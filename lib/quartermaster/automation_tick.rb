# frozen_string_literal: true

module Quartermaster
  # One scheduler tick for local automations (launchd runs `qm automation
  # tick` every 300 s). Under a non-blocking flock on `automations/tick.lock`
  # it checks each enabled automation's cron, runs the guard of a due one or
  # queues its coalesced cron run, then starts queued runs oldest-first
  # through their flows while the cap has free slots and no usage limit
  # holds; it writes `automations/tick.json` and never waits for a run.
  class AutomationTick
    INTERVAL = 300
    VERSION = 1
    # A live run's session in these states holds a slot; "none" is a run
    # whose first prompt the hooks haven't reported yet.
    BUSY = %w[working waiting none].freeze

    DryRun = Data.define(:items, :seen, :problems)

    def self.state_path(dir = AUTOMATIONS_DIR) = File.join(dir, "tick.json")

    # What the last tick wrote to tick.json, {} when nothing readable.
    def self.state(dir = AUTOMATIONS_DIR)
      path = state_path(dir)
      File.exist?(path) && Quartermaster.json_object(File.read(path)) || {}
    rescue SystemCallError
      {}
    end

    def initialize(runner: CommandRunner.new, tmux: Tmux.new, config: nil, dir: AUTOMATIONS_DIR, flows: nil,
                   rate_limits: RateLimits.new)
      @tmux = tmux
      @config = config
      @dir = dir
      @store = AutomationStore.new(dir)
      @flows = flows || AutomationFlows.new(tmux: tmux, runner: runner)
      @guard = AutomationGuard.new(runner: runner)
      @rate_limits = rate_limits
    end

    # Runs one tick; answers what it did ({"queued", "started", "held",
    # "paused", …}), {"locked" => true} when another tick holds the lock, or
    # nil after an error (logged to qm.log, never raised).
    def call(now: Time.now)
      FileUtils.mkdir_p(@dir)
      File.open(File.join(@dir, "tick.lock"), File::RDWR | File::CREAT) do |lock|
        return { "locked" => true } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        tick(now)
      end
    rescue StandardError => e
      Quartermaster.log_error("automation-tick", e)
      nil
    end

    # The items the automation's guard would queue now, without writing:
    # new ones the flow can take, ones already seen, and refused ones.
    def dry_run(slug)
      entry = local_entry(slug)
      command = entry.record["when"].to_s
      raise ArgumentError, "#{slug} has no guard (when:) — a due cron queues one run without an item" if command.strip.empty?

      items, problems = @guard.run(command, cwd: cwd(entry))
      seen = RunLog.new(slug, dir: @dir).seen_keys.dup
      old, fresh = items.partition { |item| !seen.add?(item["key"]) }
      flow = AutomationStore.local_settings(entry.record)["flow"]
      refused, ok = fresh.partition { |item| @flows.problem(flow, item) }
      DryRun.new(items: ok, seen: old,
                 problems: problems + refused.map { |item| { "error" => @flows.problem(flow, item), "item" => item } })
    end

    # Runs the guard now and queues its new items (trigger manual unless
    # given); returns the queued run ids. Raises AutomationGuard::Failed
    # after recording it as a guard error.
    def queue_guard(slug, trigger: "manual", now: Time.now)
      entry = local_entry(slug)
      queue_guard_items(entry, RunLog.new(slug, dir: @dir), trigger: trigger, now: now, raise_failure: true)
    end

    private

    def tick(now)
      @summary = { "queued" => [], "started" => [], "failed" => [], "problems" => {} }
      previous = self.class.state(@dir)
      settings = config.local_automations
      locals = @store.list.select { |entry| entry.record["runner"] == "local" }
      enabled = locals.reject { |entry| entry.record["enabled"] == false }
      paused = settings.paused
      since_tick = time(previous["last_tick_at"])
      enabled.each { |entry| guarded(entry) { check(entry, since_tick, now) } } unless paused
      held = hold(now, settings)
      @sessions = SessionLog.new
      @attention = ChatAttention.new(session_log: @sessions)
      running = locals.sum { |entry| RunLog.new(entry.slug, dir: @dir).live.count { |run| busy?(run) } }
      start_queued(enabled, settings.max_running.to_i - running, now) unless paused || held
      @summary.merge!("paused" => paused, "held" => held, "running" => running + @summary["started"].size,
                      "max_running" => settings.max_running)
      write_state(now)
      @summary
    end

    def config = @config || ProjectConfig.current

    def local_entry(slug)
      entry = @store.read(slug)
      raise ArgumentError, "no automation #{slug}" unless entry
      raise ArgumentError, "#{slug} runs on claude.ai, not locally" unless entry.record["runner"] == "local"

      entry
    end

    # One automation's trouble is recorded and never stops the others.
    def guarded(entry)
      yield
    rescue StandardError => e
      @summary["problems"][entry.slug] = e.message
      Quartermaster.log_error("automation-tick #{entry.slug}", e)
    end

    # A due cron minute in (last check or last tick, now] runs the guard, or
    # queues one cron run without one; either way the minute is checked.
    def check(entry, since_tick, now)
      cron = entry.record["cron"].to_s.strip
      return if cron.empty?

      error = LocalCron.error(cron)
      return @summary["problems"][entry.slug] = "cron #{cron.inspect}: #{error}" if error

      AutomationStore.validate_local(entry.record)
      log = RunLog.new(entry.slug, dir: @dir)
      since = [log.last_cron_check, since_tick].compact.max || now - INTERVAL
      due = LocalCron.new(cron).last_due(since: since, now: now)
      return unless due

      if entry.record["when"].to_s.strip.empty?
        queue_cron(entry, log, due, now)
      else
        ids = queue_guard_items(entry, log, trigger: "guard", now: now)
        @summary["queued"].concat(ids.map { |id| [entry.slug, id] })
      end
      log.checked(at: now)
    end

    def queue_cron(entry, log, due, now)
      flow = AutomationStore.local_settings(entry.record)["flow"]
      if (problem = @flows.problem(flow, nil))
        log.guard_error(error: problem, at: now)
      elsif (id = log.enqueue_cron(due: due, flow: flow, at: now))
        @summary["queued"] << [entry.slug, id]
      end
    end

    def queue_guard_items(entry, log, trigger:, now:, raise_failure: false)
      begin
        items, problems = @guard.run(entry.record["when"].to_s, cwd: cwd(entry))
      rescue AutomationGuard::Failed => e
        log.guard_error(error: e.message, at: now)
        raise if raise_failure

        return []
      end
      flow = AutomationStore.local_settings(entry.record)["flow"]
      log.guard_ran(items: items.size, at: now)
      problems.each { |p| log.guard_error(error: p["error"], item: p["item"], at: now) }
      items.filter_map do |item|
        if (problem = @flows.problem(flow, item))
          log.guard_error(error: problem, item: item, at: now)
          next
        end
        log.enqueue_item(key: item["key"], item: item, flow: flow, trigger: trigger, at: now)
      end
    end

    def cwd(entry) = ChatFlow.new(tmux: @tmux).cwd(entry)

    # "5h at 84%" while a usage window is at or over its hold; nil when no
    # limit holds or the snapshot is stale (its 5-hour window has reset).
    def hold(now, settings)
      limits = @rate_limits.payload
      return nil unless limits

      five = limits["fiveHour"]
      return nil if five && five["resetsAt"] && Time.iso8601(five["resetsAt"]) <= now

      [["fiveHour", "5h", settings.hold_five_hour], ["sevenDay", "7d", settings.hold_seven_day]]
        .each do |name, label, limit|
          window = limits[name]
          next unless window && window["usedPercentage"] >= limit
          next if window["resetsAt"] && Time.iso8601(window["resetsAt"]) <= now

          return "#{label} at #{window["usedPercentage"].round}%"
        end
      nil
    end

    # A live run holds a slot while its session works, waits on background
    # work or hasn't reported its first prompt; before the session's
    # SessionStart hook ran, while its tmux session lives.
    def busy?(run)
      session = run.session_id && @sessions.session_for(run.session_id)
      return @tmux.live?(run.tmux.to_s) unless session

      session.live? && BUSY.include?(@attention.turn_for(session)[:state])
    end

    def start_queued(enabled, slots, now)
      queue = enabled.flat_map do |entry|
        log = RunLog.new(entry.slug, dir: @dir)
        log.queue.map { |run| [entry, log, run] }
      end
      queue.each_with_index.sort_by { |(_, _, run), i| [run.queued_at, i] }.map(&:first).each do |entry, log, run|
        break if slots <= 0

        slots -= 1 if start(entry, log, run, now)
      end
    end

    # Starts one queued run; true when a session started.
    def start(entry, log, run, now)
      session_id = SecureRandom.uuid
      reply = @flows.start(entry, run.item, entry.prompt, run_id: run.id, session_id: session_id)
      if reply[:waiting]
        log.waiting(run.id, reason: reply[:waiting], at: now)
        return false
      end
      log.started(run.id, session_id: session_id, tmux: reply[:tmux], item_slug: reply[:item_slug], at: now)
      @summary["started"] << [entry.slug, run.id]
      true
    rescue StandardError => e
      log.failed(run.id, error: e.message, at: now)
      @summary["failed"] << [entry.slug, run.id]
      false
    end

    def write_state(now)
      state = { "v" => VERSION, "last_tick_at" => now.getutc.iso8601 }.merge(@summary.slice("paused", "held", "running",
                                                                                            "max_running", "problems"))
      AtomicFile.write(self.class.state_path(@dir), "#{JSON.pretty_generate(state)}\n")
    end

    def time(value)
      value && Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
