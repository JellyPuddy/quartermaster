# frozen_string_literal: true

module Quartermaster
  # The `qm automation …` subcommands and output for `runner: local`
  # automations (part of CliAutomation): their rows and runs from the run
  # log with no network, a manual run or retry followed by one tick so it
  # starts at once when it can, the tick itself and its LaunchAgent.
  module CliLocalAutomation
    private

    def local_automation_status(row, service)
      log = service.local_automations.run_log(row["slug"])
      last = log.recent(limit: 1).first
      "#{row["slug"]}: on this machine, #{log.queue.size} queued, #{log.live.size} live, " \
        "last run #{last ? "#{last.status} #{local_time(last.started_at || last.ended_at)}" : "none"}"
    end

    def tick_status
      installer = TickInstaller.new(runner: @runner || CommandRunner.new)
      last = AutomationTick.state["last_tick_at"]
      "tick: #{installer.installed? ? "installed" : "not installed (qm automation install-tick)"}" \
        "#{", last tick #{local_time(Time.iso8601(last))}" if last}"
    end

    def local_automation_show(detail, service)
      record = detail["entry"].record
      settings = detail["settings"]
      item = detail["item"]
      cron = record["cron"].to_s.strip
      label = detail["schedule"]
      puts record["name"]
      puts "item: #{detail["slug"]}  #{item&.project}  #{item&.state}" if item
      puts "schedule: #{label}#{"  (#{cron} Amsterdam time)" unless cron.empty? || label.include?(cron)}"
      puts "next run: #{local_time(detail["next_at"])}" if detail["next_at"]
      puts "enabled: #{record["enabled"] != false}  runner: local  model: #{record["model"] || "default"}"
      puts "guard: #{record["when"].to_s.strip.empty? ? "none — a due cron queues one run" : record["when"]}"
      puts "flow: #{settings["flow"]}  notify: #{settings["notify"]}  timeout: #{settings["timeout_minutes"]} min"
      puts "cwd: #{ChatFlow.new(tmux: nil).cwd(detail["entry"])}"
      puts "prompt: #{service.store.prompt_path(detail["slug"])}"
      puts "last guard error: #{detail["guard_error"]["error"]}" if detail["guard_error"]
      local_run_lines(detail["queue"], detail["recent"].first(10))
    end

    def automation_runs(argv)
      slug = automation_slug(argv)
      detail = automations.local_automations.detail(slug)
      local_run_lines(detail["queue"], detail["recent"])
    end

    def local_run_lines(queue, runs)
      puts "queued:#{" none" if queue.empty?}"
      queue.each { |run| puts "  #{run.id}  #{run.trigger}  #{run.key}#{"  waiting: #{run.waiting}" if run.waiting}" }
      puts "runs:#{" none" if runs.empty?}"
      runs.each do |run|
        detail = run.live? ? "tmux #{run.tmux}" : run.error
        puts "  #{run.id}  #{run.status}  #{local_time(run.started_at || run.ended_at)}  #{run.key}#{"  #{detail}" if detail}"
      end
    end

    # Queued run ids, then one tick so they start now when nothing holds them.
    def local_automation_run(service, slug, ids, note: "")
      return puts("#{slug}: the guard found nothing new") if ids.empty?

      summary = service.local_automations.tick.call
      started = Array(summary&.dig("started")).filter_map { |s, id| id if s == slug && ids.include?(id) }
      queued = ids - started
      parts = []
      parts << "started #{runs_phrase(started)}#{note}" unless started.empty?
      parts << "queued #{runs_phrase(queued)}#{note} — #{local_wait_reason(service, slug, queued, summary)}" unless queued.empty?
      puts "#{slug}: #{parts.join("; ")}"
    end

    def runs_phrase(ids) = ids.size == 1 ? "run #{ids.first}" : "#{ids.size} runs (#{ids.join(", ")})"

    def local_wait_reason(service, slug, ids, summary)
      waiting = ids.filter_map { |id| service.local_automations.run_log(slug).run(id)&.waiting }.first
      return "waiting: #{waiting}" if waiting
      return "the tick failed (see qm.log); the next tick starts it" if summary.nil?
      return "a tick is running; the next tick starts it" if summary["locked"]
      return "local automations are paused (qm config set automations.local_paused false)" if summary["paused"]
      return "held: #{summary["held"]}" if summary["held"]

      "the next tick starts it when a slot is free (#{summary["running"]} of #{summary["max_running"]} running)"
    end

    def automation_retry(argv)
      abort(CliAutomation::AUTOMATION_USAGE) unless argv.size == 2
      slug, old = argv
      service = automations
      id = service.local_automations.retry(slug, old)
      local_automation_run(service, slug, [id], note: " (retry of #{old})")
    end

    # One scheduler pass (what launchd runs every 5 minutes); quiet when it
    # did nothing and nobody is watching. --dry-run [SLUG] only runs guards.
    def automation_tick(argv)
      return automation_tick_dry_run(argv.drop(1)) if argv.first == "--dry-run"
      abort(CliAutomation::AUTOMATION_USAGE) unless argv.empty?

      summary = automations.local_automations.tick.call
      return puts("tick failed — see qm.log") if summary.nil?
      return puts("another tick is running") if summary["locked"]

      lines = %w[queued started finished closed timed_out failed].filter_map do |what|
        runs = summary[what]
        "#{what.tr("_", " ")} #{runs.map { |slug, id| "#{slug}/#{id}" }.join(", ")}" unless runs.empty?
      end
      lines += summary["problems"].map { |slug, problem| "#{slug}: #{problem}" }
      lines << "held: #{summary["held"]}" if summary["held"]
      lines << "local automations are paused" if summary["paused"]
      lines << "nothing to do (#{summary["running"]} of #{summary["max_running"]} running)" if lines.empty? && $stdout.tty?
      lines.each { |line| puts line }
    end

    def automation_tick_dry_run(argv)
      abort(CliAutomation::AUTOMATION_USAGE) if argv.size > 1
      service = automations
      slugs = argv.empty? ? service.local.select { |row| LocalAutomations.local?(row["entry"]) }.map { |row| row["slug"] } : argv
      puts "no local automations" if slugs.empty?
      slugs.each { |slug| dry_run_lines(service, slug, single: !argv.empty?) }
    end

    def dry_run_lines(service, slug, single:)
      entry = service.store.read(slug)
      if !single && entry.record["when"].to_s.strip.empty?
        next_at = service.local_automations.detail(slug)["next_at"]
        return puts("#{slug}: no guard — #{next_at ? "the next cron run queues one run at #{local_time(next_at)}" : "manual only"}")
      end
      dry = service.local_automations.tick.dry_run(slug)
      dry.items.each { |item| puts "#{slug}: would queue #{item["key"]}" }
      dry.seen.each { |item| puts "#{slug}: already seen #{item["key"]}" }
      dry.problems.each { |p| puts "#{slug}: refused #{p["item"] ? "#{p["item"]["key"] || p["item"]} " : ""}— #{p["error"]}" }
      puts "#{slug}: the guard prints nothing" if dry.items.empty? && dry.seen.empty? && dry.problems.empty?
    rescue ArgumentError => e
      raise if single

      puts "#{slug}: #{e.message}"
    end

    def automation_install_tick(argv)
      installer = TickInstaller.new(runner: @runner || CommandRunner.new)
      return print(installer.plist) if argv == ["--print"]
      abort(CliAutomation::AUTOMATION_USAGE) unless argv.empty?

      installer.install
      puts "installed #{installer.plist_path}: launchd runs `qm automation tick` every 5 minutes, output in #{installer.log_path}"
    end

    def automation_uninstall_tick(argv)
      abort(CliAutomation::AUTOMATION_USAGE) unless argv.empty?
      installer = TickInstaller.new(runner: @runner || CommandRunner.new)
      installer.uninstall
      puts "uninstalled #{TickInstaller::LABEL}: no more ticks"
    end

    def local_time(time) = time&.getlocal&.strftime("%Y-%m-%d %H:%M")
  end
end
