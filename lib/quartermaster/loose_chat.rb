# frozen_string_literal: true

require "securerandom"

module Quartermaster
  # A chat that belongs to no work item, by intent: a question about a
  # project, started from the GUI or `qm loose`. It runs in its own tmux
  # session (`loose--<id>`; the double dash never comes out of a slug) under
  # QM_LOOSE=<id> with QM_ITEM blank, so the SessionStart hook never links it.
  # It is listed while that tmux session lives — no state file — and once it
  # dies its session is an ordinary inbox entry. Unlike an aside it asks for
  # attention. ✕ closes it; promote turns it into an item's chat.
  class LooseChat
    ENV_VAR = "QM_LOOSE"
    PREFIX = "loose--"
    # The title of a loose chat whose first prompt isn't in a transcript yet.
    UNTITLED = "New loose chat"
    # /exit lets claude end its session (SessionEnd fires); kill follows anyway.
    EXIT_TIMEOUT = 5
    POLL = 0.25
    def self.new_id = SecureRandom.hex(4)

    # Claude's first prompt: a starter's (config.yml `loose_starters:`) prompt,
    # which has the chat load something before the first question, ending in
    # the typed question (or asking for one); else the question alone. qm
    # calls nothing itself; the chat's own tools do the loading.
    def self.kickoff(starter, question, starters: ProjectConfig.current.loose_starters)
      question = question.to_s.strip
      question = nil if question.empty?
      return question unless starter

      known = starters[starter]
      unless known
        raise ArgumentError, "unknown starter #{starter.inspect} (configured: #{starters.keys.join(", ")}; add one with " \
                             "`qm config set loose_starters.#{starter}.prompt <prompt>`)"
      end

      "#{known.prompt} " + (question ? "answer my question about them:\n\n#{question}" : "ask me what I want to know about them.")
    end

    def self.session_name(id) = "#{PREFIX}#{id}"

    def self.id_of(name) = name.to_s.start_with?(PREFIX) ? name.delete_prefix(PREFIX) : nil

    def initialize(tmux: Tmux.new, launcher: nil, session_log: SessionLog.new,
                   sleeper: ->(seconds) { sleep(seconds) })
      @tmux = tmux
      @launcher = launcher
      @session_log = session_log
      @sleeper = sleeper
    end

    # Opens a new loose chat; returns its tmux session name.
    def start(project:, model: nil, prompt: nil, starter: nil)
      model = presence(model)
      raise ArgumentError, "unknown model #{model.inspect} (#{Aside::MODELS.join(", ")})" if model && !Aside::MODELS.include?(model)

      prompt = self.class.kickoff(presence(starter), prompt)
      id = self.class.new_id
      plan = (@launcher || Launcher.new(session_log: @session_log)).loose_plan(id, project: presence(project) || ProjectMap::NO_PROJECT, model: model, prompt: prompt)
      name = self.class.session_name(id)
      @tmux.open(name, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      name
    end

    # The live loose chats among the tmux session names, as the chats list
    # shows them: titled by the first prompt, with whose move it is.
    def chats(panes, attention: ChatAttention.new(session_log: @session_log))
      panes.filter_map do |name|
        id = self.class.id_of(name)
        next unless id

        session = session_of(id)
        turn = session ? attention.turn_for(session) : { state: "none" }
        { "name" => name, "id" => id, "session" => session&.id,
          "title" => TurnNotifier.unlinked_title(session, UNTITLED),
          "project" => session&.project, "cwd" => session&.cwd && Quartermaster.shorten_home(session.cwd),
          "state" => turn[:state], "since" => turn[:since]&.utc&.iso8601, "tool" => turn[:tool] }
      end
    end

    # ✕: ends the chat (/exit, then kill whatever is left) and dismisses its
    # sessions from the inbox — a closed loose chat is done with.
    def close(id)
      name = self.class.session_name(id)
      if @tmux.live?(name)
        @tmux.send_text(name, Rotation::EXIT_COMMAND)
        @sleeper.call(Rotation::TYPE_SETTLE)
        @tmux.send_enter(name)
        (EXIT_TIMEOUT / POLL).to_i.times do
          break if !@tmux.live?(name) || @tmux.pane_dead?(name)

          @sleeper.call(POLL)
        end
        @tmux.kill(name)
      end
      sessions_of(id).each { |session| @session_log.dismiss(session.id) }
      true
    end

    # → Work item: an item made from the chat's newest session (WorkItem.from_session),
    # and the tmux session renamed to its slug, so from now on it is that
    # item's chat. With tell (the user's checkbox), the renamed chat is typed one
    # line naming its item. Returns [item, renamed?, told?].
    def promote(id, title:, tell: false)
      title = title.to_s.strip
      raise ArgumentError, "title is required" if title.empty?

      session = session_of(id)
      raise ArgumentError, "the loose chat has no captured session yet — give it a moment" unless session

      item, = WorkItem.from_session(session.id, title: title, session_log: @session_log)
      renamed = @tmux.rename(self.class.session_name(id), item.slug)
      [item, renamed, (tell && renamed && tell_item(item.slug)) || false]
    end

    def self.told_line(slug) = "This chat is now work item #{slug}; run qm show #{slug} and follow its work item protocol from here."

    def sessions_of(id) = @session_log.sessions.select { |s| s.loose_id == id }

    # A /clear restarts the session under the same id: the live one, else the newest.
    def session_of(id)
      sessions = sessions_of(id)
      sessions.select(&:live?).max_by { |s| s.started_ts.to_s } || sessions.max_by { |s| s.started_ts.to_s }
    end

    private

    def tell_item(slug)
      return false if !@tmux.live?(slug) || @tmux.pane_dead?(slug)
      return false unless @tmux.send_text(slug, self.class.told_line(slug))

      @sleeper.call(Rotation::TYPE_SETTLE)
      @tmux.send_enter(slug) ? true : false
    end

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
