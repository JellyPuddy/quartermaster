# frozen_string_literal: true

module Quartermaster
  # What an item's work has spent: tokens and the API-equivalent cost across
  # its sessions (sub-agents included) and its asides. Asides are counted
  # here even though they never join the item — the question was still asked
  # on the item's behalf. "lower_bound" when a session expired before the
  # ledger ever tallied it; "partial" when a model has no price.
  class ItemUsage
    attr_reader :rows

    # `asides`: the item's aside sessions in log order, when the caller already grouped them.
    def self.for(item, session_log: SessionLog.new, ledger: UsageLedger.new, prices: PriceTable.load,
                 asides: session_log.sessions.select { |s| s.aside_for == item.slug })
      sessions = Quartermaster.item_sessions(item, session_log: session_log)
      asides = asides.sort_by { |s| s.started_ts.to_s }.reverse
      rows = sessions.map { |s| row(s, false, ledger, prices) } + asides.map { |s| row(s, true, ledger, prices) }
      new(rows)
    end

    def self.row(session, aside, ledger, prices)
      usage = ledger.session_usage(session)
      cost, unpriced = prices.cost(usage["buckets"])
      { "id" => session.id, "aside" => aside, "when" => session.last_ts, "known" => usage["known"],
        "agents" => usage["agents"], "tokens" => tokens(usage["buckets"]), "cost" => cost,
        "unpriced" => unpriced.map { |b| b.split(":").first }.uniq,
        "models" => models(usage["buckets"]) }
    end

    def self.tokens(buckets) = buckets.values.sum { |kinds| kinds.values.sum }

    # Tokens per model, variants (":fast", ":long") folded into their model.
    def self.models(buckets)
      buckets.each_with_object(Hash.new(0)) { |(bucket, kinds), acc| acc[bucket.split(":").first] += kinds.values.sum }
    end

    def initialize(rows)
      @rows = rows
    end

    def tokens = rows.sum { |r| r["tokens"] }
    def cost = rows.sum { |r| r["cost"] }
    def lower_bound? = rows.any? { |r| !r["known"] }
    def unpriced = rows.flat_map { |r| r["unpriced"] }.uniq
    def partial? = unpriced.any?
    def empty? = rows.empty?

    # "1.2M tok · ~$14", "≥ 1.2M tok · ≥ $14" when sessions are missing, plus
    # "· partial" when a model had no price. When no session was ever
    # tallied, "≥ 0 tok · ≥ $0.00" would be true but says nothing — common for
    # items whose sessions expired before the ledger existed.
    def line
      return "usage unknown · sessions expired" if rows.none? { |r| r["known"] }

      bound = lower_bound? ? "≥ " : ""
      [
        "#{bound}#{self.class.human_tokens(tokens)} tok",
        "#{bound.empty? ? "~" : bound}#{self.class.dollars(cost)}",
        partial? ? "partial" : nil
      ].compact.join(" · ")
    end

    def to_h
      { "tokens" => tokens, "cost" => cost.round(4), "lowerBound" => lower_bound?, "partial" => partial?,
        "unpriced" => unpriced, "line" => line,
        "sessions" => rows.map do |r|
          r.slice("id", "aside", "when", "known", "agents", "tokens", "unpriced", "models")
           .merge("cost" => r["cost"].round(4), "tokensLabel" => self.class.human_tokens(r["tokens"]),
                  "costLabel" => self.class.dollars(r["cost"]))
        end }
    end

    def self.human_tokens(count)
      # Thresholds sit where the smaller unit would round up to "1000k" / "1000.0M".
      if count >= 999_950_000 then format("%.1fB", count / 1e9)
      elsif count >= 999_500 then format("%.1fM", count / 1e6)
      elsif count >= 1_000 then format("%.0fk", count / 1e3)
      else count.to_s
      end
    end

    def self.dollars(amount)
      amount >= 10 ? "$#{amount.round}" : format("$%.2f", amount)
    end
  end
end
