# frozen_string_literal: true

require "time"

module Quartermaster
  # The errors in qm.log the user hasn't seen yet: header lines (FailureLog's
  # format) that are neither transient nor recovered, newer than the time in
  # errors-seen-at (absent or unreadable: the last WINDOW), each with its
  # backtrace continuation lines. Reads only the log's last tail_bytes. Feeds
  # the GUI's error badge and qm doctor; the status line repeats the parse,
  # since it may not load lib/.
  class ErrorLog
    SEEN_FILE = File.join(ROOT, "errors-seen-at")
    TAIL_BYTES = 256 * 1024
    WINDOW = 24 * 3600
    SHOWN = 20
    HEADER = /\A(\S+) \[([^\]]*)\] (.*)\z/
    NOT_ERRORS = /\A(?:#{FailureLog::TRANSIENT} |recovered after )/

    def initialize(log: LOG_FILE, seen_file: SEEN_FILE, now: Time.now, tail_bytes: TAIL_BYTES)
      @log = log
      @seen_file = seen_file
      @now = now
      @tail_bytes = tail_bytes
    end

    # Unseen errors, oldest first: {"at", "context", "lines" (header first)}.
    def entries
      @entries ||= parse(tail).select { |entry| entry.delete(:time) > since }
    end

    def count = entries.size

    # The GUI's badge: the count and the newest SHOWN entries, newest first.
    def summary
      { "count" => count, "entries" => entries.last(SHOWN).reverse }
    end

    def since
      Time.iso8601(File.read(@seen_file).strip)
    rescue StandardError
      @now - WINDOW
    end

    def mark_seen
      Quartermaster.ensure_setup
      File.write(@seen_file, "#{@now.iso8601}\n")
      @entries = nil
    end

    private

    def tail
      File.open(@log, "rb") do |f|
        start = [f.size - @tail_bytes, 0].max
        f.seek(start)
        text = f.read.force_encoding(Encoding::UTF_8).scrub
        start.zero? ? text : text.partition("\n").last
      end
    rescue SystemCallError
      ""
    end

    # A continuation belongs to the header above it; one with no error header
    # above it (a skipped header, or the tail's cut start) is dropped.
    def parse(text)
      current = nil
      text.each_line(chomp: true).each_with_object([]) do |line, found|
        if line.match?(/\A\s/)
          current["lines"] << line if current
        elsif line.empty?
          current = nil
        elsif (current = error_entry(line))
          found << current
        end
      end
    end

    def error_entry(line)
      match = HEADER.match(line)
      return unless match && !match[3].match?(NOT_ERRORS)

      { "at" => match[1], "context" => match[2], "lines" => [line], time: Time.iso8601(match[1]) }
    rescue ArgumentError
      nil
    end
  end
end
