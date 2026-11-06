# frozen_string_literal: true

module Quartermaster
  # Launching an item's sessions and its workspace: resume/start, the dev server, the
  # IDE and terminal (work-on, pf-switch, ide and term dispatch in CLI#run).
  module CliWorkspace
    COMMANDS = {
      "resume" => :cmd_resume,
      "start" => :cmd_start,
      "pf-mode" => :cmd_pf_mode
    }.freeze

    private

    def cmd_resume(argv)
      slug = argv.shift
      options = {}
      OptionParser.new do |o|
        o.on("--session SESSION_ID") { |v| options[:session_id] = v }
        o.on("--here") { options[:here] = true }
      end.parse(argv)
      abort("usage: qm resume SLUG [--session ID] [--here]") unless slug

      Launcher.new.resume(WorkItem.find(slug), session_id: options[:session_id], here: options[:here] || false)
    end

    def cmd_start(argv)
      slug = argv.shift
      here = false
      OptionParser.new { |o| o.on("--here") { here = true } }.parse(argv)
      abort("usage: qm start SLUG [--here]") unless slug

      Launcher.new.start(WorkItem.find(slug), here: here)
    end

    # Bare `qm pf-mode SLUG` prints the mode, like `qm board SLUG`.
    def cmd_pf_mode(argv)
      slug, mode = argv
      abort("usage: qm pf-mode SLUG [MODE]") unless slug

      item = WorkItem.find(slug)
      server = item.dev_server
      unless mode
        return puts(item.pf_mode || abort("qm: '#{slug}' is #{item.project}, which has no dev server: run " \
                                          "`#{ProjectConfig.current.settings(item.project).config_command("dev_server.command", "<command>")}`"))
      end

      item.update_pf_mode(mode)
      puts "#{slug} → #{server.command} #{mode}"
    end

    def cmd_workspace(action, name, argv, mode:)
      slug = argv.shift
      options = {}
      OptionParser.new do |o|
        o.on("--mode MODE") { |v| options[:mode] = v } if mode
        o.on("--worktree PATH") { |v| options[:worktree] = v }
      end.parse(argv)
      abort("usage: qm #{name} SLUG#{mode ? " [--mode MODE]" : ""} [--worktree PATH]") unless slug

      report = Workspace.new.public_send(action, WorkItem.find(slug), **options)
      target = report.target
      puts paint("⚠ #{target.warning}", 33) if target.warning
      report.steps.each { |step| puts step }
      target.alternatives.each do |branch, path|
        puts paint("  also: #{branch} @ #{short_path(path)}  (--worktree #{path})", 90)
      end
    end

    def cmd_pf_status
      server = ProjectConfig.current.dev_server
      abort("qm: no project configures a dev server: run `qm config set projects.<project>.dev_server.command <command>`") unless server

      status = Pf.new(server: server).status
      state = status.running ? (status.switching ? "switching" : "running") : "stopped"
      last = status.mode ? "#{status.mode} @ #{short_path(status.root)}" : "never switched"
      puts "#{server.command} #{state}: #{last}"
    end
  end
end
