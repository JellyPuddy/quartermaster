# frozen_string_literal: true

module Quartermaster
  # Git's unified diff text as files → hunks → lines, the shape the chat
  # view's diff pane renders. Each line carries its old and new line number,
  # so a line can be addressed as `path:line`. Past `max_lines` the rest of
  # the diff keeps its files and stats but loses its lines (`truncated`), so a
  # huge generated file can't take the page down.
  class UnifiedDiff
    HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)\z/

    def self.parse(text, max_lines: 20_000) = new(max_lines).parse(text)

    def initialize(max_lines)
      @budget = max_lines
      @truncated = false
    end

    attr_reader :truncated

    def parse(text)
      files = []
      file = nil
      hunk = nil
      old_left = new_left = 0
      text.to_s.each_line(chomp: true) do |line|
        if hunk && (old_left.positive? || new_left.positive?)
          kind = line[0]
          if kind == "\\"
            next
          elsif kind == "+"
            new_left -= 1
            file["additions"] += 1
            add_line(file, hunk, "+", nil, hunk[:new], line[1..])
            hunk[:new] += 1
            next
          elsif kind == "-"
            old_left -= 1
            file["deletions"] += 1
            add_line(file, hunk, "-", hunk[:old], nil, line[1..])
            hunk[:old] += 1
            next
          elsif kind == " " || line.empty?
            old_left -= 1
            new_left -= 1
            add_line(file, hunk, " ", hunk[:old], hunk[:new], line[1..].to_s)
            hunk[:old] += 1
            hunk[:new] += 1
            next
          end
        end

        if line.start_with?("diff --git ")
          file = new_file(line)
          files << file
          hunk = nil
        elsif file.nil?
          next
        elsif (m = HUNK.match(line))
          old_left = m[2] ? m[2].to_i : 1
          new_left = m[4] ? m[4].to_i : 1
          hunk = { old: m[1].to_i, new: m[3].to_i,
                   json: { "header" => line, "oldStart" => m[1].to_i, "newStart" => m[3].to_i, "lines" => [] } }
          file["hunks"] << hunk[:json]
        elsif line.start_with?("\\")
          next
        elsif hunk.nil?
          header_line(file, line)
        end
      end
      files
    end

    private

    def add_line(file, hunk, kind, old_no, new_no, text)
      if @budget <= 0
        file["truncated"] = true
        @truncated = true
        return
      end
      @budget -= 1
      hunk[:json]["lines"] << { "t" => kind, "o" => old_no, "n" => new_no, "s" => text }
    end

    # The `diff --git a/X b/Y` line only seeds the paths: with spaces in a
    # name it is ambiguous, so the ---/+++ and rename lines overwrite it.
    def new_file(line)
      paths = line.delete_prefix("diff --git ")
      old_path, new_path = paths.start_with?("a/") && paths.include?(" b/") ? paths[2..].split(" b/", 2) : [paths, paths]
      { "path" => new_path, "oldPath" => old_path, "status" => "modified", "binary" => false,
        "additions" => 0, "deletions" => 0, "truncated" => false, "hunks" => [] }
    end

    def header_line(file, line)
      case line
      when /\Anew file mode/ then file["status"] = "added"
      when /\Adeleted file mode/ then file["status"] = "deleted"
      when /\Arename from (.*)/ then file["oldPath"] = Regexp.last_match(1)
      when /\Arename to (.*)/
        file["path"] = Regexp.last_match(1)
        file["status"] = "renamed"
      when /\ABinary files .* differ\z/ then file["binary"] = true
      when %r{\A--- (?:a/)?(.*)\z}
        file["oldPath"] = Regexp.last_match(1) unless Regexp.last_match(1) == "/dev/null"
      when %r{\A\+\+\+ (?:b/)?(.*)\z}
        file["path"] = Regexp.last_match(1) unless Regexp.last_match(1) == "/dev/null"
      end
    end
  end
end
