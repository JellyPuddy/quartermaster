# frozen_string_literal: true

module Quartermaster
  # The tokens one transcript file spent, summed from its assistant entries'
  # `usage`, per bucket. Read incrementally: the state remembers the byte
  # offset of the last complete line, so a growing transcript is only read
  # from there on. The state is plain JSON — UsageLedger persists it.
  #
  # Claude Code writes one entry per content block of a message, each
  # repeating the message's usage, and a later block's output_tokens can be
  # higher (it was still streaming). So a message counts once, with the usage
  # of its last entry: the newest message stays "pending" until the next one
  # starts, and only then lands in the buckets.
  #
  # A bucket is the model id (date snapshot suffix dropped) plus ":fast" for a
  # fast-mode request and ":long" for one whose prompt exceeded LONG_PROMPT —
  # the two things the price list charges differently per request. PriceTable
  # falls back to the plain model when it has no rate for a variant.
  class TranscriptUsage
    KINDS = %w[input cache_write_5m cache_write_1h cache_read output].freeze
    # Haiku 5.5 charges more for a prompt over 100k tokens (pricing page,
    # "Long context pricing"); every other model prices the full window flat.
    LONG_PROMPT = 100_000
    SYNTHETIC_MODEL = "<synthetic>"

    def self.empty_state = { "size" => 0, "mtime" => nil, "offset" => 0, "buckets" => {}, "pending" => nil }

    # The state brought up to date with the file: unchanged → as is, grown →
    # continued from its offset, anything else (shrunk, rewritten) → from 0.
    def self.scan(path, state = nil)
      stat = File.stat(path)
      mtime = stat.mtime.to_f
      return state if state && state["size"] == stat.size && state["mtime"] == mtime

      state = empty_state unless state && stat.size > state["size"].to_i && state["offset"].to_i <= stat.size
      state = JSON.parse(JSON.generate(state)) # never mutate a caller's copy
      read_from(path, state)
      state.merge("size" => stat.size, "mtime" => mtime)
    end

    # Buckets including the pending message: what the file has spent so far.
    def self.totals(state)
      buckets = deep_copy(state["buckets"] || {})
      pending = state["pending"]
      add(buckets, pending["bucket"], pending["tokens"]) if pending
      buckets
    end

    def self.add(buckets, key, tokens)
      bucket = (buckets[key] ||= KINDS.to_h { |k| [k, 0] })
      KINDS.each { |k| bucket[k] += tokens[k].to_i }
      buckets
    end

    def self.merge(into, buckets)
      buckets.each { |key, tokens| add(into, key, tokens) }
      into
    end

    def self.deep_copy(buckets) = buckets.transform_values(&:dup)

    # nil for entries that spent nothing worth counting.
    def self.entry_usage(entry)
      return nil unless entry.is_a?(Hash) && entry["type"] == "assistant"

      message = entry["message"]
      return nil unless message.is_a?(Hash) && message["usage"].is_a?(Hash)

      model = message["model"].to_s
      return nil if model == SYNTHETIC_MODEL

      usage = message["usage"]
      tokens = kinds(usage)
      return nil if tokens.values.sum.zero?

      prompt = tokens["input"] + tokens["cache_read"] + tokens["cache_write_5m"] + tokens["cache_write_1h"]
      bucket = [normalize_model(model)]
      bucket << "fast" if usage["speed"] == "fast"
      bucket << "long" if prompt > LONG_PROMPT
      { "id" => message["id"] || entry["requestId"] || entry["uuid"], "bucket" => bucket.join(":"), "tokens" => tokens }
    end

    # The 5m/1h split comes from usage.cache_creation; whatever it doesn't
    # account for is 5m, the API's default TTL.
    def self.kinds(usage)
      creation = usage["cache_creation"].is_a?(Hash) ? usage["cache_creation"] : {}
      write_total = usage["cache_creation_input_tokens"].to_i
      write_1h = creation["ephemeral_1h_input_tokens"].to_i
      write_5m = [creation["ephemeral_5m_input_tokens"].to_i, write_total - write_1h].max
      { "input" => usage["input_tokens"].to_i, "cache_write_5m" => write_5m, "cache_write_1h" => write_1h,
        "cache_read" => usage["cache_read_input_tokens"].to_i, "output" => usage["output_tokens"].to_i }
    end

    # "claude-haiku-4-5-20251001" → "claude-haiku-4-5"; "claude-opus-4-6[1m]" → "claude-opus-4-6".
    def self.normalize_model(model)
      model = model.strip.sub(/\[[^\]]*\]\z/, "").sub(/-\d{8}\z/, "")
      model.empty? ? "unknown" : model
    end

    def self.read_from(path, state)
      data = File.open(path, "rb") do |f|
        f.seek(state["offset"])
        f.read
      end.to_s
      complete = data.rindex("\n")
      return unless complete

      chunk = data[0..complete]
      state["offset"] += chunk.bytesize
      chunk.force_encoding(Encoding::UTF_8).each_line do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        usage = entry_usage(entry) or next

        pending = state["pending"]
        add(state["buckets"], pending["bucket"], pending["tokens"]) if pending && pending["id"] != usage["id"]
        state["pending"] = usage
      end
    end
    private_class_method :read_from
  end
end
