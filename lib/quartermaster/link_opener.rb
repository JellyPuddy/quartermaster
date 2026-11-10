# frozen_string_literal: true

module Quartermaster
  # The installed GUI app's outside links (the `open-url` action): an app
  # window Chrome installed opens them in Chrome itself, so the page hands them
  # here and macOS `open` puts them in the user's default browser. Only
  # absolute http(s) URLs: anything else `open` would hand to an app.
  class LinkOpener
    def initialize(runner:)
      @runner = runner
    end

    def open(url)
      raise ArgumentError, "only http and https links open in the browser" unless web_url?(url)

      result = @runner.call(["open", url])
      result.success? ? { "ok" => true } : { "ok" => false, "error" => "open failed: #{result.err.strip}" }
    end

    private

    def web_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end
  end
end
