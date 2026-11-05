# frozen_string_literal: true

module Quartermaster
  # When a chat's context is worth rotating. Only ever
  # an offer: rotation types into the user's chat and ends the session, so it
  # never happens without his click.
  #
  # - amber from AMBER tokens, red from RED: the meter's colour, and from
  #   amber on the list row offers "rotate?";
  # - a cold cache (no assistant reply for COLD_AFTER) on a context above
  #   COLD_MIN: the next turn re-sends all of it uncached, so reopening the
  #   item offers a rotation before continuing.
  module ContextMeter
    AMBER = 150_000
    RED = 250_000
    COLD_MIN = 50_000
    COLD_AFTER = 3600

    module_function

    def level(tokens)
      return nil unless tokens
      return "red" if tokens >= RED

      "amber" if tokens >= AMBER
    end

    # "threshold", "cold" or nil.
    def rotate_offer(tokens, last_assistant_at, now = Time.now)
      return nil unless tokens
      return "threshold" if tokens >= AMBER

      "cold" if tokens > COLD_MIN && last_assistant_at && now - last_assistant_at > COLD_AFTER
    end
  end
end
