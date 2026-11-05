# frozen_string_literal: true

module Quartermaster
  # A context rotation: hand an item's chat over to a
  # fresh session that starts from the work item instead of a bloated or
  # cold context. Never automatic — only the user's click starts one.
  #
  # A live chat in its pane hands over itself: qm types WRAP_UP_PROMPT into
  # it, waits for the turn's Stop, ends it with /exit, records the rotation
  # (which notes the fresh session is told about) and starts a fresh QM_ITEM
  # session in the same tmux window, so the attached pane never closes.
  #
  # A dead chat (crashed, ended, or its transcript expired) can't wrap up, so
  # its latest transcript gets the existing Haiku distill instead, when it
  # survives and has no snapshot yet; then the same record and fresh start.
  #
  # "Wrap up & close" (close: true) is the live hand-off without the fresh
  # start: the wrap-up runs while the cache is hot, the window closes and the
  # rotation is recorded; a later Start picks the item up from its notes.
  # "Finish" (finish: true) is that close with FINISH_PROMPT instead, and the
  # item resolved once the hand-off succeeded; a failed one resolves nothing.
  #
  # A self-rotation (qm rotate --self, the /rotate skill) is the chat asking
  # for its own hand-off after writing its notes: no prompt is typed, qm waits
  # for that chat's first Stop after the request, then the same /exit, record
  # and fresh start (or close).
  #
  # Background work still out (ChatAttention's `waiting`) blocks the /exit:
  # claude answers /exit with a confirmation about running background tasks,
  # which swallows it. A click refuses up front; once a turn has ended, both
  # modes wait for the work to report back and the turn that took it up to
  # end before typing /exit.
  class Rotation
    WRAP_UP_PROMPT = "Wrap up for a context rotation: record any decisions and open items not yet in the " \
                     "work item with qm note / qm retag, then reply DONE."
    FINISH_PROMPT = "This work item is done: record any remaining decisions with qm note, retag open notes " \
                    "that are handled with qm retag, then reply DONE."
    EXIT_COMMAND = "/exit"
    # The wrap-up may wait on a permission prompt for `qm note`; the user answers
    # it in the pane, so the wait is generous.
    STOP_TIMEOUT = 20 * 60
    EXIT_TIMEOUT = 60
    # Sub-agents and workflows routinely run longer than a turn: its own
    # bound, counted from the Stop the wait starts after.
    BACKGROUND_TIMEOUT = 60 * 60
    WAITING_LABEL = "rotating: waiting for background work…"
    # claude reads a burst of typed text as a paste: let it settle before Enter.
    TYPE_SETTLE = 0.5

    Plan = Struct.new(:mode, :session, :close, :finish, :requested_at, keyword_init: true)

    def initialize(tmux: Tmux.new, session_log: -> { SessionLog.new }, event_log: EventLog.new,
                   launcher: -> { Launcher.new }, distiller: ->(item, session) { Quartermaster.distill_session(item, session) },
                   sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now }, poll: 1,
                   lineage: ->(pid) { Quartermaster.process_lineage(pid) })
      @tmux = tmux
      @session_log = session_log
      @event_log = event_log
      @launcher = launcher
      @distiller = distiller
      @sleeper = sleeper
      @clock = clock
      @poll = poll
      @lineage = lineage
    end

    # The cheap, synchronous half: which kind of rotation this item gets, or
    # an ArgumentError saying why it can't rotate now — the GUI answers that
    # at once and runs #run on a thread.
    #
    # by_chat: the chat itself asked (qm rotate --self), as session_id when
    # the caller knows it. It is mid-turn by design, so no turn-state check.
    # finish: a close that resolves the item, so it implies close.
    def plan(item, close: false, finish: false, by_chat: false, session_id: nil)
      close ||= finish
      return self_plan(item, close: close, session_id: session_id).tap { |p| p.finish = finish } if by_chat

      log = @session_log.call
      live = Quartermaster.item_sessions(item, session_log: log).select(&:live?)
      if @tmux.live?(item.slug)
        session = live.first
        raise ArgumentError, "#{item.slug}'s chat has no captured session yet — rotate once it has answered" unless session

        turn = ChatAttention.new(session_log: log, event_log: @event_log).turn_for(session)
        state = turn[:state]
        raise ArgumentError, "#{item.slug}'s chat is mid-turn (#{state}) — rotate once it is your turn" if %w[working blocked].include?(state)
        if state == "waiting"
          raise ArgumentError, "#{item.slug}'s chat is waiting on background work (#{turn[:waiting_on].join(", ")}) — " \
                               "rotate once it has reported back"
        end

        Plan.new(mode: :wrap_up, session: session, close: close, finish: finish)
      else
        raise ArgumentError, "#{item.slug}'s chat runs outside the GUI — end it there first" if live.any?
        raise ArgumentError, "#{item.slug} has no chat open to wrap up" if close

        latest = Quartermaster.item_sessions(item, session_log: log).find(&:captured?)
        raise ArgumentError, "#{item.slug} has no session to rotate from — just Start one" unless latest

        Plan.new(mode: :distill, session: latest)
      end
    end

    # Runs the plan; returns a GUI job result. Raises ArgumentError when a
    # step gives up, leaving the chat as it stands. relabel: called with a
    # new job label while the hand-off waits on background work.
    def run(item, plan, relabel: ->(_label) {})
      @relabel = relabel
      case plan.mode
      when :wrap_up then wrap_up(item, plan.session, close: plan.close, prompt: plan.finish ? FINISH_PROMPT : WRAP_UP_PROMPT)
      when :self then after_own_turn(item, plan.session, since: plan.requested_at, close: plan.close)
      else distill(item, plan.session)
      end
      return resolve(item) if plan.finish

      rotation = item.rotations.last
      done = plan.close ? "wrapped up and closed" : "rotated"
      { "ok" => true, "message" => "#{item.slug}: #{done} — carried #{rotation["decisions"]} decisions, #{rotation["open"]} open" }
    end

    private

    # Re-read: the wrap-up wrote notes after the item was loaded.
    def resolve(item)
      item = WorkItem.find(item.slug)
      item.update_state("resolved")
      open = item.notes.count(&:open?)
      tail = case open
             when 0 then ""
             when 1 then " — 1 open note remains"
             else " — #{open} open notes remain"
             end
      { "ok" => true, "message" => "#{item.slug}: resolved#{tail}" }
    end

    def self_plan(item, close:, session_id:)
      slug = item.slug
      raise ArgumentError, "#{slug}'s chat isn't open in the qm gui — qm rotate --self only works from a GUI chat" unless @tmux.live?(slug)

      live = Quartermaster.item_sessions(item, session_log: @session_log.call).select(&:live?)
      pane = @tmux.pane_pid(slug)
      session = if session_id then live.find { |s| s.id == session_id }
                else live.find { |s| pane && s.pid && in_pane?(s, pane) } || live.first
                end
      raise ArgumentError, "session #{session_id} is not #{slug}'s live chat — nothing to rotate" if session_id && !session
      raise ArgumentError, "#{slug}'s chat has no captured session yet — nothing to rotate" unless session
      unless in_pane?(session, pane)
        raise ArgumentError, "#{session.id} runs outside #{slug}'s qm gui pane — qm rotate --self only rotates the pane's own chat"
      end

      Plan.new(mode: :self, session: session, close: close, requested_at: @clock.call)
    end

    # The pane runs this session: its claude is the pane's process or a
    # descendant of it (a QM_CHAT_COMMAND wrapper). Either pid unknown: assume so.
    def in_pane?(session, pane)
      return true unless pane && session.pid

      @lineage.call(session.pid).include?(pane)
    end

    def wrap_up(item, session, close:, prompt:)
      slug = item.slug
      sent_at = @clock.call
      type(slug, prompt)
      wait_for(STOP_TIMEOUT, "no Stop from #{slug}'s wrap-up within #{STOP_TIMEOUT / 60} min — the chat is left as is") do
        stopped_since?(session.id, sent_at)
      end
      await_background(item.slug, session)
      hand_over(item, session, via: "wrap-up", close: close)
    end

    # The chat wrote its notes before asking; its turn ends on its own.
    def after_own_turn(item, session, since:, close:)
      slug = item.slug
      wait_for(STOP_TIMEOUT, "no Stop from #{slug}'s chat within #{STOP_TIMEOUT / 60} min of its rotate request — the chat is left as is") do
        stopped_after?(session.id, since)
      end
      await_background(item.slug, session)
      hand_over(item, session, via: "self", close: close)
    end

    # After a Stop: while the chat waits on background work, the work's
    # notification wakes it for one more turn. Settled once nothing is out
    # and a turn ended after the last one seen waiting (a Stop, or an Esc).
    def await_background(slug, session)
      waited = nil
      failure = "#{slug}'s background work did not finish within #{BACKGROUND_TIMEOUT / 60} min — the chat is left as is"
      wait_for(BACKGROUND_TIMEOUT, failure) do
        raise ArgumentError, "#{slug}'s chat ended while its rotation waited on background work" unless @tmux.live?(slug)

        turn = ChatAttention.new(session_log: nil, event_log: @event_log).turn_for(session)
        if turn[:state] == "waiting"
          @relabel&.call(WAITING_LABEL) unless waited
          waited = @event_log.turn_for(session.id)["stop_ts"].to_s
          false
        else
          %w[your_turn none].include?(turn[:state]) && (waited.nil? || ended_after?(session.id, turn, waited))
        end
      end
    end

    def ended_after?(session_id, turn, stop_ts)
      @event_log.turn_for(session_id)&.dig("stop_ts").to_s > stop_ts ||
        (turn[:since] && turn[:since].utc.iso8601 > stop_ts)
    end

    def hand_over(item, session, via:, close:)
      slug = item.slug
      @tmux.keep_on_exit(slug, true)
      type(slug, EXIT_COMMAND)
      begin
        wait_for(EXIT_TIMEOUT, "#{slug}'s chat did not exit after the wrap-up") { @tmux.pane_dead?(slug) || !@tmux.live?(slug) }
      rescue ArgumentError
        @tmux.keep_on_exit(slug, false)
        raise
      end

      item.record_rotation(from_session: session.id, via: via, at: @clock.call)
      close ? @tmux.kill(slug) : start_fresh(item)
    end

    def distill(item, session)
      @distiller.call(item, session) if session.transcript && !item.snapshot_for?(session.id)
      item.record_rotation(from_session: session.id, via: "distill", at: @clock.call)
      start_fresh(item)
    end

    # In the window the old chat left behind when there is one (the pane
    # stays attached), else a new tmux session.
    def start_fresh(item)
      plan = @launcher.call.fresh_chat_plan(item)
      if @tmux.live?(item.slug)
        begin
          @tmux.respawn(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
        rescue ArgumentError
          # A kept window with a dead pane would block Start ("already live"):
          # close it so the item can be started by hand.
          @tmux.kill(item.slug)
          raise
        end
        @tmux.keep_on_exit(item.slug, false)
      else
        @tmux.open(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      end
    end

    def type(slug, text)
      @tmux.send_text(slug, text) or raise ArgumentError, "could not type into #{slug}'s chat"
      @sleeper.call(TYPE_SETTLE)
      @tmux.send_enter(slug) or raise ArgumentError, "could not type into #{slug}'s chat"
    end

    # The wrap-up's own turn ended: a prompt submitted since we typed it
    # (hook stamps have whole seconds), then a Stop after that prompt.
    def stopped_since?(session_id, sent_at)
      turn = @event_log.turn_for(session_id)
      return false unless turn && turn["state"] == "your_turn"

      floor = sent_at.utc.iso8601
      prompt = turn["prompt_ts"].to_s
      prompt >= floor && turn["stop_ts"].to_s >= prompt
    end

    # The requesting turn's Stop: the chat's turn ended at or after the
    # request (whole-second stamps), and after its latest prompt.
    def stopped_after?(session_id, requested_at)
      turn = @event_log.turn_for(session_id)
      return false unless turn && turn["state"] == "your_turn"

      stop = turn["stop_ts"].to_s
      stop >= requested_at.utc.iso8601 && stop >= turn["prompt_ts"].to_s
    end

    def wait_for(timeout, failure)
      deadline = @clock.call + timeout
      until yield
        raise ArgumentError, failure if @clock.call >= deadline

        @sleeper.call(@poll)
      end
    end
  end
end
