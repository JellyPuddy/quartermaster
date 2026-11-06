# frozen_string_literal: true

module Quartermaster
  # One local automation's runs: `automations/<slug>.runs.jsonl`, append-only,
  # one `{v, at, event, …}` line per event, and the fold of it. Writers name
  # the event; the fold gives the queue, live and recent runs, the keys
  # already seen, the last guard error and the last cron check.
  class RunLog
    VERSION = 1
    ENDINGS = %w[timed_out closed failed].freeze

    Run = Struct.new(:id, :key, :item, :flow, :trigger, :queued_at, :started_at, :session_id, :tmux, :item_slug,
                     :waiting, :finished_at, :ended_at, :status, :error, :retried_as, keyword_init: true) do
      def queued? = status == "queued"
      def live? = status == "live"
    end

    attr_reader :slug

    # The session ids of every run of a `notify: quiet` local automation,
    # which attention and turn notifications leave out.
    def self.quiet_session_ids(dir = AUTOMATIONS_DIR)
      AutomationStore.new(dir).list
                     .select { |entry| entry.record["runner"] == "local" && entry.record["notify"] == "quiet" }
                     .flat_map { |entry| new(entry.slug, dir: dir).runs.filter_map(&:session_id) }.to_set
    rescue StandardError => e
      Quartermaster.log_error("quiet-runs", e)
      Set.new
    end

    def initialize(slug, dir: AUTOMATIONS_DIR)
      raise ArgumentError, "not an automation slug: #{slug.inspect}" unless slug.is_a?(String) && slug.match?(AutomationStore::SLUG)

      @slug = slug
      @dir = dir
    end

    def path = File.join(@dir, "#{slug}.runs.jsonl")

    # Queues a run with no dedupe; returns its id.
    def enqueue(key:, item:, flow:, trigger:, at: Time.now)
      id = new_run_id
      append("queued", at, "run_id" => id, "key" => key, "item" => item, "flow" => flow, "trigger" => trigger)
      id
    end

    # Queues a guard item unless its key was seen; returns the run id or nil.
    def enqueue_item(key:, item:, flow:, trigger: "guard", at: Time.now)
      exclusively do
        next nil if seen_keys.include?(key)

        enqueue(key: key, item: item, flow: flow, trigger: trigger, at: at)
      end
    end

    # Queues the run a due cron minute asks for, unless a cron run is
    # already queued; returns the run id or nil.
    def enqueue_cron(due:, flow:, at: Time.now)
      exclusively do
        next nil if cron_queued?

        enqueue(key: "cron:#{due.getutc.iso8601}", item: nil, flow: flow, trigger: "cron", at: at)
      end
    end

    # Queues a new run with an ended run's item, bypassing dedupe; returns its id.
    def retry(run_id, at: Time.now)
      exclusively do
        old = run(run_id)
        raise ArgumentError, "no run #{run_id} in #{slug}" unless old
        raise ArgumentError, "run #{run_id} is still #{old.status}" if old.queued? || old.live?

        id = new_run_id
        append("retried", at, "run_id" => run_id, "new_run_id" => id)
        append("queued", at, "run_id" => id, "key" => old.key, "item" => old.item, "flow" => old.flow, "trigger" => "retry")
        id
      end
    end

    def started(run_id, session_id:, tmux:, item_slug:, at: Time.now)
      append("started", at, "run_id" => run_id, "session_id" => session_id, "tmux" => tmux, "item_slug" => item_slug)
    end

    # Records why a queued run doesn't start, only when the reason changed.
    def waiting(run_id, reason:, at: Time.now)
      exclusively do
        next if run(run_id)&.waiting == reason

        append("waiting", at, "run_id" => run_id, "reason" => reason)
      end
    end

    def finished(run_id, at: Time.now) = append("finished", at, "run_id" => run_id)

    def timed_out(run_id, at: Time.now) = append("timed_out", at, "run_id" => run_id)

    def closed(run_id, at: Time.now) = append("closed", at, "run_id" => run_id)

    def failed(run_id, error:, at: Time.now) = append("failed", at, "run_id" => run_id, "error" => error)

    def guard_error(error:, item: nil, at: Time.now)
      append("guard_error", at, { "error" => error, "item" => item }.compact)
    end

    # A guard run that exited cleanly; clears the last guard error.
    def guard_ran(items:, at: Time.now) = append("guard_ran", at, "items" => items)

    # Keys recorded as seen without queuing a run.
    def mark_seen(keys, at: Time.now) = append("seen", at, "keys" => keys)

    # The tick handled a due cron minute up to `at`.
    def checked(at: Time.now) = append("checked", at, {})

    # Oldest first; runs queued at the same second keep their log order.
    def queue = runs.select(&:queued?).each_with_index.sort_by { |run, i| [run.queued_at, i] }.map(&:first)

    def live = runs.select(&:live?)

    # Runs that left the queue, newest first.
    def recent(limit: 20)
      runs.reject(&:queued?).sort_by { |r| r.started_at || r.ended_at || r.queued_at }.reverse.first(limit)
    end

    def run(run_id) = fold[:runs][run_id]

    def runs = fold[:runs].values

    def seen_keys = fold[:seen]

    def cron_queued? = queue.any? { |r| r.trigger == "cron" }

    # The latest `guard_error` event (its fields) since the last clean guard run.
    def last_guard_error = fold[:guard_error]

    def last_cron_check = fold[:checked]

    private

    def append(event, at, fields)
      line = { "v" => VERSION, "at" => at.getutc.iso8601, "event" => event }.merge(fields)
      exclusively { @locked.puts(JSON.generate(line)) }
      @fold = nil
      line
    end

    # Runs the block holding the log's flock, with the fold re-read, so a
    # check and the append it decides stay one step against other writers.
    def exclusively
      return yield if @locked

      FileUtils.mkdir_p(@dir)
      File.open(path, "a") do |f|
        f.flock(File::LOCK_EX)
        f.sync = true
        @locked = f
        @fold = nil
        yield
      ensure
        @locked = nil
      end
    end

    def new_run_id = SecureRandom.alphanumeric(8).downcase

    def fold
      @fold ||= events.each_with_object({ runs: {}, seen: Set.new, guard_error: nil, checked: nil }) { |e, state| apply(state, e) }
    end

    def events
      return [] unless File.exist?(path)

      File.foreach(path).filter_map { |line| Quartermaster.json_object(line) }
    end

    def apply(state, event)
      at = time(event["at"])
      case event["event"]
      when "queued"
        state[:seen] << event["key"]
        state[:runs][event["run_id"]] = Run.new(id: event["run_id"], key: event["key"], item: event["item"], flow: event["flow"],
                                                trigger: event["trigger"], queued_at: at, status: "queued")
      when "seen" then state[:seen].merge(Array(event["keys"]))
      when "guard_error" then state[:guard_error] = event
      when "guard_ran" then state[:guard_error] = nil
      when "checked" then state[:checked] = at
      else apply_to_run(state[:runs][event["run_id"]], event, at)
      end
    end

    def apply_to_run(run, event, at)
      return unless run

      case event["event"]
      when "started"
        run.status = "live"
        run.started_at = at
        run.session_id, run.tmux, run.item_slug = event.values_at("session_id", "tmux", "item_slug")
      when "waiting" then run.waiting = event["reason"]
      when "finished"
        run.status = "finished"
        run.finished_at = at
      when *ENDINGS
        run.status = event["event"]
        run.ended_at = at
        run.error = event["error"]
      when "retried" then run.retried_as = event["new_run_id"]
      end
    end

    def time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.at(0).utc
    end
  end
end
