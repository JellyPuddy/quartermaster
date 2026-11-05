# frozen_string_literal: true

module Quartermaster
  # Comments the user left on lines of the diff pane, as the one message the
  # chat receives: a short header, then per comment the line's path:line
  # (path:first-last for a range of lines), the line(s) quoted, and what he
  # wrote about it. A removed line is addressed by its number in the base,
  # and says so; one made in the PR scope names the PR and the commit its
  # numbers are from. The header names the branch the comments were written
  # on when they agree; otherwise each names its own.
  module DiffComments
    module_function

    # entries: [{ "path", "line", "side" ("new" | "old"), "code", "comment",
    #             "range" (optional: "abc1234" or "abc1234..def5678"),
    #             "start_line", "start_side" (optional: a range of lines),
    #             "repo", "number", "commit" (optional: made in the PR scope),
    #             "branch", "committed" (optional: where it was written) }]
    # branch/base: what the pane shows at send time, standing in for a comment
    # that doesn't say where it was written (one older than the field).
    def message(entries, branch: nil, base: nil)
      shown = branch.to_s.strip
      entries = Array(entries).select { |e| e.is_a?(Hash) }
      branches = entries.map { |e| e["branch"].to_s.strip.empty? ? shown : e["branch"].to_s.strip }.uniq
      header_branch = branches.size == 1 ? branches.first : ""
      comments = entries.filter_map { |e| entry(e, header_branch) }
      raise ArgumentError, "no comments to send" if comments.empty?

      on = header_branch.empty? ? "the diff" : "the diff of #{header_branch}"
      on += " (vs #{base.to_s.strip})" unless base.to_s.strip.empty? || header_branch != shown
      header = "Review comments on #{on} — #{comments.size} comment#{"s" unless comments.size == 1}:"
      ([header] + comments).join("\n\n")
    end

    def entry(raw, header_branch = "")
      return nil unless raw.is_a?(Hash)

      comment = raw["comment"].to_s.strip
      path = raw["path"].to_s.strip
      return nil if comment.empty? || path.empty?

      where = "#{path}#{lines_label(raw)}#{pr_label(raw)}"
      notes = []
      notes << (raw["start_line"] ? "removed lines" : "removed line") if raw["side"] == "old" && (raw["start_side"] || "old") == "old"
      notes << on_commits(raw["range"])
      own = raw["branch"].to_s.strip
      notes << "on branch #{own}" unless own.empty? || own == header_branch
      notes << "as committed, not on disk" if raw["committed"] == true && raw["range"].to_s.strip.empty? && !raw["number"]
      where += " (#{notes.compact.join(", ")})" unless notes.compact.empty?
      [where, quote(raw["code"]), comment].compact.join("\n")
    end

    # ":12", ":12-15" for a range on one side, ":old 12-new 15" across sides.
    def lines_label(raw)
      line = Integer(raw["line"], exception: false)
      return "" unless line

      start = Integer(raw["start_line"], exception: false)
      return ":#{line}" unless start

      start_side = raw["start_side"] || raw["side"]
      return ":#{start}-#{line}" if start_side.to_s == raw["side"].to_s

      ":#{start_side} #{start}-#{raw["side"]} #{line}"
    end

    # " on widgets#7 @abc1234": a PR-scope draft's numbers are that commit's.
    def pr_label(raw)
      number = Integer(raw["number"], exception: false)
      return "" unless number && raw["repo"]

      commit = raw["commit"].to_s.match?(/\A\h{7,64}\z/) ? " @#{raw["commit"][0, 7]}" : ""
      " on #{raw["repo"].to_s.split("/").last}##{number}#{commit}"
    end

    # Every line quoted; nil when there is no text.
    def quote(code)
      text = code.to_s.chomp
      return nil if text.strip.empty?

      text.split("\n", -1).map { |line| "> #{line}" }.join("\n")
    end

    # A comment made on a selected commit or run of commits: its line numbers
    # are that range's, not necessarily the file on disk's.
    def on_commits(range)
      range = range.to_s.strip
      return "on commit #{range}" if range.match?(/\A\h{4,64}\z/)

      "on commits #{range}" if range.match?(/\A\h{4,64}\.\.\h{4,64}\z/)
    end

    # What a GitHub draft posts as its body: the comment as written (a
    # ```suggestion block in it is GitHub's own), and for a file comment the
    # line(s) it was written on quoted above it, since a file comment points
    # at no line.
    def github_body(raw)
      comment = raw["comment"].to_s.strip
      quoted = raw["subject"] == "file" && quote(raw["code"])
      label = lines_label(raw).delete_prefix(":")
      return comment unless quoted && !label.empty?

      "#{raw["start_line"] ? "Lines" : "Line"} #{label}:\n#{quoted}\n\n#{comment}"
    end
  end
end
