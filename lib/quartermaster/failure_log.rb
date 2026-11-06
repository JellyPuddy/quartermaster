# frozen_string_literal: true

module Quartermaster
  # Writes qm.log. A failure is one header line, `<iso8601> [<context>]
  # <Class>: <message>`, followed by up to BACKTRACE_FRAMES lines indented two
  # spaces: its first frames inside the repo's lib/, repo-relative. A transient
  # failure (the network, or a browser tab gone mid-write) carries TRANSIENT
  # after its context. In a SUCCESS_REPORTING context it is written only once
  # per outage, and the context's next success ends the outage with one
  # `recovered after <n> failure(s)` header; any other context could never end
  # an outage, so it writes every failure. Outages live in this process only.
  module FailureLog
    TRANSIENT = "transient"
    # The contexts with a Quartermaster.log_success call site.
    SUCCESS_REPORTING = %w[pr-inbox pr-deployment pr-refresh gui-client].freeze
    BACKTRACE_FRAMES = 3
    REPO = File.expand_path("../..", __dir__)
    LIB = File.join(REPO, "lib", "")
    # Messages gh prints when it can't reach GitHub at all.
    NETWORK_MESSAGES = Regexp.union(
      /error connecting to api\.github\.com/i, /githubstatus\.com/i, /connection reset/i,
      /dial tcp/i, /read tcp/i, /i\/o timeout/i, /TLS handshake timeout/i,
      /\Agh .*: EOF\z/m
    )
    # A client that hung up mid-response: the browser's doing, not qm's.
    DISCONNECTS = [Errno::EPIPE, Errno::ECONNRESET].freeze

    OUTAGES = {}
    MUTEX = Mutex.new

    module_function

    def transient?(error)
      DISCONNECTS.any? { |klass| error.is_a?(klass) } || error.message.to_s.match?(NETWORK_MESSAGES)
    end

    def failure(context, error)
      if transient?(error)
        return if SUCCESS_REPORTING.include?(context) && !first_of_outage?(context)

        tag = "#{TRANSIENT} "
      end
      message = error.message.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")
      append(["#{Time.now.iso8601} [#{context}] #{tag}#{error.class}: #{message}", *lib_frames(error)])
    end

    def first_of_outage?(context)
      MUTEX.synchronize { (OUTAGES[context] = OUTAGES.fetch(context, 0) + 1) == 1 }
    end

    def success(context)
      failures = MUTEX.synchronize { OUTAGES.delete(context) }
      return unless failures

      append(["#{Time.now.iso8601} [#{context}] recovered after #{failures} failure#{"s" unless failures == 1}"])
    end

    def lib_frames(error)
      (error.backtrace || []).select { |frame| frame.start_with?(LIB) }
                             .first(BACKTRACE_FRAMES)
                             .map { |frame| "  #{frame.delete_prefix("#{REPO}/")}" }
    end

    def append(lines)
      Quartermaster.ensure_setup
      File.open(LOG_FILE, "a") { |f| f.write(lines.map { |line| "#{line}\n" }.join) }
    end

    def reset = MUTEX.synchronize { OUTAGES.clear }
  end
end
