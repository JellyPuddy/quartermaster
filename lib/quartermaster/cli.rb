# frozen_string_literal: true

module Quartermaster
  # `qm`: the work-item commands, and the dispatch to every command group.
  # A group is a module beside this file whose COMMANDS maps a command word
  # to the method #run calls with argv, so a new command touches only its
  # group. The hooks and the irregular commands stay explicit in #run.
  class CLI
    COMMAND_GROUPS = [CliViewer, CliWorkspace, CliPrs, CliCleanup, CliChats, CliAttention].freeze
    include CliFormat
    include(*COMMAND_GROUPS)

    COMMANDS = {
      "new" => :cmd_new,
      "attach" => :cmd_attach,
      "detach" => :cmd_detach,
      "note" => :cmd_note,
      "retag" => :cmd_retag,
      "state" => :cmd_state,
      "link-branch" => :cmd_link_branch,
      "unlink-branch" => :cmd_unlink_branch,
      "board" => :cmd_board,
      "board-rows" => :cmd_board_rows,
      "board-answer" => :cmd_board_answer,
      "move" => :cmd_move,
      "retitle" => :cmd_retitle,
      "describe" => :cmd_describe,
      "issues-dir" => :cmd_issues_dir,
      "list" => :cmd_list,
      "install-hooks" => :cmd_install_hooks,
      "ask" => :cmd_ask,
      "grep" => :cmd_grep
    }.freeze

    # Every table-dispatched command word → its method, across the groups.
    def self.commands
      @commands ||= [self, *COMMAND_GROUPS].map { |group| group::COMMANDS }.reduce do |all, table|
        all.merge(table) { |word| raise "qm command '#{word}' is in two command tables" }
      end.freeze
    end

    # prerequisites: a PrPrerequisites with a stubbed gh in tests.
    # caller_pids: this process and its ancestors (qm rotate --self), stubbed in tests.
    # runner: the CommandRunner for external tools (qm open-chat), stubbed in tests.
    def initialize(prerequisites: nil, cwd: nil, caller_pids: nil, runner: nil)
      @prerequisites = prerequisites
      @cwd = cwd
      @caller_pids = caller_pids
      @runner = runner
    end

    def run(argv)
      command = argv.shift
      FeatureUse.new.command(command)
      case command
      when "hook-session-start" then guard_hook(command) do
        context = HookHandler.new.session_started(JSON.parse($stdin.read))
        puts context if context
      end
      when "hook-session-end" then guard_hook(command) { HookHandler.new.session_ended(JSON.parse($stdin.read)) }
      when *CLI.commands.keys then send(CLI.commands.fetch(command), argv)
      when "pf-switch" then cmd_workspace(:switch_pf, "pf-switch", argv, mode: true)
      when "ide" then cmd_workspace(:open_ide, "ide", argv, mode: false)
      when "term" then cmd_workspace(:open_terminal, "term", argv, mode: false)
      when "work-on" then cmd_workspace(:work_on, "work-on", argv, mode: true)
      when "pf-stop" then puts Workspace.new.stop_pf
      when "pf-status" then cmd_pf_status
      when "feature-use" then puts FeatureUse.new.report(argv)
      when "gui" then Gui.new.run
      # Internal, never in the help: the detached process BenchmarkRun spawns.
      when "bench-run" then BenchmarkPipeline.new(argv.first || abort("usage: qm bench-run RUN_DIR")).call
      when "pane-start", "pane-resume" then cmd_pane(command, argv)
      when "viewer" then Viewer.new.open
      when "sessions-view" then Viewer.new.sessions_view(argv.first || abort("usage: qm sessions-view SLUG"))
      when "inbox-view" then Viewer.new.inbox_view
      when "cycle-filter" then viewer_filter(cycle: true)
      when nil then $stdout.tty? && Viewer.fzf? ? Viewer.new.open : cmd_list(argv)
      when "help", "--help", "-h" then usage
      else
        warn("qm: unknown command '#{command}'")
        usage
        exit 1
      end
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end

    private

    # Hooks must never block or break a session: swallow everything, log, stay silent.
    def guard_hook(context)
      return if ENV["QM_SKIP"]

      yield
    rescue StandardError => e
      Quartermaster.log_error(context, e)
    end

    def cmd_new(argv)
      options = { project: "No project" }
      parser = OptionParser.new do |o|
        o.on("--project PROJECT") { |v| options[:project] = v }
        o.on("--branch BRANCH") { |v| options[:branch] = v }
        o.on("--session SESSION_ID") { |v| options[:session] = v }
        o.on("--description TEXT") { |v| options[:description] = v }
        o.on("--pf-mode MODE") { |v| options[:pf_mode] = v }
      end
      title = parser.parse(argv).join(" ").strip
      if title.empty?
        abort("usage: qm new TITLE [--project P] [--branch B] [--session ID] [--description TEXT] [--pf-mode MODE]")
      end

      item = WorkItem.create(
        title,
        project: options[:project],
        branch: options[:branch],
        session_id: options[:session],
        description: options[:description],
        pf_mode: options[:pf_mode]
      )
      report_claim(item.claim_session(options[:session]), options[:session], item.slug) if options[:session]
      puts item.slug
    end

    def cmd_attach(argv)
      slug = argv.shift
      session_id = nil
      OptionParser.new { |o| o.on("--session SESSION_ID") { |v| session_id = v } }.parse(argv)
      abort("usage: qm attach SLUG --session SESSION_ID") unless slug && session_id

      report_claim(WorkItem.find(slug).claim_session(session_id), session_id, slug)
    end

    # A chat pane running the session follows it to the new item.
    def report_claim(vacated, session_id, slug)
      vacated.each { |other| puts "detached from '#{other}'" }
      warning = PaneFollowsSession.new.move(session_id, from: vacated, to: slug)
      warn "qm: #{warning}" if warning
    end

    def cmd_detach(argv)
      slug = argv.shift
      session_id = nil
      OptionParser.new { |o| o.on("--session SESSION_ID") { |v| session_id = v } }.parse(argv)
      abort("usage: qm detach SLUG --session SESSION_ID") unless slug && session_id

      WorkItem.find(slug).detach_session(session_id)
    end

    def cmd_note(argv)
      kind = DEFAULT_NOTE_KIND
      parser = OptionParser.new { |o| o.on("--kind KIND") { |v| kind = v } }
      slug = argv.shift
      text = parser.parse(argv).join(" ").strip
      abort("usage: qm note SLUG [--kind #{NOTE_KINDS.join("|")}] TEXT") if slug.nil? || text.empty?

      item = WorkItem.find(slug)
      item.add_note(text, kind: kind)
      # Echo what landed: a wrong or missing kind is worth noticing immediately,
      # while it's still one `qm retag` away.
      puts note_line(item.notes.first)
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end

    def cmd_retag(argv)
      slug, position, kind = argv
      unless slug && position && kind
        abort("usage: qm retag SLUG POSITION KIND (#{NOTE_KINDS.join(" | ")}) — POSITION is the number qm show prints")
      end

      puts note_line(WorkItem.find(slug).update_note_kind(Integer(position, exception: false) || 0, kind))
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end

    def cmd_state(argv)
      slug, state = argv
      abort("usage: qm state SLUG (#{STATES.join(" | ")})") unless slug && state

      item = WorkItem.find(slug)
      item.update_state(state)
      offer_cleanup(item) if state == "resolved"
    end

    # Resolving is when worktrees go stale, so say what cleanup would do —
    # a hint only: a failing plan must never fail the resolve.
    def offer_cleanup(item)
      plan = Cleanup.new.plan_item(item)
      return if plan.empty?

      puts "cleanup: #{plan.summary} — qm cleanup #{item.slug}"
    rescue StandardError => e
      Quartermaster.log_error("cleanup-offer", e)
    end

    def cmd_list(_argv)
      items = WorkItem.all
      if items.empty?
        puts "No work items yet. Create one with: qm new TITLE"
        return
      end

      rows = items.map do |item|
        [item.state || "?", item.project || "?", item.slug, item.sessions.size.to_s,
         item.branches.empty? ? "-" : item.branches.join(" ")]
      end
      widths = rows.transpose.map { |col| col.map(&:length).max }
      rows.each do |row|
        puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ")
      end
    end

    def cmd_link_branch(argv)
      temp = false
      slug, branch = OptionParser.new { |o| o.on("--temp") { temp = true } }.parse(argv)
      branch ||= Quartermaster.git(Dir.pwd, "rev-parse", "--abbrev-ref", "HEAD")
      unless slug && branch
        abort("usage: qm link-branch SLUG [BRANCH] [--temp]  (BRANCH defaults to the current branch)")
      end

      item = WorkItem.find(slug)
      if temp
        abort("qm: '#{branch}' is already a linked branch of '#{slug}'; unlink it first") if item.branches.include?(branch)

        item.add_temp_branch(branch)
        puts "#{slug} → temp: #{item.temp_branches.join(", ")}"
      else
        item.link_branch(branch)
        puts "#{slug} → #{item.branches.join(", ")}"
      end
    end

    def cmd_unlink_branch(argv)
      slug, branch = argv
      abort("usage: qm unlink-branch SLUG BRANCH") unless slug && branch

      item = WorkItem.find(slug)
      abort("qm: '#{slug}' has no branch '#{branch}'") unless item.branches.include?(branch)
      item.unlink_branch(branch)
      puts "#{slug} → #{item.branches.empty? ? "(no branches)" : item.branches.join(", ")}"
    end

    # Bare `qm board SLUG` prints only the URL (nothing, non-zero, when unset)
    # so a shell can test it with one call.
    def cmd_board(argv)
      answers_dir = nil
      OptionParser.new { |o| o.on("--answers-dir DIR") { |v| answers_dir = v } }.parse!(argv)
      slug, url = argv
      abort("usage: qm board SLUG [URL [--answers-dir DIR] | clear]") unless slug
      abort("qm: --answers-dir needs a board URL") if answers_dir && (url.nil? || url == "clear")

      item = WorkItem.find(slug)
      case url
      when nil then item.board ? puts(item.board) : exit(1)
      when "clear"
        item.unlink_board
        puts "#{slug} → (no status board)"
      else
        item.link_board(url, answers_dir: answers_dir)
        puts "#{slug} → #{url}#{" (answers: #{item.board_answers_dir})" if item.board_answers_dir}"
      end
    end

    # The item's board as mirrored from board-writes.jsonl, a row per line (--json: full rows).
    def cmd_board_rows(argv)
      json = argv.delete("--json")
      slug = argv.first
      abort("usage: qm board-rows SLUG [--json]") unless slug

      item = WorkItem.find(slug)
      abort("qm: '#{slug}' has no status board") unless item.board
      rows = BoardMirror.new.rows_for(item)
      return puts(JSON.pretty_generate(rows)) if json
      return puts("(no rows mirrored for #{item.board})") if rows.empty?

      width = rows.map { |r| r["doc_id"].length }.max
      rows.each do |r|
        line = "#{r["doc_id"].ljust(width)}  #{r["status"].to_s.ljust(8)}  #{r["title"]}"
        line += " — #{r["note"]}" unless r["note"].to_s.empty?
        puts line
      end
    end

    def cmd_board_answer(argv)
      slug, doc_id, *words = argv
      abort("usage: qm board-answer SLUG ROW_ID TEXT  ('-' or no TEXT reads stdin)") unless slug && doc_id

      text = words.empty? || words == ["-"] ? $stdin.read : words.join(" ")
      puts BoardMirror.new.answer(WorkItem.find(slug), doc_id, text)
    end

    def cmd_move(argv)
      slug, project = argv
      abort("usage: qm move SLUG PROJECT") unless slug && project

      WorkItem.find(slug).move_to(project)
      puts "#{slug} → #{project}"
    end

    def cmd_retitle(argv)
      slug = argv.shift
      title = argv.join(" ").strip
      abort("usage: qm retitle SLUG NEW_TITLE  (the slug never changes)") if slug.nil? || title.empty?

      WorkItem.find(slug).retitle(title)
      puts "#{slug}: #{title}"
    end

    def cmd_describe(argv)
      slug = argv.shift
      text = argv.join(" ").strip
      text = $stdin.read.strip if text.empty? || text == "-"
      abort("usage: qm describe SLUG TEXT  (or pipe the text on stdin)") if slug.nil? || text.empty?

      WorkItem.find(slug).describe(text)
    end

    # Where the /draft-issues skill writes an item's issue files.
    def cmd_issues_dir(argv)
      slug = argv.first
      abort("usage: qm issues-dir SLUG") unless slug

      issues = IssueDrafts.new(slug)
      WorkItem.find(slug)
      FileUtils.mkdir_p(issues.dir)
      puts issues.dir
    end

    HOOK_SCRIPTS_DIR = File.join(File.dirname(File.realpath(EXECUTABLE)), "hooks")

    # Prints, never writes: settings.json is the user's to edit. Absolute paths
    # through the launcher's realpath, so the snippet points at this checkout.
    def cmd_install_hooks(_argv)
      launcher = File.realpath(EXECUTABLE)
      command = ->(cmd) { [{ "hooks" => [{ "type" => "command", "command" => cmd }] }] }
      events = File.join(HOOK_SCRIPTS_DIR, "record-event.sh")
      hooks = {
        "SessionStart" => command.("#{launcher} hook-session-start"),
        "SessionEnd" => command.("#{launcher} hook-session-end"),
        "UserPromptSubmit" => [{ "hooks" => [events, File.join(HOOK_SCRIPTS_DIR, "snapshot-worktree.sh")]
          .map { |cmd| { "type" => "command", "command" => cmd } } }],
        "PermissionRequest" => command.(events),
        "Stop" => command.(events),
        "StopFailure" => command.(events),
        "PostToolUseFailure" => command.(events),
        "PostToolUse" => command.(events) +
          [{ "matcher" => "ArtifactData",
             "hooks" => [{ "type" => "command", "command" => File.join(HOOK_SCRIPTS_DIR, "record-board-write.sh") }] }]
      }
      puts "# Merge into the \"hooks\" key of ~/.claude/settings.json (qm never writes it)."
      puts "# The SessionStart/SessionEnd entries replace the existing qm ones - kept side by"
      puts "# side, every session would be captured and injected twice."
      puts JSON.pretty_generate({ "hooks" => hooks })
    end

    def cmd_ask(argv)
      query = argv.join(" ")
      abort("usage: qm ask QUERY") if query.strip.empty?

      hits = AskSearch.new.call(query)
      return puts("No work item matches.") if hits.empty?

      hits.each { |hit| puts "#{hit["slug"]}\n    #{hit["why"]}" }
    end

    def cmd_grep(argv)
      query = argv.join(" ")
      abort("usage: qm grep PHRASE") if query.strip.empty?

      result = TranscriptSearch.new.call(query)
      return puts("No transcript mentions that.") if result["groups"].empty?

      bold = $stdout.tty? ? ->(s) { "\e[1m#{s}\e[0m" } : ->(s) { s }
      result["groups"].each do |group|
        puts group["slug"] ? "#{group["slug"]}  #{group["title"]}  (#{group["state"]})" : "unlinked"
        group["sessions"].each do |hit|
          date = hit["date"] ? Time.parse(hit["date"]).localtime.strftime("%Y-%m-%d %H:%M") : "????-??-?? --:--"
          who = hit["role"] == "user" ? "you" : "claude"
          hits = hit["hits"] > 1 ? " (#{hit["hits"]} hits)" : ""
          puts "  #{date}  #{hit["id"]}#{hits}"
          puts "    #{who}: #{hit["before"]}#{bold.call(hit["match"])}#{hit["after"]}"
        end
      end
      puts "… #{result["more"]} more transcript(s) not read; narrow the phrase" if result["more"].positive?
      puts "Resume: qm resume SLUG --session ID (unlinked: claude --resume ID from its project dir)"
    rescue ArgumentError => e
      abort(e.message)
    end
  end
end
