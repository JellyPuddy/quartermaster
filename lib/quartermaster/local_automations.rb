# frozen_string_literal: true

module Quartermaster
  # What the CLI and the GUI do with a `runner: local` automation, never over
  # the network: its runs from the run log, a manual run, pause and resume
  # (the item's state follows, with a history note), retry and delete. The
  # guard and the tick are the scheduler's own (AutomationTick).
  class LocalAutomations
    def self.local?(entry) = entry&.record&.dig("runner") == "local"

    def initialize(store: AutomationStore.new, runner: CommandRunner.new, tmux: nil)
      @store = store
      @runner = runner
      @tmux = tmux
    end

    def tick = @tick ||= AutomationTick.new(runner: @runner, tmux: @tmux || Tmux.new, dir: @store.dir)

    def run_log(slug) = RunLog.new(slug, dir: @store.dir)

    # One local automation with its settings (defaults filled), schedule,
    # queue, live and recent runs and its last guard error.
    def detail(slug)
      entry = entry!(slug)
      log = run_log(slug)
      cron = entry.record["cron"].to_s.strip
      { "slug" => slug, "entry" => entry, "item" => item_or_nil(slug), "settings" => AutomationStore.local_settings(entry.record),
        "schedule" => self.class.schedule_label(cron), "next_at" => (LocalCron.next_after(cron, Time.now) unless cron.empty? || LocalCron.error(cron)),
        "queue" => log.queue, "live" => log.live, "recent" => log.recent, "guard_error" => log.last_guard_error }
    end

    # "every day 08:00", the cron as Amsterdam time, or manual only.
    def self.schedule_label(cron)
      return "manual only (no cron)" if cron.to_s.strip.empty?

      LocalCron.error(cron) ? "#{cron} (invalid: #{LocalCron.error(cron)})" : LocalCron.label(cron)
    end

    # Queues a manual run now and answers the queued run ids: with a guard,
    # one per new item it prints; without one, a single run with no item.
    def run(slug, now: Time.now)
      entry = entry!(slug)
      return tick.queue_guard(slug, trigger: "manual", now: now) unless entry.record["when"].to_s.strip.empty?

      flow = AutomationStore.local_settings(entry.record)["flow"]
      problem = AutomationFlows.new(tmux: @tmux, runner: @runner).problem(flow, nil)
      raise ArgumentError, "#{slug}: #{problem}" if problem

      [run_log(slug).enqueue(key: "manual:#{now.getutc.iso8601}", item: nil, flow: flow, trigger: "manual", at: now)]
    end

    def pause(slug) = set_enabled(entry!(slug), false, "paused")

    # Enables the automation; `skip_existing` first records the keys its guard
    # prints now as seen, so only items that appear later queue runs.
    # Answers how many keys it marked.
    def resume(slug, skip_existing: false)
      entry = entry!(slug)
      unless skip_existing
        set_enabled(entry, true, "resumed")
        return 0
      end
      raise ArgumentError, "#{slug} has no guard (when:), so there are no existing items to mark seen" if entry.record["when"].to_s.strip.empty?

      keys = tick.dry_run(slug).items.map { |item| item["key"] }
      run_log(slug).mark_seen(keys) unless keys.empty?
      set_enabled(entry, true, "resumed; #{keys.size} existing guard #{keys.size == 1 ? "item" : "items"} marked seen")
      keys.size
    end

    # Queues an ended run's item again; answers the new run id.
    def retry(slug, run_id)
      entry!(slug)
      run_log(slug).retry(run_id)
    end

    # Removes the files and the run log and resolves the item (its notes
    # kept); refused while a run is live.
    def delete(slug)
      entry!(slug)
      live = run_log(slug).live
      raise ArgumentError, "#{slug} has #{live.size == 1 ? "a live run" : "#{live.size} live runs"} — stop or finish its runs first" unless live.empty?

      @store.delete_local(slug)
      item = item_or_nil(slug)
      item&.add_note("deleted", kind: "history")
      item&.update_state("resolved")
      :deleted
    end

    private

    def entry!(slug)
      entry = @store.read(slug) or raise ArgumentError, "no automation '#{slug}'"
      raise ArgumentError, "#{slug} runs on claude.ai, not locally" unless self.class.local?(entry)

      entry
    end

    def set_enabled(entry, enabled, note)
      @store.write(entry.slug, { "enabled" => enabled }, entry.prompt)
      item = item_or_nil(entry.slug) or return
      item.add_note(note, kind: "history")
      state = Automations::STATE_FOR_ENABLED.fetch(enabled)
      item.update_state(state) unless item.state == state
    end

    def item_or_nil(slug) = File.exist?(WorkItem.path_for(slug)) ? WorkItem.find(slug) : nil
  end
end
