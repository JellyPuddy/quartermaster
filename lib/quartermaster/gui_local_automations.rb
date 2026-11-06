# frozen_string_literal: true

module Quartermaster
  # The Automations tab's `runner: local` part, never the network: GuiAutomations
  # hands it every local slug and asks it for the tab header's tick status.
  # Rows and detail read the run logs and tick.json; Run now, Enable (with
  # "mark existing as seen"), Retry and the tick's Install/Uninstall run as
  # GuiJobs jobs (a guard may take 60 s, a tick starts runs, launchctl is an
  # external tool); the pause toggle writes config.yml; Resume reopens an
  # ended chat run under its own tmux name.
  class GuiLocalAutomations
    STALE_TICK = 15 * 60
    ACTIONS = %w[apply pause resume run delete retry resume-run].freeze

    def initialize(jobs:, store:, runner:, tmux:, installer: nil)
      @jobs = jobs
      @store = store
      @tmux = tmux
      @local = LocalAutomations.new(store: store, runner: runner, tmux: tmux)
      @installer = installer || TickInstaller.new(runner: runner)
    end

    attr_reader :local

    def row(entry, item, now: Time.now)
      record = entry.record
      log = @local.run_log(entry.slug)
      last = log.recent(limit: 1).first
      cron = record["cron"].to_s.strip
      { "slug" => entry.slug, "name" => record["name"] || item&.title || entry.slug, "project" => item&.project,
        "state" => item&.state, "cron" => record["cron"], "schedule" => schedule(cron), "enabled" => record["enabled"] != false,
        "runner" => "local", "routine" => nil, "drift" => false, "missing" => false,
        "nextRunAt" => (LocalCron.next_after(cron, now)&.utc&.iso8601 unless cron.empty? || LocalCron.error(cron)),
        "queued" => log.queue.size, "live" => log.live.size,
        "lastRun" => last && { "status" => last.status, "at" => iso(last.started_at || last.ended_at) } }
    end

    # The tab header's local part: the tick (installed, last tick, stale
    # when enabled local automations went 15 minutes without one), the
    # global pause and the last tick's usage hold.
    def header(entries, now: Time.now)
      state = AutomationTick.state(@store.dir)
      settings = ProjectConfig.current.local_automations
      last = time(state["last_tick_at"])
      enabled = entries.any? { |e| LocalAutomations.local?(e) && e.record["enabled"] != false }
      { "count" => entries.count { |e| LocalAutomations.local?(e) }, "installed" => @installer.installed?,
        "lastTickAt" => state["last_tick_at"], "stale" => enabled && (last.nil? || now - last > STALE_TICK),
        "paused" => settings.paused == true, "held" => state["held"], "running" => state["running"],
        "maxRunning" => settings.max_running }
    end

    def detail(entry, item)
      d = @local.detail(entry.slug)
      record = entry.record
      settings = d["settings"]
      chats = @tmux.sessions
      row(entry, item).merge(
        "prompt" => entry.prompt, "model" => record["model"], "promptPath" => @store.prompt_path(entry.slug),
        "ymlPath" => @store.yml_path(entry.slug), "guard" => presence(record["when"]), "flow" => settings["flow"],
        "notify" => settings["notify"], "timeoutMinutes" => settings["timeout_minutes"],
        "permissionMode" => record["permission_mode"], "allowedTools" => Array(record["allowed_tools"]),
        "cwd" => Quartermaster.shorten_home(ChatFlow.new(tmux: @tmux).cwd(entry)),
        "guardError" => d["guard_error"] && { "error" => d["guard_error"]["error"], "at" => d["guard_error"]["at"] },
        "queue" => d["queue"].map do |run|
          { "id" => run.id, "trigger" => run.trigger, "subject" => subject(run), "queuedAt" => iso(run.queued_at), "waiting" => run.waiting }
        end,
        "runs" => d["recent"].map { |run| run_payload(run, chats) }, "runsState" => "ok"
      )
    end

    # A local action: [the answer, or nil for a verb that isn't one].
    def act(verb, slug, request)
      case verb
      when "apply" then done(slug, "saved") { save_edits(slug, request) }
      when "resume-run" then resume_run(slug, request["run"].to_s)
      when "pause" then done(slug, "paused") { @local.pause(slug) }
      when "delete" then done(slug, "deleted") { @local.delete(slug) }
      else job(slug, verb) { run_action(verb, slug, request) }
      end
    end

    def install_tick(install)
      @jobs.background("automation-tick", install ? "installing the tick" : "removing the tick") do
        install ? @installer.install : @installer.uninstall
        { "ok" => true, "message" => install ? "tick installed: launchd runs `qm automation tick` every 5 minutes" : "tick uninstalled",
          "automation" => nil }
      end
    end

    # The global pause, written to config.yml as `qm config set` would.
    def set_paused(paused)
      ConfigFile.load.set("automations.local_paused", paused == true).write!
      { "ok" => true, "paused" => paused == true }
    rescue ConfigFile::Invalid, ConfigFile::Stale => e
      raise ArgumentError, "config.yml not saved: #{e.message}"
    end

    private

    # A quick local file change, answered at once.
    def done(slug, what)
      yield
      { "ok" => true, "message" => "#{slug}: #{what}", "automation" => slug }
    end

    def job(slug, verb, &)
      @jobs.background("automation-#{slug}", verb == "resume" ? "enabling" : verb) do
        { "ok" => true, "message" => yield, "automation" => slug }
      end
    end

    def run_action(verb, slug, request)
      case verb
      when "resume"
        marked = @local.resume(slug, skip_existing: request["skipExisting"] == true)
        "#{slug}: enabled#{", #{marked} existing #{marked == 1 ? "item" : "items"} marked seen" if request["skipExisting"] == true}"
      when "run" then started_message(slug, @local.run(slug), "run")
      when "retry" then started_message(slug, [@local.retry(slug, request["run"].to_s)], "retry")
      end
    end

    # Queued run ids, then one tick so they start now when nothing holds them.
    def started_message(slug, ids, what)
      return "#{slug}: the guard found nothing new" if ids.empty?

      summary = @local.tick.call
      started = Array(summary&.dig("started")).count { |s, id| s == slug && ids.include?(id) }
      queued = ids.size - started
      parts = []
      parts << "started #{started} #{what}#{"s" if started > 1}" if started.positive?
      parts << "queued #{queued} (#{wait_reason(slug, ids, summary)})" if queued.positive?
      "#{slug}: #{parts.join("; ")}"
    end

    def wait_reason(slug, ids, summary)
      waiting = ids.filter_map { |id| @local.run_log(slug).run(id)&.waiting }.first
      return "waiting: #{waiting}" if waiting
      return "the next tick starts it" if summary.nil? || summary["locked"]
      return "local automations are paused" if summary["paused"]
      return "held: #{summary["held"]}" if summary["held"]

      "#{summary["running"]} of #{summary["max_running"]} running"
    end

    # Apply saves the local files only: a local automation has nothing to push.
    def save_edits(slug, request)
      entry = @store.read(slug)
      changes = {}
      if request.key?("cron")
        cron = request["cron"].to_s.strip
        error = cron.empty? ? nil : LocalCron.error(cron)
        raise ArgumentError, error if error

        changes["cron"] = cron
      elsif request.key?("days")
        changes["cron"] = LocalCron.to_cron(days: Array(request["days"]), time: request["time"])
      end
      @store.write(slug, changes, request.key?("prompt") ? request["prompt"].to_s : entry.prompt)
    end

    # Resume: an ended chat run's session again, in a tmux of its own name.
    def resume_run(slug, run_id)
      entry = @store.read(slug)
      run = @local.run_log(slug).run(run_id) or raise ArgumentError, "no run #{run_id} in #{slug}"
      raise ArgumentError, "run #{run_id} has no session to resume" unless run.session_id && run.flow == "chat"

      name = ChatFlow.new(tmux: @tmux).resume(entry, run)
      { "ok" => true, "name" => name, "message" => "#{slug}: run #{run_id} resumed" }
    end

    def run_payload(run, chats)
      own = run.flow == "chat"
      name = own ? run.tmux : run.item_slug
      live = own ? chats.include?(name.to_s) : !name.nil?
      { "id" => run.id, "status" => run.status, "trigger" => run.trigger, "subject" => subject(run), "error" => run.error,
        "startedAt" => iso(run.started_at), "endedAt" => iso(run.finished_at || run.ended_at), "retriedAs" => run.retried_as,
        "chat" => (name if live), "runChat" => own, "resumable" => own && !live && !run.session_id.nil?,
        "retryable" => !run.live? && run.retried_as.nil? }
    end

    def subject(run)
      item = run.item
      (item.is_a?(Hash) && (item["title"] || item["key"])) || run.key
    end

    def schedule(cron)
      return nil if cron.empty?
      return { "label" => "#{cron} (invalid: #{LocalCron.error(cron)})", "raw" => true } if LocalCron.error(cron)

      c = LocalCron.new(cron)
      { "label" => c.label, "days" => c.days, "time" => c.time, "raw" => !c.simple? }
    end

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s

    def iso(time) = time&.getutc&.iso8601

    def time(value)
      value && Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
