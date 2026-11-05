# frozen_string_literal: true

module Quartermaster
  # One earlier session as the chat view renders it read-only above the live
  # pane: what the user typed and what Claude answered, in full, and every tool
  # call as a single line. Thinking, tool results, sub-agent (sidechain)
  # traffic, hook output and compaction summaries are left out — the history
  # is for rereading the conversation, not for auditing the run.
  #
  # Entries are {"kind", "text", "ts"} with kind user | assistant | tool |
  # event (an interrupt). Claude Code writes one transcript line per content
  # block, so consecutive text blocks of one assistant message are joined.
  class TranscriptHistory
    TOOL_LINE_CHARS = 160
    # The input field that best says what a tool call did, in order of preference.
    TOOL_SUBJECT_KEYS = %w[command file_path notebook_path pattern path url query skill description prompt].freeze

    def self.entries(path)
      return nil unless path && File.exist?(path)

      new.tap { |history| File.foreach(path) { |line| history.add(line) } }.entries
    rescue SystemCallError
      nil
    end

    # "Bash  git status" — the tool's name and the one input that identifies
    # the call, folded onto one line and clipped.
    def self.tool_line(block)
      input = block["input"].is_a?(Hash) ? block["input"] : {}
      subject = TOOL_SUBJECT_KEYS.lazy.map { |key| input[key] }.find { |v| v.is_a?(String) && !v.strip.empty? }
      subject ||= input.values.find { |v| v.is_a?(String) && !v.strip.empty? }
      subject = subject && Quartermaster.shorten_home(subject.split.join(" "))
      Quartermaster.clip([block["name"] || "?", subject].compact.join("  "), TOOL_LINE_CHARS)
    end

    attr_reader :entries

    def initialize
      @entries = []
      @message_id = nil
    end

    def add(line)
      entry = JSON.parse(line)
      return unless entry.is_a?(Hash) && !entry["isSidechain"]

      case entry["type"]
      when "user" then add_user(entry)
      when "assistant" then add_assistant(entry)
      end
    rescue JSON::ParserError
      nil
    end

    private

    def add_user(entry)
      return if entry["isCompactSummary"]

      text = Quartermaster.prompt_text(entry)
      return unless text

      kind = text.start_with?(TranscriptVitals::INTERRUPT_MARK) ? "event" : "user"
      push(kind, text, entry["timestamp"])
    end

    def add_assistant(entry)
      id = entry.dig("message", "id")
      content = entry.dig("message", "content")
      content = [{ "type" => "text", "text" => content }] if content.is_a?(String)
      Array(content).each do |block|
        next unless block.is_a?(Hash)

        case block["type"]
        when "text"
          text = block["text"].to_s.strip
          next if text.empty?

          last = @entries.last
          if last && last["kind"] == "assistant" && id && id == @message_id
            last["text"] = "#{last["text"]}\n\n#{text}"
          else
            push("assistant", text, entry["timestamp"])
          end
        when "tool_use"
          push("tool", self.class.tool_line(block), entry["timestamp"])
        end
      end
      @message_id = id
    end

    def push(kind, text, ts)
      @message_id = nil unless kind == "assistant"
      @entries << { "kind" => kind, "text" => text, "ts" => ts }
    end
  end
end
