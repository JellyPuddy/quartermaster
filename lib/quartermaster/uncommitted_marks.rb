# frozen_string_literal: true

module Quartermaster
  # Which parts of a branch diff (base → working tree) are not committed yet,
  # worked out from two more parsed diffs of the same checkout: `committed`
  # (base → HEAD) and `uncommitted` (HEAD → working tree, untracked files as
  # added). Marks each added or removed line `"uncommitted" => true` (the key
  # is left out otherwise) and gives each file a `"commitStatus"` of
  # committed, uncommitted or mixed.
  #
  # An added line shares its number with the uncommitted diff's new side (both
  # are the working tree), so it is uncommitted exactly when that diff adds
  # it. A removed line is a base line: committed when base → HEAD removes it,
  # otherwise it maps to a HEAD line through that diff's hunks, and is
  # uncommitted exactly when HEAD → working tree removes that line. A line
  # whose answer depends on a truncated or binary file stays unmarked, and a
  # truncated branch file gets no line marks at all.
  class UncommittedMarks
    def self.apply(files, committed:, uncommitted:) = new(committed, uncommitted).apply(files)

    def initialize(committed, uncommitted)
      @committed_by_old = by(committed, "oldPath") { |f| f["status"] != "added" }
      @committed_by_new = by(committed, "path") { |f| f["status"] != "deleted" }
      @uncommitted_by_old = by(uncommitted, "oldPath") { |f| f["status"] != "added" }
      @uncommitted_by_new = by(uncommitted, "path") { |f| f["status"] != "deleted" }
      @sides = {}.compare_by_identity
    end

    def apply(files)
      files.each { |file| mark(file) }
      files
    end

    private

    def by(files, key) = files.select { |f| yield f }.to_h { |f| [f[key], f] }

    def mark(file)
      marks = file["truncated"] || file["binary"] ? [nil] : change_lines(file).map { |line| mark_line(file, line) }
      file["commitStatus"] =
        if marks.any? && marks.none?(&:nil?)
          status(marks.include?(true), marks.include?(false))
        else
          status(marks.include?(true) || touched_uncommitted?(file), marks.include?(false) || touched_committed?(file))
        end
    end

    def status(uncommitted, committed)
      return "mixed" if uncommitted && committed

      uncommitted ? "uncommitted" : "committed"
    end

    def change_lines(file) = file["hunks"].flat_map { |h| h["lines"].reject { |l| l["t"] == " " } }

    # true / false, or nil when it can't be told.
    def mark_line(file, line)
      mark = line["t"] == "+" ? added_uncommitted?(file, line["n"]) : removed_uncommitted?(file, line["o"])
      line["uncommitted"] = true if mark
      mark
    end

    def added_uncommitted?(file, number)
      other = @uncommitted_by_new[file["path"]]
      return false unless other

      side = sides(other)
      side && side[:added].include?(number)
    end

    def removed_uncommitted?(file, number)
      head_path, head_line = head_position(file, number)
      return head_path unless head_path

      other = @uncommitted_by_old[head_path]
      return false unless other

      side = sides(other)
      side && side[:removed].include?(head_line)
    end

    # The base line's path and number in HEAD; false when the branch's
    # commits removed it, nil when that can't be told.
    def head_position(file, number)
      commit = @committed_by_old[file["oldPath"]]
      return [file["oldPath"], number] unless commit
      return [false] if commit["status"] == "deleted" && !commit["binary"]

      side = sides(commit)
      return [nil] unless side
      return [false] if side[:removed].include?(number)
      return [commit["path"], side[:context][number]] if side[:context].key?(number)

      shift = side[:hunks].sum { |last_old, delta| last_old < number ? delta : 0 }
      [commit["path"], number + shift]
    end

    # A file's added and removed line numbers, its context lines old → new,
    # and per hunk its last old line (the line an insertion follows) with how
    # far it moves the lines below it. nil when the file's lines are not all
    # there.
    def sides(file)
      return @sides[file] if @sides.key?(file)

      @sides[file] = file["truncated"] || file["binary"] ? nil : collect_sides(file)
    end

    def collect_sides(file)
      side = { added: Set.new, removed: Set.new, context: {}, hunks: [] }
      file["hunks"].each do |hunk|
        old_count = new_count = 0
        hunk["lines"].each do |line|
          case line["t"]
          when "+" then side[:added] << line["n"]
          when "-" then side[:removed] << line["o"]
          else side[:context][line["o"]] = line["n"]
          end
          old_count += 1 unless line["t"] == "+"
          new_count += 1 unless line["t"] == "-"
        end
        last_old = old_count.zero? ? hunk["oldStart"] : hunk["oldStart"] + old_count - 1
        side[:hunks] << [last_old, new_count - old_count]
      end
      side
    end

    # Cheap file-level answers, for files whose lines can't all be told.
    def touched_uncommitted?(file)
      commit = @committed_by_old[file["oldPath"]]
      head_path = commit ? commit["path"] : file["oldPath"]
      @uncommitted_by_new.key?(file["path"]) || (file["status"] != "added" && @uncommitted_by_old.key?(head_path))
    end

    def touched_committed?(file)
      (file["status"] != "added" && @committed_by_old.key?(file["oldPath"])) || @committed_by_new.key?(file["path"])
    end
  end
end
