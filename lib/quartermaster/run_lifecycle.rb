# frozen_string_literal: true

module Quartermaster
  # What each tick does with a local automation's started runs, paused or
  # not: a run whose session's turn ended (your_turn) is `finished`; a
  # finished `--run-` chat left idle for CLOSE_AFTER is killed (`closed`);
  # an untouched run still busy past its `timeout_minutes` is `timed_out` —
  # its `--run-` chat killed (a pr-review run's Review chat is left open),
  # a history note on the automation's item and a macOS notification. A run
  # the user typed into (a second prompt) is theirs: never closed or stopped.
  class RunLifecycle
    CLOSE_AFTER = 3600
    # A live run's session in these states holds a slot; "none" is a run
    # whose first prompt the hooks haven't reported yet.
    BUSY = %w[working waiting none].freeze

    def initialize(tmux:, notifier:, dir: AUTOMATIONS_DIR, sessions: SessionLog.new, event_log: EventLog.new)
      @tmux = tmux
      @notifier = notifier
      @dir = dir
      @sessions = sessions
      @event_log = event_log
      @attention = ChatAttention.new(session_log: sessions, event_log: event_log)
    end

    # Checks every started run of one automation; answers {"finished",
    # "closed", "timed_out"} => run ids.
    def call(entry, now)
      done = { "finished" => [], "closed" => [], "timed_out" => [] }
      log = RunLog.new(entry.slug, dir: @dir)
      log.runs.each do |run|
        outcome = case run.status
                  when "live" then live(entry, log, run, now)
                  when "finished" then idle(log, run, now)
                  end
        done[outcome] << run.id if outcome
      end
      done
    end

    # A live run holds a slot while its session works, waits on background
    # work or hasn't reported its first prompt; before the session's
    # SessionStart hook ran, while its tmux session lives.
    def busy?(run)
      session = session(run)
      return @tmux.live?(run.tmux.to_s) unless session

      session.live? && BUSY.include?(@attention.turn_for(session)[:state])
    end

    private

    def live(entry, log, run, now)
      session = session(run)
      if session && @attention.turn_for(session)[:state] == "your_turn"
        log.finished(run.id, at: now)
        return "finished"
      end
      return if typed_into?(run) || !busy?(run)

      minutes = AutomationStore.local_settings(entry.record)["timeout_minutes"].to_i
      return if run.started_at.nil? || now - run.started_at < minutes * 60

      stop(entry, log, run, minutes, now)
      "timed_out"
    end

    def idle(log, run, now)
      return unless own_chat?(run) && !typed_into?(run) && @tmux.live?(run.tmux)

      session = session(run)
      turn = session && @attention.turn_for(session)
      return unless turn && turn[:state] == "your_turn" && turn[:since] && now - turn[:since] >= CLOSE_AFTER

      @tmux.kill(run.tmux)
      log.closed(run.id, at: now)
      "closed"
    end

    def stop(entry, log, run, minutes, now)
      @tmux.kill(run.tmux) if own_chat?(run)
      log.timed_out(run.id, at: now)
      what = "#{run.id} timed out after #{minutes} min"
      note(entry.slug, own_chat?(run) ? "run #{what}" : "run #{what} (its Review chat stays open)")
      announce(entry, run, "Run #{what}")
    end

    # Only the `--run-` chat a chat flow opened is ever killed by qm.
    def own_chat?(run) = run.tmux.to_s.include?(ChatFlow::SEPARATOR)

    # Any prompt after the first (the run's own) means the user took it over.
    def typed_into?(run) = run.session_id && @event_log.turn_for(run.session_id)&.dig("prompts").to_i > 1

    def session(run) = run.session_id && @sessions.session_for(run.session_id)

    def note(slug, text)
      WorkItem.find(slug).add_note(text, kind: "history")
    rescue ArgumentError => e
      Quartermaster.log_error("automation-timeout #{slug}", e)
    end

    def announce(entry, run, body)
      click = own_chat?(run) ? nil : ["open-chat", run.tmux]
      @notifier.announce(title: entry.record["name"] || entry.slug, body: body, group: "qm-automation-#{entry.slug}",
                         click: click)
    rescue StandardError => e
      Quartermaster.log_error("automation-timeout #{entry.slug}", e)
    end
  end
end
