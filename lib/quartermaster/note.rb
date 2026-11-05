# frozen_string_literal: true

module Quartermaster
  # One note line in a work item's ## Notes section — the only place the
  # stored format is parsed or written. Renderers read attributes; nothing
  # else matches NOTE_LINE.
  class Note
    # The stored note line. The kind marker is optional so every note written
    # before kinds existed still parses — an unrecognised marker falls back to
    # the default rather than dropping the note, since this parse runs inside
    # the hook.
    NOTE_LINE = /\A- (\d{4}-\d{2}-\d{2})(?: \[([a-z]+)\])?: (.*)\z/

    attr_reader :stamp, :kind, :text, :position

    # nil unless the line is a stored note. An unrecognised kind marker falls
    # back to the default rather than dropping the note — this parse runs
    # inside the hook.
    def self.parse(line, position: nil)
      match = line.chomp.match(NOTE_LINE)
      return nil unless match

      kind = NOTE_KINDS.include?(match[2]) ? match[2] : DEFAULT_NOTE_KIND
      new(stamp: match[1], kind: kind, text: match[3].strip, position: position)
    end

    def initialize(stamp:, kind:, text:, position: nil)
      @stamp = stamp.to_s
      @kind = kind
      @text = text
      @position = position
    end

    def open? = kind == "open"
    def history? = kind == "history"

    def with_kind(kind)
      Note.new(stamp: stamp, kind: kind, text: text, position: position)
    end

    # The stored form. The default kind is left unmarked, so the common note
    # stays as readable in the raw file as it was before kinds existed (and
    # so do the pre-kind notes).
    def to_s
      marker = kind == DEFAULT_NOTE_KIND ? "" : " [#{kind}]"
      "- #{stamp}#{marker}: #{text}"
    end

    def to_h
      { "stamp" => stamp, "kind" => kind, "text" => text, "position" => position }
    end
  end
end
