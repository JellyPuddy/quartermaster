# frozen_string_literal: true

module Quartermaster
  # Tells the user when a chat needs them: a permission prompt or question
  # (always, with sound), or a turn that ran long enough that he has likely
  # looked away (LONG_TURN). Every non-aside session counts, GUI chat or not,
  # except the runs of a `notify: quiet` local automation.
  # Never for an Esc interrupt (no hook fires), a turn that delegated to
  # background work (waiting) or a snoozed turn.
  #
  # The GUI's watcher thread calls #check when events.jsonl grows; it reacts
  # only to hook output, never to the page's absence. The channel depends on
  # the page: a pulse younger than PAGE_FRESH means a visible tab, which shows
  # a browser notification itself (#recent, flagged "page") — or nothing
  # when it is focused on that very chat. Otherwise macOS shows one via
  # terminal-notifier (a click opens the chat: `qm open-chat`), else
  # osascript, through the runner so tests never raise a real one.
  class TurnNotifier
    LONG_TURN = 30
    PAGE_FRESH = 3
    KEEP = 20
    SOUND = "Glass"
    # A GUI started from a launcher may not have Homebrew on PATH.
    NOTIFIER_DIRS = %w[/opt/homebrew/bin /usr/local/bin].freeze

    def self.find_terminal_notifier
      dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR) + NOTIFIER_DIRS
      dirs.map { |dir| File.join(dir, "terminal-notifier") }.find { |path| File.executable?(path) }
    end

    # terminal_notifier: its path, or nil for osascript.
    def initialize(runner:, event_log: EventLog.new, clock: -> { Time.now },
                   terminal_notifier: self.class.find_terminal_notifier)
      @runner = runner
      @terminal_notifier = terminal_notifier
      @event_log = event_log
      @clock = clock
      @lock = Mutex.new
      @seen = nil
      @page = nil
      @recent = []
      @seq = 0
    end

    # Bumped per notification raised, so the page's pulse moves with it.
    def seq = @lock.synchronize { @seq }

    # The newest notifications, oldest first, for the page to show the ones
    # it hasn't yet.
    def recent = @lock.synchronize { @recent.dup }

    # The page's pulse: it is visible, and whether it has focus on a chat.
    def page_seen(focused:, chat:)
      @lock.synchronize { @page = { at: @clock.call, focused: focused, chat: chat } }
    end

    # The page's tab was hidden: a notification it took now would wait for
    # its throttled pulse, so macOS shows them again.
    def page_hidden
      @lock.synchronize { @page = nil }
    end

    # The notifications raised by the turns that changed since the last
    # check. The first check only takes stock: what happened before the GUI
    # started is not news.
    def check
      turns = @event_log.turns
      previous = @seen
      @seen = turns.transform_values { |turn| [turn["state"], turn["since"]] }
      return [] unless previous

      changed = turns.select { |id, turn| previous[id] != @seen[id] && trigger(turn) }
      return [] if changed.empty?

      changed = changed.except(*RunLog.quiet_session_ids)
      log = SessionLog.new
      items = WorkItem.all
      runs = RunChats.by_session
      changed.filter_map { |id, turn| raise_for(id, turn, log, items, runs[id]) }
    end

    private

    def trigger(turn)
      case turn["state"]
      when "blocked" then :blocked
      when "your_turn" then :your_turn if long_turn?(turn)
      end
    end

    def long_turn?(turn)
      return false unless turn["prompt_ts"] && turn["stop_ts"]

      Time.parse(turn["stop_ts"]) - Time.parse(turn["prompt_ts"]) >= LONG_TURN
    rescue ArgumentError
      false
    end

    def raise_for(session_id, turn, log, items, run)
      session = log.session_for(session_id)
      return if session&.aside_for

      item = items.find { |candidate| candidate.sessions.any? { |s| s["id"] == session_id } }
      kind = trigger(turn)
      return if kind == :your_turn && quiet_turn?(session, item, turn, log)

      notification = run ? build_for_run(session_id, run, turn, kind) : build(session_id, session, item, turn, kind)
      deliver(notification)
      notification
    rescue StandardError => e
      Quartermaster.log_error("turn-notify", e)
      nil
    end

    # A snoozed turn, or one that only handed off to background work.
    def quiet_turn?(session, item, turn, log)
      since = Time.parse(turn["since"].to_s)
      return true if item&.turn_snoozed?(since)
      return false unless session

      ChatAttention.new(session_log: log, event_log: @event_log).turn_for(session)[:state] != "your_turn"
    rescue ArgumentError
      false
    end

    def build(session_id, session, item, turn, kind)
      title = item ? item.title : self.class.unlinked_title(session)
      loose = !item && session&.loose_id ? LooseChat.session_name(session.loose_id) : nil
      { "slug" => item&.slug, "loose" => loose, "session" => session_id, "kind" => kind.to_s,
        "title" => title, "body" => body(turn, kind) }
    end

    # A local automation's chat-flow run: its own tmux, not the automation's slug.
    def build_for_run(session_id, run, turn, kind)
      { "slug" => nil, "run" => run.tmux, "session" => session_id, "kind" => kind.to_s,
        "title" => run.title, "body" => body(turn, kind) }
    end

    def body(turn, kind)
      return "Your turn — after #{duration(turn)}" unless kind == :blocked

      turn["tool"] ? "Needs you: #{turn['tool']}" : "Needs your answer"
    end

    # The tmux name a click opens: the item's slug, else the run's or the loose chat's.
    def self.chat_of(notification) = notification["slug"] || notification["run"] || notification["loose"]

    def self.unlinked_title(session, fallback = "Unlinked session")
      prompt = session&.first_prompt.to_s.strip
      return fallback if prompt.empty?

      prompt.length > 60 ? "#{prompt[0, 59]}…" : prompt
    end

    def duration(turn)
      seconds = (Time.parse(turn["stop_ts"]) - Time.parse(turn["prompt_ts"])).to_i
      seconds < 3600 ? "#{seconds / 60}m #{seconds % 60}s" : "#{seconds / 3600}h #{seconds % 3600 / 60}m"
    end

    def deliver(notification)
      page = @lock.synchronize { @page }
      visible = page && @clock.call - page[:at] < PAGE_FRESH
      chat = self.class.chat_of(notification)
      watching = visible && page[:focused] && chat && page[:chat] == chat
      notification["page"] = visible && !watching ? true : false
      @lock.synchronize do
        @seq += 1
        notification["id"] = @seq
        @recent = (@recent + [notification]).last(KEEP)
      end
      macos(notification) unless visible
    end

    def macos(notification)
      chat = self.class.chat_of(notification)
      announce(title: notification["title"], body: notification["body"],
               group: "qm-#{notification["slug"] || notification["run"] || notification["session"]}",
               click: chat && ["open-chat", chat], sound: notification["kind"] == "blocked")
    end

    public

    # A macOS notification straight away, for news raised outside the GUI (a
    # finished benchmark run). click: the qm command words a click runs, or
    # nil. A newer notification of the same group replaces the older one.
    # The click runs in a bare environment (PATH without asdf's shims), so it
    # names this very ruby rather than trusting the launcher's `env ruby`.
    def announce(title:, body:, group:, click: nil, sound: false)
      return osascript(title, body, sound) unless @terminal_notifier

      argv = [@terminal_notifier, "-title", title, "-message", body, "-group", group]
      argv += ["-sound", SOUND] if sound
      argv += ["-execute", Shellwords.join([RbConfig.ruby, EXECUTABLE, *click])] if click
      @runner.call(argv)
    end

    private

    # Text goes in as argv, never spliced into the script.
    def osascript(title, body, sound)
      sound = sound ? " sound name \"#{SOUND}\"" : ""
      @runner.call(["osascript", "-e", "on run argv",
                    "-e", "display notification (item 2 of argv) with title (item 1 of argv)#{sound}",
                    "-e", "end run", title, body])
    end
  end
end
