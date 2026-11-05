# frozen_string_literal: true

module Quartermaster
  # The account's 5-hour and weekly usage limits as the status line last saw
  # them (statusline/statusline.rb writes `rate-limits.json`; see
  # docs/areas/side-panel.md for that file's contract). Read for the GUI
  # header chip and the phone page; both render countdowns from `resetsAt`
  # and grey the chip once `capturedAt` is old, so the payload carries
  # timestamps, not durations.
  class RateLimits
    FILE = File.join(ROOT, "rate-limits.json")
    WINDOWS = { "five_hour" => "fiveHour", "seven_day" => "sevenDay" }.freeze

    def initialize(path = FILE)
      @path = path
    end

    # {"fiveHour" => {"usedPercentage", "resetsAt"} | nil, "sevenDay" => …,
    # "capturedAt"}, or nil without a usable snapshot.
    def payload
      return nil unless File.exist?(@path)

      doc = JSON.parse(File.read(@path))
      captured = iso(doc["captured_at"]) if doc.is_a?(Hash)
      return nil unless captured

      windows = WINDOWS.to_h { |key, name| [name, window(doc[key])] }
      return nil if windows.values.none?

      windows.merge("capturedAt" => captured)
    rescue StandardError => e
      Quartermaster.log_error("rate-limits", e)
      nil
    end

    private

    def window(raw)
      return nil unless raw.is_a?(Hash) && raw["used_percentage"].is_a?(Numeric)

      { "usedPercentage" => raw["used_percentage"], "resetsAt" => iso(raw["resets_at"]) }
    end

    # Claude Code gives epoch seconds; an ISO string is taken as it is.
    def iso(value)
      time = case value
             when Numeric then Time.at(value)
             when String then Time.iso8601(value)
             end
      time&.utc&.iso8601
    rescue ArgumentError
      nil
    end
  end
end
