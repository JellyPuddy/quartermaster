# frozen_string_literal: true

module Quartermaster
  # What a session's transcript says about its chat right now, read from the
  # tail only (transcripts reach many megabytes):
  # - context_tokens: the last assistant message's input + cache_read +
  #   cache_creation tokens — what the next turn sends;
  # - cache_warm_until: that message's timestamp plus the prompt-cache TTL,
  #   1 h when usage.cache_creation shows the 1 h tier, else 5 min;
  # - interrupted_at: the last "[Request interrupted by user…]" entry. Esc
  #   fires no hook, so this is the only trace an interrupt leaves.
  class TranscriptVitals
    TAIL_BYTES = 256 * 1024
    CACHE_TTL_1H = 3600
    CACHE_TTL_5M = 300
    INTERRUPT_MARK = "[Request interrupted by user"

    attr_reader :context_tokens, :last_assistant_at, :cache_warm_until, :interrupted_at

    def self.read(path)
      return nil unless path && File.exist?(path)

      new(path).tap(&:scan)
    rescue StandardError
      nil
    end

    def initialize(path)
      @path = path
    end

    def cache_warm?(now = Time.now) = !cache_warm_until.nil? && cache_warm_until > now

    # Grows the tail until it holds an assistant message with usage. An
    # interrupt older than the tail needs no search: a full tail written after
    # it means the user prompted again since.
    def scan
      size = File.size(@path)
      tail = TAIL_BYTES
      loop do
        scan_lines(read_tail([tail, size].min))
        break if @context_tokens || tail >= size

        tail *= 4
      end
    end

    private

    def read_tail(bytes)
      data = File.open(@path, "rb") do |f|
        f.seek(-bytes, IO::SEEK_END)
        f.read
      end
      lines = data.force_encoding(Encoding::UTF_8).lines
      lines.shift if bytes < File.size(@path) # a partial first line
      lines
    end

    def scan_lines(lines)
      usage_seen = tier = nil
      lines.reverse_each do |line|
        entry = Quartermaster.json_object(line) or next
        next if entry["isSidechain"]

        case entry["type"]
        when "assistant"
          usage = entry.dig("message", "usage")
          next unless usage.is_a?(Hash) && entry.dig("message", "model") != "<synthetic>"

          unless usage_seen
            total = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].sum { |k| usage[k].to_i }
            next if total.zero?

            usage_seen = entry
            @context_tokens = total
            @last_assistant_at = time(entry["timestamp"])
          end
          tier ||= cache_tier(usage["cache_creation"])
        when "user"
          @interrupted_at ||= time(entry["timestamp"]) if interrupt?(entry)
        end
        break if usage_seen && tier && @interrupted_at
      end
      return unless @last_assistant_at

      @cache_warm_until = @last_assistant_at + (tier == "1h" ? CACHE_TTL_1H : CACHE_TTL_5M)
    end

    # nil when this message created no cache entries — the tier then comes
    # from the newest message that did.
    def cache_tier(creation)
      return nil unless creation.is_a?(Hash)
      return "1h" if creation["ephemeral_1h_input_tokens"].to_i.positive?

      "5m" if creation["ephemeral_5m_input_tokens"].to_i.positive?
    end

    def interrupt?(entry)
      content = entry.dig("message", "content")
      texts = content.is_a?(String) ? [content] : Array(content).filter_map { |c| c["text"] if c.is_a?(Hash) }
      texts.any? { |t| t.is_a?(String) && t.start_with?(INTERRUPT_MARK) }
    end

    def time(ts)
      ts && Time.parse(ts)
    rescue ArgumentError
      nil
    end
  end
end
