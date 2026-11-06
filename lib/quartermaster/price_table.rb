# frozen_string_literal: true

module Quartermaster
  # API-equivalent prices in USD per million tokens, per model, for turning a
  # usage tally into "what this would have cost on the API" — an estimate
  # (subscription use costs nothing per token), never a bill.
  #
  # Defaults are from the official pricing page,
  # https://platform.claude.com/docs/en/about-claude/pricing, as read on
  # 2026-10-21 (standard global-routing rates; batch, data residency and
  # server-tool fees don't show up in transcripts). Fast mode is 2x input and
  # output with the cache multipliers on top; Haiku 5.5 prompts over 100k
  # tokens pay its "long" rates.
  #
  # Override or add models under `prices:` in config.yml, by bucket key
  # (TranscriptUsage), any subset of the fields:
  #
  #   prices:
  #     claude-opus-5-5: { input: 4, cache_write_5m: 5, cache_write_1h: 8, cache_read: 0.2, output: 20 }
  class PriceTable
    FIELDS = TranscriptUsage::KINDS

    def self.rates(input, write_5m, write_1h, read, output)
      FIELDS.zip([input, write_5m, write_1h, read, output]).to_h
    end

    DEFAULTS = {
      "claude-fable-5-1" => rates(10, 12.5, 20, 0.25, 50),
      "claude-mythos-5-1" => rates(10, 12.5, 20, 0.25, 50),
      "claude-fable-5" => rates(10, 12.5, 20, 1, 50),
      "claude-mythos-5" => rates(10, 12.5, 20, 1, 50),
      "claude-opus-5-5" => rates(4, 5, 8, 0.2, 20),
      "claude-opus-5-5:fast" => rates(8, 10, 16, 0.4, 40),
      "claude-opus-5" => rates(5, 6.25, 10, 0.5, 25),
      "claude-opus-5:fast" => rates(10, 12.5, 20, 1, 50),
      "claude-opus-4-8" => rates(5, 6.25, 10, 0.5, 25),
      "claude-opus-4-8:fast" => rates(10, 12.5, 20, 1, 50),
      "claude-opus-4-7" => rates(5, 6.25, 10, 0.5, 25),
      "claude-opus-4-6" => rates(5, 6.25, 10, 0.5, 25),
      "claude-opus-4-5" => rates(5, 6.25, 10, 0.5, 25),
      "claude-opus-4-1" => rates(15, 18.75, 30, 1.5, 75),
      "claude-opus-4" => rates(15, 18.75, 30, 1.5, 75),
      "claude-sonnet-5-5" => rates(2, 2.5, 4, 0.1, 10),
      "claude-sonnet-5" => rates(2, 2.5, 4, 0.2, 10),
      "claude-sonnet-4-6" => rates(3, 3.75, 6, 0.3, 15),
      "claude-sonnet-4-5" => rates(3, 3.75, 6, 0.3, 15),
      "claude-sonnet-4" => rates(3, 3.75, 6, 0.3, 15),
      "claude-haiku-5-5" => rates(0.1, 0.125, 0.2, 0.01, 0.5),
      "claude-haiku-5-5:long" => rates(0.5, 0.625, 1, 0.05, 2.5),
      "claude-haiku-4-5" => rates(1, 1.25, 2, 0.1, 5),
      "claude-3-5-haiku" => rates(0.8, 1, 1.6, 0.08, 4)
    }.freeze

    # Defaults merged with config.yml's `prices:` (ProjectConfig#prices, per
    # model, per field). A broken config never breaks a page: it falls back
    # to the defaults.
    def self.load
      new(ProjectConfig.current.prices)
    rescue StandardError => e
      Quartermaster.log_error("price-table", e)
      new({})
    end

    def initialize(overrides = {})
      @rates = DEFAULTS.transform_values(&:dup)
      overrides.each do |model, fields|
        next unless fields.is_a?(Hash)

        known = fields.to_h { |k, v| [k.to_s, v] }.slice(*FIELDS).select { |_, v| v.is_a?(Numeric) }
        @rates[model.to_s] = (@rates[model.to_s] || {}).merge(known)
      end
    end

    # The rates for a bucket key: exact, else with its variants dropped from
    # the end ("x:fast:long" → "x:fast" → "x"). nil when the model is unknown
    # or a rate is missing.
    def rates_for(bucket)
      parts = bucket.split(":")
      until parts.empty?
        rates = @rates[parts.join(":")]
        return rates if rates && FIELDS.all? { |f| rates[f].is_a?(Numeric) }

        parts.pop
      end
      nil
    end

    # [dollars, unpriced bucket keys] for a tally of buckets.
    def cost(buckets)
      unpriced = []
      dollars = buckets.sum do |bucket, tokens|
        rates = rates_for(bucket)
        unless rates
          unpriced << bucket
          next 0
        end
        FIELDS.sum { |f| tokens[f].to_i * rates[f] } / 1_000_000.0
      end
      [dollars, unpriced]
    end
  end
end
