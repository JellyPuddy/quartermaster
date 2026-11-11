# frozen_string_literal: true

module Quartermaster
  class WorkItem
    include WorkItemEpic
    include WorkItemLinks
    attr_reader :slug, :front, :body

    def self.slugify(title)
      slug_words(title).tap { |s| raise ArgumentError, "title needs at least one letter or digit (a-z, 0-9) for its slug" if s.empty? }
    end

    def self.slug_words(text) = text.dup.force_encoding(Encoding::UTF_8).scrub("").unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-+|-+$/, "")

    def self.path_for(slug)
      File.join(WORK_ITEMS_DIR, "#{slug}.md")
    end

    LOCK_KEY = :qm_work_item_lock

    # Every work-item mutation runs under one exclusive flock spanning its
    # whole read-modify-write — without it, concurrent qm processes clobber
    # each other's saves (a bulk distill once ate a note this way). One global
    # lock rather than per-item: contention is negligible for a personal tool
    # and compound moves (claim_session vacates other items) stay atomic.
    # Reentrant per thread so those compound moves can nest per-item mutations.
    def self.with_lock
      return yield if Thread.current[LOCK_KEY]

      Quartermaster.ensure_setup
      File.open(File.join(WORK_ITEMS_DIR, ".lock"), File::CREAT | File::RDWR) do |f|
        f.flock(File::LOCK_EX)
        Thread.current[LOCK_KEY] = true
        begin
          yield
        ensure
          Thread.current[LOCK_KEY] = false
        end
      end
    end

    def self.create(title, project:, branch: nil, session_id: nil, description: nil, pf_mode: nil, slug: nil, front: {})
      with_lock { create_locked(title, project:, branch:, session_id:, description:, pf_mode:, slug: slug || slugify(title), extra: front) }
    end

    def self.create_locked(title, project:, branch:, session_id:, description:, pf_mode:, slug:, extra:)
      raise ArgumentError, "work item '#{slug}' already exists" if File.exist?(path_for(slug))
      check_epic_target!(extra["epic"], kind: extra["kind"], slug: slug) if extra["epic"]

      validate_pf_mode(project, pf_mode) if pf_mode

      front = {
        "v" => WORK_ITEM_VERSION,
        "title" => title,
        "state" => "in_progress",
        "project" => project,
        "created" => Date.today.to_s
      }.merge(extra)
      front["branches"] = [branch] if branch
      front["sessions"] = [{ "id" => session_id }] if session_id
      front["pf_mode"] = pf_mode if pf_mode

      body = <<~BODY

        ## Description

        #{description || "_TODO_"}

        ## Notes

        ## Snapshots
      BODY

      new(slug, front, body).tap(&:save)
    end
    private_class_method :create_locked

    # The project's dev server serves one checkout in one of its modes; the
    # item remembers which one its work needs (front key pf_mode).
    def self.validate_pf_mode(project, mode)
      ProjectConfig.current.settings(project).dev_server!.check_mode!(mode)
    end

    def self.find(slug)
      path = path_for(slug)
      raise ArgumentError, "no work item '#{slug}'" unless File.exist?(path)

      match = File.read(path).match(/\A---\n(.*?)\n---\n(.*)\z/m)
      raise ArgumentError, "malformed work item file #{path}" unless match

      front = YAML.safe_load(match[1], permitted_classes: [Date]) || {}
      new(slug, front, match[2])
    end

    def self.all
      Dir[File.join(WORK_ITEMS_DIR, "*.md")].sort.map { |path| find(File.basename(path, ".md")) }
    end

    # The work item a session is linked to, or nil. A session normally belongs to
    # a single item; the first match wins if it was manually attached to several.
    def self.for_session(session_id)
      return nil unless session_id

      all.find { |item| item.sessions.any? { |s| s["id"] == session_id } }
    end

    def initialize(slug, front, body)
      @slug = slug
      @front = front
      @body = body
    end

    def attach_session(session_id)
      locked do
        sessions = (front["sessions"] ||= [])
        return false if sessions.any? { |s| s["id"] == session_id }

        sessions << { "id" => session_id }
        save
        true
      end
    end

    def detach_session(session_id)
      locked do
        list = front["sessions"]
        return false unless list&.any? { |s| s["id"] == session_id }

        list.reject! { |s| s["id"] == session_id }
        save
        true
      end
    end

    # A session belongs to one work item: a resumed session re-links to the
    # first item that lists it, so a stale attachment must not survive a move.
    def self.detach_session_elsewhere(session_id, keep:)
      all.filter_map { |item| item.slug if item.slug != keep && item.detach_session(session_id) }
    end

    # Attaching is a move: claim the session for this item and vacate it
    # everywhere else. Returns the slugs it left, for the frontends to report.
    def claim_session(session_id)
      self.class.with_lock do
        attach_session(session_id)
        WorkItem.detach_session_elsewhere(session_id, keep: slug)
      end
    end

    # Branches that are nobody's feature branch — a session started on one of
    # these says nothing about which work item it belongs to.
    MAINLINE_BRANCHES = %w[main master develop].freeze

    # Make an item out of a captured session: project and branch come from the
    # session's start event, and the session is claimed for the new item.
    # Returns [item, vacated slugs].
    def self.from_session(session_id, title:, session_log: SessionLog.new)
      start = session_log.last_start_for(session_id)
      raise ArgumentError, "unknown session #{session_id}" unless start

      branch = start["branch"]
      branch = nil if MAINLINE_BRANCHES.include?(branch)
      item = create(title, project: start["project"] || ProjectMap::NO_PROJECT,
                           branch: branch, session_id: session_id)
      [item, detach_session_elsewhere(session_id, keep: item.slug)]
    end

    def add_note(text, kind: DEFAULT_NOTE_KIND)
      note = Note.new(stamp: Date.today, kind: validate_kind(kind), text: strip_leading_stamp(text))
      locked do
        append_to_section("## Notes", "#{note}\n")
        save
      end
    end

    # Notes are addressed by their 1-based position in the file (oldest first) —
    # the numbering `qm show` prints, so what the user reads is what they can retag.
    def update_note_kind(position, kind)
      kind = validate_kind(kind)
      locked do
        stored = notes
        note = stored.find { |n| n.position == position }
        raise ArgumentError, "note ##{position} does not exist (#{stored.size} note(s))" if note.nil?

        retagged = note.with_kind(kind)
        @body = body_with_notes { |n| n.position == position ? retagged : n }
        save
        retagged
      end
    end

    # A session gets exactly one snapshot: re-distilling replaces the old
    # block, so duplicates can't exist at the storage layer whatever the
    # caller does.
    def add_snapshot(session_id, text)
      locked do
        drop_snapshot(session_id)
        append_to_section("## Snapshots", "\n### #{Date.today} — session #{session_id}\n\n#{text.strip}\n")
        save
      end
    end

    def snapshot_for?(session_id)
      snapshots.any? { |s| s["session"] == session_id }
    end

    # Resolving drops the item's diff viewed marks: a re-opened item's review
    # starts over.
    def update_state(state)
      raise ArgumentError, "state must be one of: #{STATES.join(", ")}" unless STATES.include?(state)

      locked do
        front["state"] = state
        save
      end
      ViewedMarks.new(slug).clear if state == "resolved"
    end

    # Appends — a work item can span a stack of branches (gh-stack PRs).
    # Renames are unlink-then-link. Linking a temp branch promotes it: it is
    # real work now, so cleanup must stop treating it as disposable.
    def link_branch(branch)
      locked do
        drop_temp_branch(branch)
        store_branches(branches | [branch])
      end
    end

    # A scratch branch the item's work passed through (a `claude --worktree`
    # session's worktree-* branch): cleanup's to sweep, never a PR, stack or
    # pf target. A branch already linked for real stays only that. Returns
    # whether it was added.
    def add_temp_branch(branch)
      locked do
        return false if branches.include?(branch) || temp_branches.include?(branch)

        front["temp_branches"] = temp_branches + [branch]
        save
        true
      end
    end

    # A context rotation: from_session ended and a fresh session starts now,
    # told about exactly the notes injectable at this moment. Their positions
    # are recorded (notes are append-only, so a position keeps naming the same
    # note) and so are the counts, which label the history's divider as it
    # was — a later retag doesn't rewrite what was carried. Under the lock,
    # so the notes a wrap-up just wrote are counted.
    def record_rotation(from_session:, via:, at: Time.now)
      locked do
        carried = injectable_notes
        rotation = { "at" => at.utc.iso8601, "from" => from_session, "via" => via,
                     "carried" => carried.map(&:position),
                     "decisions" => carried.count { |n| n.kind == "decision" }, "open" => carried.count(&:open?) }
        front["rotations"] = rotations + [rotation]
        save
        rotation
      end
    end

    def unlink_temp_branch(branch)
      locked do
        drop_temp_branch(branch)
        save
      end
    end

    # Several at once, appended in the given order (a stack's bottom → top).
    # Re-checked under the lock, so it is idempotent across racing processes.
    # Returns the branches it actually added.
    def link_branches(list)
      locked do
        added = list.uniq - branches
        store_branches(branches + added) if added.any?
        added
      end
    end

    def unlink_branch(branch)
      locked { store_branches(branches - [branch]) }
    end

    # One status board per item — every session on it writes to the same board.
    # The answers directory belongs to the run that published the board, so
    # pointing the item at a different board drops a stale one; relinking the
    # same board without a directory keeps it.
    def link_board(url, answers_dir: nil)
      locked do
        front.delete("board_answers_dir") if front["board"] != url
        front["board"] = url
        front["board_answers_dir"] = File.expand_path(answers_dir) if answers_dir
        save
      end
    end

    def unlink_board
      locked do
        front.delete("board")
        front.delete("board_answers_dir")
        save
      end
    end

    def update_pf_mode(mode)
      self.class.validate_pf_mode(project, mode)
      locked do
        front["pf_mode"] = mode
        save
      end
    end

    def save
      Quartermaster.ensure_setup
      AtomicFile.write(self.class.path_for(slug), "#{Psych.dump(front)}---\n#{body}")
    end

    def move_to(project)
      locked do
        front["project"] = project
        save
      end
    end

    # The slug is the item's identity (events and commands reference it), so
    # retitling deliberately never renames the file.
    def retitle(title)
      locked do
        front["title"] = title
        save
      end
    end

    def describe(text)
      locked do
        replace_section("## Description", "\n#{text.strip}\n\n")
        save
      end
    end

    # "I'm fine with this transcript degrading un-distilled" — permanent, per
    # session; a newer session on the same item warns independently.
    def ack_degrade(session_id)
      locked do
        session = sessions.find { |s| s["id"] == session_id }
        return false unless session

        session["ack_degrade"] = true
        save
        true
      end
    end

    # Takes the user-facing grammar: "Nd" snoozes N days from today, "turn"
    # quiets the chat's current your-turn, "clear" wakes the item. Returns the
    # until-date, the turn-snooze time, or nil when cleared.
    def snooze(duration)
      if duration == "clear"
        clear_snooze
        nil
      elsif duration == "turn"
        snooze_turn
      elsif (match = duration.to_s.match(/\A(\d+)d\z/))
        date = Date.today + match[1].to_i
        locked do
          front["snooze_until"] = date.to_s
          save
        end
        date
      else
        raise ArgumentError, "snooze duration must be Nd, turn or clear"
      end
    end

    # Quiets a your-turn that started at or before `at`. It has no end date:
    # the next turn's Stop starts a newer your-turn, which is loud again.
    def snooze_turn(at = Time.now)
      locked do
        front["turn_snoozed_at"] = at.utc.iso8601
        save
      end
      at
    end

    def clear_snooze
      locked do
        front.delete("snooze_until")
        front.delete("turn_snoozed_at")
        save
      end
    end

    def turn_snoozed?(since)
      stored = front["turn_snoozed_at"]
      return false unless stored && since

      Time.parse(stored.to_s) >= since
    rescue ArgumentError
      false
    end

    def snoozed_at?(date)
      stored = front["snooze_until"]
      return false unless stored

      Date.parse(stored.to_s) >= date
    rescue Date::Error
      false
    end

    def title = front["title"]
    def state = front["state"]
    def project = front["project"]
    def created = front["created"]
    def sessions = front["sessions"] || []

    def branches
      Array(front["branches"] || front["branch"])
    end

    def temp_branches = Array(front["temp_branches"])

    # Context rotations, oldest first: {"at", "from", "via", "carried", "decisions", "open"}.
    def rotations = Array(front["rotations"])

    # The session was handed over (wrapped up or distilled): its context is spent.
    def rotated_from?(session_id) = rotations.any? { |r| r["from"] == session_id }

    def board = front["board"]
    def dev_server = ProjectConfig.current.settings(project).dev_server

    # nil unless the item's project has a dev server.
    def pf_mode = (server = dev_server) && (front["pf_mode"] || server.default_mode)
    def board_answers_dir = front["board_answers_dir"]

    # An automation (kind "automation") tracks a scheduled routine: its routine id
    # and runner live in the front matter, and it stays off the lists of work.
    %w[kind routine runner].each { |key| define_method(key) { front[key] } }
    def automation? = kind == "automation"

    def issue_number
      branches.filter_map { |b| b[%r{issue/(\d+)}, 1] }.first
    end

    def description
      section_body("## Description").strip
    end

    # Newest first, the order the GUI's timeline and card preview expect. 'position' is the note's 1-based place in the file — the
    # handle `qm retag` takes, stable regardless of which end a reader counts from.
    def notes
      stored = []
      section_body("## Notes").lines.each do |line|
        note = Note.parse(line, position: stored.size + 1)
        stored << note if note
      end
      stored.reverse
    end

    # The one note a surface shows when it can show only one: the newest open
    # blocker outranks everything, then any non-history note, then whatever's left.
    def headline_note
      all = notes
      all.find(&:open?) || all.find { |n| !n.history? } || all.first
    end

    # The body with every stored note line replaced by whatever the block
    # returns for its Note — the single walker of the ## Notes section, shared
    # by retagging (writes) and `qm show` (renders annotated).
    def body_with_notes
      seen = 0
      in_notes = false
      body.lines.map do |line|
        in_notes = line.start_with?("## Notes") if line.start_with?("## ")
        note = in_notes ? Note.parse(line, position: seen + 1) : nil
        next line unless note

        seen += 1
        "#{yield(note)}\n"
      end.join
    end

    # What the SessionStart hook injects, oldest-first so it reads as a chronology:
    # every open note (newest few) plus the newest notes that aren't pure history.
    # Open notes ignore the window because a blocker stays relevant however old.
    def injectable_notes(limit: INJECTED_NOTES, open_limit: INJECTED_OPEN_NOTES)
      carried = notes.reject(&:history?)
      open_positions = carried.each_index.select { |i| carried[i].open? }.first(open_limit)
      recent_positions = carried.each_index.first(limit)
      (open_positions | recent_positions).sort.reverse.map { |i| carried[i] }
    end

    def snapshots
      section_body("## Snapshots").split(/^### /).filter_map do |chunk|
        next if chunk.strip.empty?

        header, *rest = chunk.lines
        meta = header.match(/\A(\d{4}-\d{2}-\d{2}) — session (\S+)/)
        { "stamp" => meta && meta[1], "session" => meta && meta[2], "text" => rest.join.strip }
      end.reverse
    end

    # The static shape of a work item — everything derivable from the file
    # alone. The GUI enriches this with live session tiers, attention badges,
    # and last-activity, which need the session log and can't live here.
    def to_h
      {
        "slug" => slug, "title" => title, "state" => state, "project" => project,
        "branches" => branches, "temp_branches" => temp_branches, "issue_number" => issue_number, "board" => board,
        "pf_mode" => pf_mode, "board_answers_dir" => board_answers_dir,
        "kind" => kind, "routine" => routine, "runner" => runner, "epic" => epic, "links" => links,
        "session_ids" => sessions.map { |s| s["id"] }, "sessions" => sessions.size,
        "description" => description, "notes" => notes.map(&:to_h), "snapshots" => snapshots
      }
    end

    private

    # Notes are stored with a date prefix this writer adds, but Claude tends to
    # open the text with the date as well — drop its copy so notes don't read
    # "2026-08-04: 2026-08-04: ...".
    def strip_leading_stamp(text)
      text.strip.sub(/\A\d{4}-\d{2}-\d{2}:\s*/, "")
    end

    # The unit that makes a stale in-memory copy harmless: take the lock,
    # re-read the file, and only then apply the mutation (which saves).
    def locked
      self.class.with_lock do
        reload!
        yield
      end
    end

    def reload!
      fresh = self.class.find(slug)
      @front = fresh.front
      @body = fresh.body
    end

    def validate_kind(kind)
      kind = kind.to_s
      raise ArgumentError, "unknown note kind '#{kind}' (#{NOTE_KINDS.join(" | ")})" unless NOTE_KINDS.include?(kind)

      kind
    end

    def section_body(heading)
      lines = body.lines
      idx = lines.index { |l| l.start_with?(heading) }
      return "" unless idx

      lines[(idx + 1)...section_end(lines, idx)].join
    end

    def store_branches(list)
      front.delete("branch")
      front["branches"] = list
      save
    end

    def drop_temp_branch(branch)
      list = temp_branches - [branch]
      list.empty? ? front.delete("temp_branches") : front["temp_branches"] = list
    end

    def drop_snapshot(session_id)
      section = section_body("## Snapshots")
      marker = /\A### \d{4}-\d{2}-\d{2} — session #{Regexp.escape(session_id)}\s*$/
      chunks = section.split(/^(?=### )/)
      return unless chunks.any? { |c| c.lines.first&.match?(marker) }

      kept = chunks.reject { |c| c.lines.first&.match?(marker) }.join.strip
      replace_section("## Snapshots", kept.empty? ? "\n" : "\n#{kept}\n")
    end

    def append_to_section(heading, entry)
      lines = body.lines
      section_idx = lines.index { |l| l.start_with?(heading) }
      unless section_idx
        @body += "\n#{heading}\n#{entry}"
        return
      end

      insert_at = section_end(lines, section_idx)
      insert_at -= 1 while insert_at > section_idx + 1 && lines[insert_at - 1].strip.empty?
      lines.insert(insert_at, entry)
      @body = lines.join
    end

    def replace_section(heading, content)
      lines = body.lines
      section_idx = lines.index { |l| l.start_with?(heading) }
      unless section_idx
        @body += "\n#{heading}\n#{content}"
        return
      end

      @body = (lines[0..section_idx] + [content] + lines[section_end(lines, section_idx)..]).join
    end

    def section_end(lines, section_idx)
      ((section_idx + 1)...lines.length).each do |i|
        return i if lines[i].start_with?("## ")
      end
      lines.length
    end
  end
end
