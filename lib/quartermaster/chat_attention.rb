# frozen_string_literal: true

module Quartermaster
  # Whose move it is in each item's chat — the chat view's left list. Derived
  # from the hook events (EventLog) plus SessionLog liveness, with the
  # transcript filling in what no hook reports (Esc interrupts, context size).
  #
  # blocked: a permission prompt or question is pending. your_turn: the turn
  # ended (Stop or Esc) and stays loud until the user types or snoozes it — no
  # auto-dimming. working: Claude is mid-turn. waiting: the turn ended with
  # background work still out (BackgroundJobs; watchers don't count) — the
  # chat takes it up again when that reports. none: no live chat (or a live
  # one that has had no prompt yet).
  class ChatAttention
    STATES = %w[blocked your_turn working waiting none].freeze

    Entry = Struct.new(:slug, :session_id, :state, :since, :tool, :snoozed, :waiting_on, :context_tokens,
                       :cache_warm_until, :last_assistant_at, :activity, :run, keyword_init: true) do
      # A snoozed your-turn sinks below working, above chats with no turn at all.
      def rank
        return 2.5 if snoozed

        STATES.index(state)
      end

      # Longest-waiting first within a state; no-turn rows by recent activity.
      def sort_key = [rank, since ? since.to_f : -activity.to_f]
    end

    def initialize(session_log: SessionLog.new, event_log: EventLog.new)
      @session_log = session_log
      @event_log = event_log
      @vitals = {}
    end

    # In-progress items plus anything with a live chat, by attention. Automations
    # never: their chat opens from the Automations tab, and rotate offers hang off these rows.
    def entries
      WorkItem.all.filter_map do |item|
        next if item.automation?

        live = live_sessions(item)
        next unless item.state == "in_progress" || live.any?

        entry_for(item, live)
      end.sort_by(&:sort_key)
    end

    # The Runs group: one entry per live chat-flow run of a local automation
    # that isn't `notify: quiet`, named by its own tmux (slug) and carrying the
    # run (RunChats::Chat). A pr-review run speaks through its Review item's row.
    def runs(chats = RunChats.by_session)
      chats.each_value.filter_map do |chat|
        next if chat.quiet

        session = @session_log.session_for(chat.session_id)
        next unless session&.live?

        turn = turn_for(session)
        Entry.new(slug: chat.tmux, session_id: session.id, state: turn[:state], since: turn[:since], tool: turn[:tool],
                  waiting_on: turn[:waiting_on], activity: session.last_ts ? Time.parse(session.last_ts) : nil, run: chat)
      end.sort_by(&:sort_key)
    end

    def entry_for(item, live = live_sessions(item))
      turns = live.map { |session| [session, turn_for(session)] }
      session, turn = turns.min_by { |_, t| [STATES.index(t[:state]), t[:since].to_f] }
      session ||= Quartermaster.item_sessions(item, session_log: @session_log).first
      turn ||= { state: "none" }
      # A chat handed over without a fresh start (wrap up & close) leaves no
      # context to show or rotate — the next Start begins from the notes.
      vitals = session && !item.rotated_from?(session.id) ? vitals_for(session) : nil
      snoozed = turn[:state] == "your_turn" && item.turn_snoozed?(turn[:since])
      Entry.new(slug: item.slug, session_id: session&.id, state: turn[:state], since: turn[:since],
                tool: turn[:tool], snoozed: snoozed, waiting_on: turn[:waiting_on], context_tokens: vitals&.context_tokens,
                cache_warm_until: vitals&.cache_warm_until, last_assistant_at: vitals&.last_assistant_at,
                activity: session&.last_ts ? Time.parse(session.last_ts) : nil)
    end

    # One live session's state. A turn still working or blocked after a
    # transcript interrupt newer than its last Stop and prompt was ended by
    # Esc, which no hook reports.
    def turn_for(session)
      raw = @event_log.turn_for(session.id)
      return { state: "none" } unless raw && raw["state"]

      turn = { state: raw["state"], since: time(raw["since"]), tool: raw["tool"] }
      return delegated(session, turn) if turn[:state] == "your_turn"

      vitals = vitals_for(session)
      interrupted = vitals&.interrupted_at
      settled = [time(raw["stop_ts"]), time(raw["prompt_ts"])].compact.max
      return turn unless interrupted && (settled.nil? || interrupted > settled)

      { state: "your_turn", since: interrupted, tool: nil }
    end

    # A Stop with an agent, workflow or shell still running in the background: the
    # chat isn't done, only answerable. Not after Esc — that was the user's call.
    def delegated(session, turn)
      jobs = BackgroundJobs.pending(session.transcript).reject(&:watcher?)
      return turn if jobs.empty?

      turn.merge(state: "waiting", waiting_on: jobs.map(&:description))
    end

    private

    def vitals_for(session)
      return @vitals[session.id] if @vitals.key?(session.id)

      @vitals[session.id] = TranscriptVitals.read(session.transcript)
    end

    # A quiet automation's runs (a pr-review run lives in its Review item's chat) count for nothing.
    def live_sessions(item)
      @quiet ||= RunLog.quiet_session_ids
      item.sessions.filter_map { |s| @session_log.session_for(s["id"]) unless @quiet.include?(s["id"]) }.select(&:live?)
    end

    def time(ts)
      ts && Time.parse(ts)
    rescue ArgumentError
      nil
    end
  end
end
