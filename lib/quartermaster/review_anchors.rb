# frozen_string_literal: true

module Quartermaster
  # Where a GitHub review comment anchored to one commit of a PR can sit. GitHub
  # validates it against the PR diff base..commit (base: the merge-base of
  # the PR's base with that commit) — not the commit's own parent..commit —
  # so only lines inside that diff's hunks take a comment (3 context lines,
  # hunks one line apart joined: GITHUB_HUNKS): RIGHT lines by their number
  # in the commit, LEFT lines by their number in the base. addPullRequestReviewComment addresses a line by
  # its diff position instead: 1 for the line below the file's first @@
  # header, counting every line after it — later @@ headers and "\ No newline"
  # markers included — up to the next file.
  #
  #   anchors = ReviewAnchors.new(repo, base: "origin/main", commit: sha)
  #   anchors.commentable?("lib/a.rb", "RIGHT", 12)
  #   anchors.position("lib/a.rb", "RIGHT", 12) # => 7
  #   anchors.file("lib/a.rb") # UnifiedDiff's file, each line with its "p"
  class ReviewAnchors
    SIDES = %w[LEFT RIGHT].freeze
    # GitHub joins two hunks one unchanged line apart into one, which makes
    # that line commentable and shifts every later position.
    GITHUB_HUNKS = "--inter-hunk-context=1"

    attr_reader :base_sha, :commit

    # base: any ref or sha on the PR's base side (origin/<base>, the PR's
    # base sha); commit: the commit comments would anchor to.
    def initialize(repo, base:, commit:)
      @repo = repo
      @commit = git("rev-parse", "--verify", "--quiet", "#{commit}^{commit}") or
        raise ArgumentError, "#{commit} is not a commit in #{repo}"
      @base_sha = git("merge-base", base, @commit) or
        raise ArgumentError, "#{commit} shares no history with #{base}"
      @lines = {}
    end

    # The file's base..commit diff as UnifiedDiff parses it, every line also
    # carrying its diff position "p"; nil when the diff doesn't touch it.
    # Found by its path in the commit, or a deleted file's old path.
    def file(path) = files[path]

    # The numbers a comment on that side can take: RIGHT the added and
    # context lines' new numbers, LEFT the removed and context lines' old ones.
    def lines(path, side)
      key = side_key(side)
      (file(path)&.fetch("hunks") || []).flat_map { |h| h["lines"] }.filter_map { |l| l[key] }
    end

    def commentable?(path, side, line) = !find_line(path, side, line).nil?

    # The 1-based diff position addPullRequestReviewComment takes, or nil
    # when that line is outside the diff's hunks.
    def position(path, side, line) = find_line(path, side, line)&.fetch("p")

    # The line's text, for checking a stored draft still sits on it.
    def text(path, side, line) = find_line(path, side, line)&.fetch("s")

    # The texts of every diff line from one line to another, both included
    # and in diff order — a range draft's `code`, as the diff pane joins its
    # rows. nil unless both are in the same hunk.
    def span(path, from_side, from_line, side, line)
      first = find_line(path, from_side, from_line)
      last = find_line(path, side, line)
      return nil unless first && last && first["h"] == last["h"]

      first, last = last, first if first["p"] > last["p"]
      file(path)["hunks"][first["h"]]["lines"].select { |l| l["p"].between?(first["p"], last["p"]) }.map { |l| l["s"] }
    end

    # Whether GitHub takes a comment on this line of a view diffed from
    # view_base (the PR's base, or a selected run's parent): inside the
    # hunks and still this text. A removed line is numbered by view_base, so
    # it counts only when that is GitHub's base too. side: LEFT/RIGHT or the
    # diff pane's old/new.
    def anchorable?(path, side, line, text, view_base: @base_sha)
      return false if side_key(side) == "o" && view_base != @base_sha

      found = find_line(path, side, line)
      !found.nil? && found["s"] == text.to_s
    end

    # Why GitHub won't take this draft (Drafts' line and PR fields) at this
    # commit, or nil when it will: a line comment needs both ends of its
    # range anchorable, a file comment only its file in the diff.
    def refusal(entry, view_base: @base_sha)
      path = entry["path"].to_s
      at = "#{entry["repo"].to_s.split("/").last}##{entry["number"]} @#{@commit[0, 7]}"
      return "#{path} isn't in the diff of #{at}" unless file(path)
      return nil if entry["subject"] == "file"

      texts = entry["code"].to_s.split("\n", -1)
      texts = [""] if texts.empty?
      ends = [[entry["start_side"] || entry["side"], entry["start_line"] || entry["line"], texts.first],
              [entry["side"], entry["line"], texts.last]]
      side, line, = ends.find { |s, l, t| !anchorable?(path, s, l, t, view_base: view_base) }
      unless line
        return nil if find_line(path, *ends.first[0, 2])["h"] == find_line(path, *ends.last[0, 2])["h"]

        return "#{path}:#{DiffComments.lines_label(entry).delete_prefix(":")} spans two hunks of #{at}'s diff " \
               "— GitHub takes a range of lines only inside one"
      end
      if side_key(side) == "o" && view_base != @base_sha
        return "#{path}:#{line} is a removed line of the selected commits, numbered from them, not from the PR's base " \
               "— GitHub can't take a comment there; select all commits to comment on it"
      end

      "GitHub can't take a comment on #{path}:#{line} at #{at}: only lines the PR's diff up to that commit " \
        "shows (changes and 3 lines around them) take one"
    end

    # The refusal for a draft as stored: anchored to its commit, against its
    # PR's base, numbered like the view it was made in (a selected run's
    # parent, else the base). A draft without a base can't be checked.
    def self.refusal(repo, entry)
      return "the draft doesn't know its PR's base commit" unless entry["base"].to_s.match?(/\A\h{7,64}\z/)

      anchors = new(repo, base: entry["base"], commit: entry["commit"].to_s)
      from = entry["range"].to_s.split("..").first
      view_base = from ? Quartermaster.git(repo, "rev-parse", "--verify", "--quiet", "#{from}^") : anchors.base_sha
      anchors.refusal(entry, view_base: view_base)
    end

    private

    # Indexed per path and side once; each line found carries its hunk's
    # index "h", so a range can be held to one hunk.
    def find_line(path, side, line)
      key = side_key(side)
      index = @lines[[path, key]] ||= (file(path)&.fetch("hunks") || []).each_with_index.with_object({}) do |(hunk, h), found|
        hunk["lines"].each { |l| found[l[key]] ||= l.merge("h" => h) if l[key] }
      end
      index[line.to_i]
    end

    # Every file of the diff, parsed once: by its path, and a deleted one by
    # its old path too.
    def files
      @files ||= chunks.each_with_object({}) do |chunk, by_path|
        parsed = UnifiedDiff.parse(chunk, max_lines: Float::INFINITY).first or next
        number_positions(chunk, parsed)
        by_path[parsed["path"]] ||= parsed
        by_path[parsed["oldPath"]] ||= parsed if parsed["status"] == "deleted"
      end
    end

    # The diff pane's "old"/"new" are GitHub's LEFT/RIGHT.
    def side_key(side)
      side = { "old" => "LEFT", "new" => "RIGHT" }.fetch(side.to_s, side.to_s.upcase)
      raise ArgumentError, "side must be LEFT or RIGHT, not #{side.inspect}" unless SIDES.include?(side)

      side == "LEFT" ? "o" : "n"
    end

    # The parsed file's lines are the chunk's +/-/space lines in order, so
    # one walk over the raw text numbers them.
    def number_positions(chunk, parsed)
      body = parsed["hunks"].flat_map { |h| h["lines"] }.each
      position = nil
      chunk.each_line(chomp: true) do |raw|
        if position.nil?
          position = 0 if raw.start_with?("@@ ")
          next
        end
        position += 1
        next if raw.start_with?("@@ ", "\\")

        body.next["p"] = position
      end
      parsed
    end

    # The diff split per file, each chunk from its `diff --git` line.
    def chunks
      @chunks ||= begin
        out, _err, status = Open3.capture3("git", "-c", "core.quotepath=off", "-C", @repo, "diff", "--no-color",
                                           "--no-ext-diff", "-M", GITHUB_HUNKS, @base_sha, @commit, "--")
        raise ArgumentError, "git diff #{@base_sha[0, 7]}..#{@commit[0, 7]} failed" unless status.success?

        out.force_encoding(Encoding::UTF_8).scrub("?").split(/^(?=diff --git )/)
      end
    end

    def git(*args) = Quartermaster.git(@repo, *args)
  end
end
