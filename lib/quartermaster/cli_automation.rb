# frozen_string_literal: true

module Quartermaster
  # `qm automation ...`: claude.ai cloud routines managed as kind: automation
  # work items with local files (AutomationStore).
  module CliAutomation
    COMMANDS = { "automation" => :cmd_automation }.freeze

    AUTOMATION_USAGE = <<~USAGE
      usage: qm automation new TITLE --project P [--description TEXT]
             qm automation edit SLUG
    USAGE

    private

    def cmd_automation(argv)
      case argv.shift
      when "new" then automation_new(argv)
      when "edit" then automation_chat("edit", automation_slug(argv))
      else abort(AUTOMATION_USAGE)
      end
    end

    # The item and its empty local files, then its chat with the brief.
    def automation_new(argv)
      project = description = nil
      parser = OptionParser.new do |o|
        o.on("--project PROJECT") { |v| project = v }
        o.on("--description TEXT") { |v| description = v }
      end
      rest = FreeTextArgs.parse(parser, argv)
      abort(AUTOMATION_USAGE) unless rest.size == 1 && project

      item = AutomationChat.create(rest.first, project: project, description: description)
      puts "#{item.slug}: created (#{project}), files in #{short_path(AUTOMATIONS_DIR)}"
      automation_chat("new", item.slug)
    rescue ArgumentError => e
      abort("qm automation new: #{e.message}")
    end

    def automation_slug(argv)
      abort(AUTOMATION_USAGE) unless argv.size == 1
      argv.first
    end

    # Opens (or resumes) the chat in the running GUI and brings the GUI up on
    # it; a chat already running gets nothing typed — the brief is printed to
    # paste by hand. Without a GUI, prints how to start it in a terminal.
    def automation_chat(name, slug)
      chat = AutomationChat.new(tmux: nil)
      item = chat.automation(slug)
      reply = gui_action("automation #{name}", "automation-chat", slug: item.slug, optional: true)
      if reply.nil?
        plan = chat.plan(item)
        abort("qm automation #{name}: #{item.slug} has a chat running outside the GUI — continue there") if plan[:mode] == :live
        puts "no qm gui running — start its chat with:"
        puts "  cd #{Shellwords.escape(plan[:cwd])} && QM_ITEM=#{item.slug} #{Shellwords.join(plan[:argv])}"
        return
      end

      ChatOpener.new(runner: @runner || CommandRunner.new).open(item.slug)
      if reply["attached"]
        puts "#{item.slug}: its chat is already running in the qm gui — nothing typed; paste this brief there if it needs it:"
        puts reply["brief"]
      else
        puts "#{item.slug}: its chat #{reply["mode"] == "resume" ? "resumed" : "started"} in the qm gui"
      end
    rescue ArgumentError => e
      abort("qm automation #{name}: #{e.message}")
    end
  end
end
