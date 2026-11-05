# frozen_string_literal: true

module Quartermaster
  # A one-off question about an item, asked beside its chat rather than in it.
  # The aside runs in a tmux session of its own (`<slug>--aside`) under
  # QM_ASIDE=<slug>: the SessionStart hook then injects the item's digest but
  # never links the session to the item, record-event.sh logs nothing for it,
  # and the inbox skips it — so it gets no attention, is never distilled and
  # never shows in the item's sessions. Closing it kills the tmux session;
  # "promote" is the one way an answer reaches the item, as a note.
  class Aside
    ENV_VAR = "QM_ASIDE"
    SUFFIX = "--aside"
    MODELS = %w[sonnet opus haiku].freeze
    DEFAULT_MODEL = "sonnet"

    def self.session_name(slug) = "#{slug}#{SUFFIX}"

    def initialize(tmux: Tmux.new, launcher: Launcher.new, session_log: SessionLog.new)
      @tmux = tmux
      @launcher = launcher
      @session_log = session_log
    end

    # Opens the aside unless one already runs; true when it started one.
    def open(item, model: DEFAULT_MODEL)
      model = DEFAULT_MODEL if model.to_s.empty?
      raise ArgumentError, "unknown model #{model.inspect} (#{MODELS.join(", ")})" unless MODELS.include?(model)

      plan = @launcher.aside_plan(item, model: model)
      @tmux.open(self.class.session_name(item.slug), cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
    end

    def live?(item) = @tmux.live?(self.class.session_name(item.slug))

    def close(item) = @tmux.kill(self.class.session_name(item.slug))

    # Reopens an earlier aside in the drawer: `claude --resume` under the same
    # marker, so it stays out of the item's sessions. One aside at a time.
    def reopen(item, session_id)
      raise ArgumentError, "an aside for #{item.slug} is already open — close it first" if live?(item)

      session = asides_of(item).find { |s| s.id == session_id }
      raise ArgumentError, "#{session_id.to_s[0, 8]} is not an aside about #{item.slug}" unless session

      plan = @launcher.aside_resume_plan(item, session, model: self.class.model_in(session.transcript))
      raise ArgumentError, "#{session_id[0, 8]} has no surviving transcript to resume" unless plan

      @tmux.open(self.class.session_name(item.slug), cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
    end

    # The item's asides, newest first, for the drawer's list of earlier ones.
    # Reads every transcript, so it is served on demand, never in the state.
    def history(item)
      promoted = item.notes.map(&:text)
      asides_of(item).sort_by { |s| s.started_ts.to_s }.reverse.map do |s|
        answer = self.class.last_answer_in(s.transcript)
        { "id" => s.id, "tier" => s.tier, "at" => s.started_ts, "prompt" => s.first_prompt, "model" => self.class.model_in(s.transcript),
          "answer" => answer, "promoted" => !answer.nil? && promoted.include?(self.class.note_text(answer)) }
      end
    end

    # An aside's last assistant answer becomes a note on the item, folded onto
    # one line — a stored note is a single line. Without a session id that is
    # the running aside. Raises when there is nothing to promote. Returns the
    # note text.
    def promote(item, session_id: nil, kind: DEFAULT_NOTE_KIND)
      answer = session_id ? answer_of(item, session_id) : last_answer(item)
      raise ArgumentError, "the aside for #{item.slug} has no answer to promote yet" unless answer

      text = self.class.note_text(answer)
      item.add_note(text, kind: kind)
      text
    end

    def self.note_text(answer) = "aside: #{answer.split.join(" ")}"

    # Only the aside running now counts: a closed one's claude is gone, so a
    # Promote clicked before a fresh aside's start is logged finds nothing
    # rather than an earlier aside's answer.
    def last_answer(item)
      session = asides_of(item).select(&:live?).max_by(&:started_ts)
      session && self.class.last_answer_in(session.transcript)
    end

    def answer_of(item, session_id)
      session = asides_of(item).find { |s| s.id == session_id }
      session && self.class.last_answer_in(session.transcript)
    end

    def asides_of(item) = @session_log.sessions.select { |s| s.aside_for == item.slug }

    # The text of the transcript's last assistant message that has any.
    # Claude Code writes one entry per content block, all sharing the
    # message id, so the blocks of that message are joined back together.
    def self.last_answer_in(transcript)
      return nil unless transcript && File.exist?(transcript)

      message_id = nil
      parts = []
      File.foreach(transcript) do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless entry.is_a?(Hash) && entry["type"] == "assistant"

        texts = assistant_texts(entry)
        next if texts.empty?

        id = entry.dig("message", "id")
        parts = [] unless id && id == message_id
        message_id = id
        parts.concat(texts)
      end
      answer = parts.join("\n\n").strip
      answer.empty? ? nil : answer
    end

    # The model the transcript's last assistant message ran on, so a reopened
    # aside keeps the one the user picked (or switched to) rather than the default.
    def self.model_in(transcript)
      return nil unless transcript && File.exist?(transcript)

      model = nil
      File.foreach(transcript) do |line|
        next unless line.include?('"model"')

        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        found = entry.dig("message", "model") if entry.is_a?(Hash) && entry["type"] == "assistant"
        model = found if found.is_a?(String) && !found.empty? && found != "<synthetic>"
      end
      model
    end

    def self.assistant_texts(entry)
      content = entry.dig("message", "content")
      return [content] if content.is_a?(String) && !content.strip.empty?
      return [] unless content.is_a?(Array)

      content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" && !block["text"].to_s.strip.empty? }
    end
  end
end
