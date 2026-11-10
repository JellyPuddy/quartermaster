# frozen_string_literal: true

module Quartermaster
  class HookHandler
    def initialize(session_log: SessionLog.new)
      @session_log = session_log
    end

    def session_started(input)
      session_id = input["session_id"]
      cwd = input["cwd"]
      branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
      project = ProjectMap.new.project_for(cwd)
      aside = ENV[Aside::ENV_VAR].to_s
      return aside_started(input, aside, branch, project) unless aside.empty?

      loose = ENV[LooseChat::ENV_VAR].to_s
      item = loose.empty? ? linked_work_item(session_id, branch, project) : promoted_item(session_id, loose)
      return loose_started(input, loose, branch, project) if !loose.empty? && item.nil?

      item&.attach_session(session_id)
      record_temp_branch(item, cwd, branch) if item

      @session_log.append(
        "event" => "start",
        "session_id" => session_id,
        "source" => input["source"],
        "cwd" => cwd,
        "transcript_path" => input["transcript_path"],
        "branch" => branch,
        "head" => git(cwd, "rev-parse", "HEAD"),
        "pid" => claude_pid,
        "project" => project,
        "work_item" => item&.slug,
        "ts" => Time.now.iso8601
      )

      item ? linked_context(session_id, item) : unlinked_context(session_id, project)
    end

    def session_ended(input)
      session_id = input["session_id"]
      cwd = input["cwd"]
      start = @session_log.last_start_for(session_id)
      now = Time.now

      commits = nil
      if start && start["head"]
        out = git(cwd, "log", "--format=%h %s", "#{start["head"]}..HEAD")
        commits = out.split("\n") if out && !out.empty?
      end

      # Claude Code never persists a transcript for a session with zero
      # messages, so a missing transcript at end time means the session was
      # opened and closed without being used.
      recorded = input["transcript_path"] || start&.fetch("transcript_path", nil)
      empty = Quartermaster.locate_transcript(session_id, recorded).nil?

      event = {
        "event" => "end",
        "session_id" => session_id,
        "reason" => input["reason"],
        "duration_s" => start ? (now - Time.parse(start["ts"])).round : nil,
        "commits" => commits,
        "diff_stat" => git(cwd, "diff", "--shortstat", "HEAD"),
        "ts" => now.iso8601
      }
      event["empty"] = true if empty
      @session_log.append(event)
      return unless empty

      WorkItem.all.each { |item| item.detach_session(session_id) }
      @session_log.dismiss(session_id)
    end

    private

    # An aside (QM_ASIDE=<slug>) is logged as such and gets the item's digest,
    # but is never attached — not even by branch — so it stays out of the
    # item's sessions, attention, distill and the inbox.
    def aside_started(input, slug, branch, project)
      @session_log.append(
        "event" => "start",
        "session_id" => input["session_id"],
        "source" => input["source"],
        "cwd" => input["cwd"],
        "transcript_path" => input["transcript_path"],
        "branch" => branch,
        "pid" => claude_pid,
        "project" => project,
        "aside" => slug,
        "ts" => Time.now.iso8601
      )
      item = begin
        WorkItem.find(slug)
      rescue ArgumentError
        nil
      end
      return nil unless item

      <<~CONTEXT
        [qm] This Claude Code session is an aside about work item '#{item.slug}': a one-off question asked beside the item's chat. It is deliberately not linked to the item — don't run qm commands for it (no note, state, attach or new); the user promotes an answer to the item themselves.

        #{item_digest(item)}
      CONTEXT
    end

    # A loose chat (QM_LOOSE=<id>) is logged with its id and never linked —
    # no QM_ITEM, no branch match — but, unlike an aside, it stays in the
    # inbox and asks for attention like any unlinked session.
    def loose_started(input, id, branch, project)
      @session_log.append(
        "event" => "start",
        "session_id" => input["session_id"],
        "source" => input["source"],
        "cwd" => input["cwd"],
        "transcript_path" => input["transcript_path"],
        "branch" => branch,
        "head" => git(input["cwd"], "rev-parse", "HEAD"),
        "pid" => claude_pid,
        "project" => project,
        "loose" => id,
        "ts" => Time.now.iso8601
      )

      <<~CONTEXT
        [qm] This Claude Code session (#{input["session_id"]}) is a loose chat, by intent: the user started it without a work item (project #{project}). Don't create or attach a work item (no qm new, attach or note) unless the user asks. Before changing any code, ask the user to promote this chat (→ Work item in qm's chat view) so it gets an item and a worktree.
      CONTEXT
    end

    # A promoted loose chat keeps QM_LOOSE in its claude process, so a /clear
    # or compaction restart must follow the item it became: this session's
    # own item, else the one any earlier session of the same loose id joined.
    def promoted_item(session_id, id)
      ids = [session_id] + @session_log.sessions.select { |s| s.loose_id == id }.map(&:id)
      WorkItem.all.find { |i| i.sessions.any? { |s| ids.include?(s["id"]) } }
    end

    WORKTREE_SEGMENT = "/#{TargetWorktree::WORKTREES_DIR}/".freeze

    # A linked session working in a `.claude/worktrees/*` checkout leaves a
    # scratch branch behind; recording it lets cleanup find it later. A path
    # test and one item write — and a failure here must never cost the
    # session its context, so it is swallowed and logged.
    def record_temp_branch(item, cwd, branch)
      return unless cwd&.include?(WORKTREE_SEGMENT) && branch && branch != "HEAD"
      return if WorkItem::MAINLINE_BRANCHES.include?(branch)

      item.add_temp_branch(branch)
    rescue StandardError => e
      Quartermaster.log_error("temp-branch", e)
    end

    # An item this session is already attached to wins (QM_ITEM outlives a
    # mid-session move); then launcher-provided QM_ITEM, but an unknown slug (a
    # launched session's env leaks into nested runs) falls through; then a work
    # item that recorded this exact branch in this project. No fuzzy matching here — ambiguity is
    # Claude's job (the unlinked context asks it to decide).
    def linked_work_item(session_id, branch, project)
      if (attached = WorkItem.all.find { |i| i.sessions.any? { |s| s["id"] == session_id } })
        attached
      elsif ENV["QM_ITEM"] && (launched = begin
        WorkItem.find(ENV["QM_ITEM"])
      rescue ArgumentError
        nil
      end)
        launched
      elsif branch
        candidates = WorkItem.all.select { |i| i.branches.include?(branch) && i.project == project }
        candidates.find { |i| i.state != "resolved" } || candidates.first
      end
    end

    def linked_context(session_id, item)
      <<~CONTEXT
        [qm] This Claude Code session (#{session_id}) is linked to work item '#{item.slug}' — the session id has been attached to it automatically.

        #{item_digest(item)}
        Work item protocol:
        - Append a succinct progress note at meaningful milestones: qm note #{item.slug} --kind <#{NOTE_KINDS.join("|")}> "..."
          - open — still unresolved and user-facing: a decision the user owes, a blocked dependency, a known gap, anything you'd describe as "flagged to the user". Always re-injected regardless of age, so keep it short and say what would unblock it.
          - decision — a choice made, or a finding about how the system actually is: something a later session would get wrong without knowing it.
          - history — how it got done: commits, rebases, folds, message fixups, push status, specs green. Kept in the file, never re-injected.
          One kind per note: if a milestone has both a decision and its mechanics, write two notes. If a note contains anything still open, it is 'open' whatever else it says. Omitting --kind means '#{DEFAULT_NOTE_KIND}'. Don't repeat the date in the text — qm stamps it.
        - When an open item is handled, retag it so it stops being injected: qm retag #{item.slug} <position> decision (positions are the #n above). Same command backfills a kind you got wrong.
        - Keep the Description as the item's current truth: when a note records a decision or constraint that still governs the work, fold it into the description (qm describe #{item.slug} "..."). Notes fall out of the injection window; the description doesn't.
        - Update the state when it changes: qm state #{item.slug} (#{STATES.join(" | ")})
        - A 'status board' above means the item already has one: reuse that URL instead of publishing a new board (record one with qm board #{item.slug} URL).
        - Refine a stale title when asked (or when it's clearly outdated): qm retitle #{item.slug} "..."
        - A todo for the user's own list, when the user asks, or something needs their own hands outside this session: qm todo add "…" [--item #{item.slug}]
        - The session sits on the item it is working on right now. The moment its work moves to another item (a different issue, a follow-up, refinement prep), re-link it then and there; likewise when this link is a wrong branch-based guess, telling the user:
          continues another item → qm attach <other-slug> --session #{session_id}; substantial new work → qm new "Title" --project "..." --session #{session_id} (both move the session off this item); trivial or throwaway → qm detach #{item.slug} --session #{session_id} and don't mention tracking again.#{pf_protocol_line(item)}#{pr_requires_protocol_line(item)}
      CONTEXT
    end

    # Only a project with a dev server (projects.<name>.dev_server.command) pays these tokens.
    def pf_protocol_line(item)
      return "" unless (server = item.dev_server)

      ide = ProjectConfig.current.ide(item.project)
      "\n- Dev server: qm work-on #{item.slug} (#{server.command} #{item.pf_mode}#{" + #{ide.label}" if ide}); mode: qm pf-mode #{item.slug} MODE"
    end

    # PR prerequisites (PrPrerequisites) matter where PRs ship by release;
    # only projects that say so (projects.<name>.pr_prerequisites) pay for the hint.
    def pr_requires_protocol_line(item)
      return "" unless ProjectConfig.current.settings(item.project).pr_prerequisites?

      "\n- PR may merge only after an earlier PR/commit is deployed: qm pr-requires <pr-or-sha> [--note TEXT]"
    end

    # A digest rather than the raw file: the full note history of a long-running
    # item dwarfs everything else in the injection, and the session-id list is
    # bookkeeping Claude never acts on.
    def item_digest(item)
      notes = item.notes
      shown = item.injectable_notes
      lines = ["Work item (#{WorkItem.path_for(item.slug)}):", "  title: #{item.title}"]
      lines << "  state: #{item.state}"
      lines << "  project: #{item.project}" if item.project
      lines << "  created: #{item.created}" if item.created
      lines << "  branches: #{item.branches.join(", ")}" if item.branches.any?
      lines << "  status board: #{item.board}" if item.board
      lines << "  sessions: #{item.sessions.size} (ids in the file)" if item.sessions.any?

      lines << "" << "## Description" << "" << (item.description.empty? ? "(none)" : item.description)
      lines << "" << "## Notes#{notes_heading_suffix(item, notes.size, shown.size)}"
      lines.concat(shown.empty? ? ["(none yet)"] : shown.map { |n| digest_note_line(n) })
      if item.snapshots.any?
        lines << "" << "## Snapshots: #{item.snapshots.size} distilled transcript(s), read with `qm show #{item.slug}`"
      end
      "#{lines.join("\n")}\n"
    end

    # Position numbers match `qm show`, so Claude can retag a note it just read.
    def digest_note_line(note)
      "- ##{note.position} #{note.stamp} [#{note.kind}]: #{note.text}"
    end

    def notes_heading_suffix(item, total, shown)
      return "" if total <= shown

      " (#{shown} of #{total} — the rest are history or older; read them all with `qm show #{item.slug}`)"
    end

    def unlinked_context(session_id, project)
      open_items = WorkItem.all.reject { |i| i.state == "resolved" || i.automation? }
      listing = open_items.map do |i|
        details = [i.project, *i.branches, i.state].compact.join(", ")
        "- #{i.slug} — #{i.title} (#{details})"
      end
      listing = ["(none yet)"] if listing.empty?

      <<~CONTEXT
        [qm] This Claude Code session (#{session_id}) is not linked to a work item. Project baseline from cwd: #{project}.

        Open work items:
        #{listing.join("\n")}

        Linking protocol — link once the session's purpose is clear from the first message or two, and re-link the moment its work moves to a different item (attach and new both move the session):
        - Continues one of the items above → qm attach <slug> --session #{session_id}
        - Substantial new work → qm new "Title" --project "#{project}" --session #{session_id} --description "..." — but sanity-check the project against the topic first; if it seems wrong, ask the user instead of guessing.
        - Trivial or throwaway (quick question, one-off lookup) → do nothing, and don't mention any of this.
        After linking, keep the work item current: qm note <slug> "..." at meaningful milestones.
      CONTEXT
    end

    def git(cwd, *args)
      Quartermaster.git(cwd, *args)
    end

    def claude_pid
      pid = Process.ppid
      6.times do
        out, _err, status = Open3.capture3("ps", "-o", "ppid=,command=", "-p", pid.to_s)
        break unless status.success? && !out.strip.empty?

        ppid_str, command = out.strip.split(" ", 2)
        return pid if command&.match?(/claude/i)

        pid = ppid_str.to_i
        break if pid <= 1
      end
      Process.ppid
    rescue StandardError
      Process.ppid
    end
  end
end
