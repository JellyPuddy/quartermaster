# frozen_string_literal: true

module Quartermaster
  # Commands that act on the running GUI's chats (pane-start/-resume
  # dispatch in CLI#run).
  module CliChats
    COMMANDS = {
      "caffeinate" => :cmd_caffeinate,
      "open-chat" => :cmd_open_chat,
      "start-issue" => :cmd_start_issue,
      "loose" => :cmd_loose,
      "rotate" => :cmd_rotate
    }.freeze

    private

    # Acts on the running GUI, which owns the caffeinate child (`-w <gui pid>`
    # ties its life to the GUI's).
    def cmd_caffeinate(argv)
      mode = argv.first || "status"
      abort("usage: qm caffeinate on|off|auto|status") unless %w[on off auto status].include?(mode)

      reply = gui_action("caffeinate", "caffeinate", args: { "mode" => mode })
      status = reply["caffeinate"]
      held = status["on"] ? "pid #{status["pid"]}" : "not held"
      puts case status["mode"]
           when "auto" then "caffeinate auto (#{held} — held while any session is working, until the GUI exits)"
           when "on" then "caffeinate on (#{held}, until the GUI exits)"
           else "caffeinate off"
           end
    end

    # A macOS notification's click (TurnNotifier). Doesn't check the GUI is
    # up: a dead one's page says so, which is news too.
    def cmd_open_chat(argv)
      benchmark = nil
      OptionParser.new { |o| o.on("--benchmark BRANCH") { |v| benchmark = v } }.parse!(argv)
      slug = argv.first or abort("usage: qm open-chat SLUG [--benchmark BRANCH]")

      ChatOpener.new(runner: @runner || CommandRunner.new).open(slug, benchmark: benchmark)
    end

    # The GUI's chat-pane Start/Resume, from a terminal or another chat: the
    # pane is the GUI's (its tmux session, its terminal), so it is the GUI's
    # action that runs.
    def cmd_pane(cmd, argv)
      slug = argv.shift
      session_id = nil
      OptionParser.new { |o| o.on("--session SESSION_ID") { |v| session_id = v } }.parse(argv) if cmd == "pane-resume"
      abort(cmd == "pane-start" ? "usage: qm pane-start SLUG" : "usage: qm pane-resume SLUG [--session ID]") unless slug

      reply = gui_action(cmd, cmd, slug: slug, args: session_id ? { "session" => session_id } : {})
      puts(if reply["attached"] then "#{slug}: its chat is already running in the qm gui"
           elsif reply["mode"] == "resume" then "#{slug}: resumed in its qm gui pane"
           else "#{slug}: fresh chat started in its qm gui pane"
           end)
    end

    # The GUI's rotate action. --self is the chat rotating itself (the
    # /rotate skill): it names no slug — the calling chat is the one — and
    # returns at once; the GUI hands over once this turn ends.
    def cmd_rotate(argv)
      close = by_chat = false
      OptionParser.new do |o|
        o.on("--close") { close = true }
        o.on("--self") { by_chat = true }
      end.parse!(argv)
      slug = argv.shift unless by_chat
      abort("usage: qm rotate SLUG [--close] | qm rotate --self [--close]") unless by_chat || slug

      args = { "close" => close }
      if by_chat
        slug, session_id = calling_chat
        args.merge!("self" => true, "session" => session_id)
      end
      reply = gui_action("rotate", "rotate", slug: slug, args: args)
      puts(if by_chat then "#{slug}: #{close ? "closing" : "rotating"} after this turn ends — end the turn now"
           elsif reply["mode"] == "distill" then "#{slug}: rotating — distilling the dead chat, then a fresh one starts in its pane"
           else "#{slug}: #{close ? "wrap up & close" : "rotation"} started — the chat wraps up in its qm gui pane"
           end)
    end

    # The item and session of the chat running this command: the live
    # session whose claude process is an ancestor, else the QM_ITEM it was
    # launched with. An aside is never the item's chat.
    def calling_chat
      abort("qm rotate --self: an aside can't rotate — only the item's own chat can") if ENV[Aside::ENV_VAR].to_s != ""

      pids = caller_pids
      session = SessionLog.new.sessions.find { |s| s.live? && pids.include?(s.pid) }
      slug = (session && WorkItem.for_session(session.id)&.slug) || ENV["QM_ITEM"].to_s
      if slug.empty?
        abort("qm rotate --self: run it from a work item's chat in the qm gui — this process belongs to no item's chat")
      end
      [slug, session&.id]
    end

    def caller_pids
      @caller_pids ? @caller_pids.call : Quartermaster.process_lineage(Process.pid)
    end

    # Any GitHub issue as a work item: prints the preview, then starts it in
    # the running GUI (worktree on its background job, then the chat with the
    # kickoff in the item's pane). Without a GUI it makes the item and
    # worktree here and prints how to start the chat. No y/N: chats run this
    # too, and the preview is there to read afterwards.
    def cmd_start_issue(argv)
      project = nil
      rest = OptionParser.new { |o| o.on("--project PROJECT") { |v| project = v } }.parse(argv)
      abort("usage: qm start-issue NUMBER [--project P]") unless rest.size == 1

      project ||= default_issue_project
      starter = IssueStart.new(runner: @runner || CommandRunner.new)
      preview = starter.preview(rest.first, project)
      print_issue_preview(preview)

      reply = gui_action("start-issue", "issue-start", args: { "number" => preview["number"], "project" => project },
                                                       optional: true)
      if reply
        puts(if reply["existing"] then "#{reply["slug"]}: its chat is open in the qm gui"
             else "#{reply["slug"]}: starting in the qm gui — its chat opens in the item's pane once the worktree is ready"
             end)
      elsif (existing = preview["existing"])
        puts "#{existing["slug"]} already holds ##{preview["number"]} — continue there: qm resume #{existing["slug"]}"
      else
        started = starter.start(preview)
        path = started[:target].path
        puts "#{started[:item].slug}: created, worktree #{short_path(path)} on #{preview["branch"]}"
        puts "no qm gui running — start its chat with:"
        puts "  cd #{Shellwords.escape(path)} && QM_ITEM=#{started[:item].slug} " \
             "claude #{Shellwords.escape(IssueStart.kickoff(preview["number"]))}"
      end
    rescue ArgumentError => e
      abort("qm start-issue: #{e.message}")
    end

    # A loose chat (LooseChat, no work item) in the running GUI, listed under
    # Loose in its chats list. Without a GUI, prints how to start one in a
    # terminal. The project defaults to the cwd's; the prompt is claude's argument
    # (--starter NAME: that config.yml loose starter's kickoff ending in it).
    def cmd_loose(argv)
      project = model = starter = nil
      parser = OptionParser.new do |o|
        o.on("--project PROJECT") { |v| project = v }
        o.on("--model MODEL") { |v| model = v }
        o.on("--starter NAME") { |v| starter = v }
      end
      rest = FreeTextArgs.parse(parser, argv)
      abort(%(usage: qm loose [--project P] [--model #{Aside::MODELS.join("|")}] [--starter NAME] [--] ["first prompt"])) if rest.size > 1
      abort("qm loose: unknown model #{model.inspect} (#{Aside::MODELS.join(", ")})") if model && !Aside::MODELS.include?(model)
      begin
        LooseChat.kickoff(starter, nil)
      rescue ArgumentError => e
        abort("qm loose: #{e.message}")
      end

      project ||= ProjectMap.new.project_for(@cwd || Dir.pwd)
      args = { "project" => project, "model" => model, "prompt" => rest.first, "starter" => starter }.compact
      if (reply = gui_action("loose", "loose-start", args: args, optional: true))
        puts "loose chat #{reply["id"]} started in the qm gui (#{project}) — under Loose in its chats list"
      else
        id = LooseChat.new_id
        plan = Launcher.new.loose_plan(id, project: project, model: model, prompt: LooseChat.kickoff(starter, rest.first))
        puts "no qm gui running — start the loose chat with:"
        puts "  cd #{Shellwords.escape(plan[:cwd])} && #{LooseChat::ENV_VAR}=#{id} QM_ITEM= #{Shellwords.join(plan[:argv])}"
      end
    end

    # The project of the repo this runs in, else config.yml's default project.
    def default_issue_project
      project = ProjectMap.new.project_for(@cwd || Dir.pwd)
      return project unless project == ProjectMap::NO_PROJECT

      ProjectConfig.current.default_project || project
    end

    def print_issue_preview(preview)
      puts "##{preview["number"]} #{preview["title"]} (#{preview["state"]}) — #{preview["url"]}"
      puts "  ⚠ the issue is closed" if preview["closed"]
      if (existing = preview["existing"])
        puts "  already tracked: #{existing["slug"]} (#{existing["state"]})"
      else
        puts "  project #{preview["project"]}, branch #{preview["branch"]}#{" (existing, reused)" if preview["reuse_branch"]}"
      end
    end

    # POSTs one action to the running GUI like its page does; a local process
    # sends no Origin, which the GUI's POST check lets through only for
    # LoopbackGuard::LOCAL_ACTIONS (a browser page sends one, and a foreign
    # one is refused). No GUI → say so and do nothing, or (optional) return
    # nil. Returns the action's reply; a refusal aborts with its error.
    def gui_action(name, cmd, slug: nil, args: {}, optional: false)
      port = Gui.port
      reply = begin
        http = Net::HTTP.new("127.0.0.1", port)
        http.open_timeout = 2
        http.read_timeout = 10
        response = http.post("/api/action", JSON.generate({ "cmd" => cmd, "slug" => slug, "args" => args }.compact),
                             "Content-Type" => "application/json")
        JSON.parse(response.body)
      rescue SystemCallError, Net::OpenTimeout
        return nil if optional

        abort("qm #{name}: no qm gui running on 127.0.0.1:#{port} — nothing done (it starts with `qm gui`)")
      rescue Net::ReadTimeout, IOError
        abort("qm #{name}: the qm gui on 127.0.0.1:#{port} did not answer in time — try again")
      rescue JSON::ParserError
        abort("qm #{name}: 127.0.0.1:#{port} did not answer like a qm gui")
      end
      abort("qm #{name}: #{reply["error"]}") unless reply["ok"]

      reply
    end
  end
end
