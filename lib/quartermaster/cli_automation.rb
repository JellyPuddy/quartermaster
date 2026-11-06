# frozen_string_literal: true

module Quartermaster
  # `qm automation …`: the user's claude.ai routines through the Automations
  # service. A RoutinesClient error (off, token expired, API changed) is an
  # ArgumentError, so it ends the command with its message and exit 1.
  module CliAutomation
    COMMANDS = { "automation" => :cmd_automation }.freeze

    AUTOMATION_USAGE = "usage: qm automation list | show SLUG | new TITLE --project P [--description TEXT] | " \
                       "edit SLUG | adopt TRIGGER_ID --project P [--slug S] | " \
                       "push SLUG [--force] | pull SLUG | pause SLUG | resume SLUG | run SLUG | delete SLUG [--yes]"
    AUTOMATION_SUBCOMMANDS = { "list" => :automation_list, "show" => :automation_show, "new" => :automation_new,
                               "edit" => :automation_edit, "adopt" => :automation_adopt, "push" => :automation_push, "pull" => :automation_pull, "pause" => :automation_pause,
                               "resume" => :automation_resume, "run" => :automation_run,
                               "delete" => :automation_delete }.freeze

    private

    def cmd_automation(argv)
      method = AUTOMATION_SUBCOMMANDS[argv.shift] or abort(AUTOMATION_USAGE)
      send(method, argv)
    end

    def automations = Automations.new(client: RoutinesClient.new(runner: @runner || CommandRunner.new))

    # The one word left once a command's flags are taken out.
    def automation_slug(argv) = argv.size == 1 ? argv.shift : abort(AUTOMATION_USAGE)

    # The local files at once, then one list call for each routine's status
    # and the routines qm doesn't manage yet.
    def automation_list(_argv)
      service = automations
      rows = service.local
      rows.each { |row| puts automation_row(row) }
      puts "no automations yet" if rows.empty?
      $stdout.flush
      overview = service.overview(rows)
      overview["rows"].each { |row| puts "#{row["slug"]}: #{automation_status(row)}" }
      return if overview["unmanaged"].empty?

      puts "", "Not managed by qm (qm automation adopt ID --project P):"
      overview["unmanaged"].each do |routine|
        puts "  #{routine["id"]}  #{routine["name"]}  #{LocalSchedule.from_cron(routine["cron_expression"]).label}"
      end
    end

    def automation_row(row)
      record = row["entry"].record
      item = row["item"]
      [row["slug"], item&.project || "-", item&.state || "-", LocalSchedule.from_cron(record["cron"]).label,
       record["enabled"] == false ? "paused" : "enabled"].join("  ")
    end

    def automation_status(row)
      remote = row["remote"]
      return row["entry"].record["routine"] ? "not on claude.ai" : "not pushed yet" unless remote

      run = remote["last_run"].is_a?(Hash) ? remote["last_run"] : {}
      parts = ["last run #{run_status(run["status"])}#{" #{short_time(run["finished_at"] || run["fired_at"])}" if run["status"]}",
               "next #{short_time(remote["next_run_at"]) || "-"}"]
      parts << "changed outside qm (pull or push --force)" if row["drift"]
      parts.join(", ")
    end

    def automation_show(argv)
      service = automations
      detail = service.detail(automation_slug(argv))
      record = detail["entry"].record
      item = detail["item"]
      puts record["name"]
      puts "item: #{detail["slug"]}  #{item&.project}  #{item&.state}" if item
      puts "schedule: #{LocalSchedule.from_cron(record["cron"]).label}  (#{record["cron"]} UTC)"
      puts "enabled: #{record["enabled"] != false}  runner: #{record["runner"]}  model: #{record["model"]}"
      puts "repos: #{Array(record["sources"]).map { |s| s.dig("git_repository", "url") || s["url"] }.compact.join(", ")}"
      puts "connectors: #{Array(record["connectors"]).map { |c| c["name"] }.compact.join(", ")}"
      puts "prompt: #{service.store.prompt_path(detail["slug"])}"
      puts "routine: #{record["routine"] ? Automations.routine_url(record["routine"]) : "not pushed yet"}"
      puts "changed outside qm: `qm automation pull #{detail["slug"]}` or `qm automation push #{detail["slug"]} --force`" if detail["drift"]
      puts "runs:#{" none" if detail["runs"].empty?}"
      detail["runs"].each do |r|
        puts "  #{r["status"] || "?"}  #{short_time(r["created_at"]) || "-"}  #{r["title"]}  #{r["url"]}"
      end
    end

    def automation_adopt(argv)
      options = {}
      OptionParser.new do |o|
        o.on("--project PROJECT") { |v| options[:project] = v }
        o.on("--slug SLUG") { |v| options[:slug] = v }
      end.parse!(argv)
      id = argv.shift
      abort(AUTOMATION_USAGE) unless id && options[:project]

      entry = automations.adopt(id, project: options[:project], slug: options[:slug])
      puts "adopted #{id} as #{entry.slug}"
    end

    def automation_push(argv)
      force = argv.delete("--force")
      slug = automation_slug(argv)
      result = automations.push(slug, force: !force.nil?)
      puts result["changes"].empty? ? "#{slug}: nothing to push" : "#{slug}: #{result["changes"].join("; ")}"
    end

    def automation_pull(argv)
      slug = automation_slug(argv)
      changes = automations.pull(slug)
      puts changes.empty? ? "#{slug}: already in sync" : "#{slug}: pulled #{changes.join(", ")} (previous files kept as .bak)"
    end

    def automation_pause(argv) = automation_toggle(argv, :pause)

    def automation_resume(argv) = automation_toggle(argv, :resume)

    def automation_toggle(argv, action)
      slug = automation_slug(argv)
      automations.public_send(action, slug)
      puts "#{slug}: #{action == :pause ? "paused" : "resumed"}"
    end

    def automation_run(argv)
      slug = automation_slug(argv)
      service = automations
      service.run(slug)
      puts "#{slug}: running — #{Automations.routine_url(service.store.read(slug).record["routine"])}"
    end

    def automation_delete(argv)
      yes = argv.delete("--yes")
      slug = automation_slug(argv)
      service = automations
      entry = service.store.read(slug) or raise ArgumentError, "no automation '#{slug}'"
      unless yes
        $stderr.print "Delete #{entry.record["name"] || slug} on claude.ai and resolve #{slug}? [y/N] "
        abort("qm automation: not deleted") unless $stdin.gets.to_s.strip.downcase.start_with?("y")
      end
      case service.delete(slug)
      when :paused then puts "#{slug}: paused; delete it on claude.ai: #{Automations.routine_url(entry.record["routine"])}"
      when :deleted then puts "#{slug}: deleted"
      else puts "#{slug}: removed (it was never pushed)"
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

    def automation_edit(argv) = automation_chat("edit", automation_slug(argv))

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

    def run_status(status) = status.to_s.empty? ? "none" : status.to_s.sub(/\AROUTINE_RUN_STATUS_/, "").downcase

    def short_time(iso)
      return nil unless iso.is_a?(String) && !iso.empty?

      Time.iso8601(iso).utc.strftime("%Y-%m-%d %H:%M UTC")
    rescue ArgumentError
      iso
    end
  end
end
