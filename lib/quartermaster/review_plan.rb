# frozen_string_literal: true

module Quartermaster
  # Where each GitHub draft of one PR goes when it is posted, decided with
  # local git against the PR's head as fetched now (PR review plan D9-D11):
  #
  #   "head"     a review thread on the head (addPullRequestReviewThread):
  #              the draft's lines still read the same at the same place in
  #              base..head, or — for a draft made on the whole PR, whose
  #              head has moved since — its line's text appears exactly once
  #              in that file's new diff ("moved": true, the new numbers).
  #              A file comment goes here while its file is in the PR.
  #   "commit"   a comment on the commit it was made on
  #              (addPullRequestReviewComment at its diff "position"): a draft
  #              made on selected commits, or pinned there from the outdated
  #              card. A commit a force-push removed is followed to the PR
  #              commit with the same patch-id ("moved": true).
  #   "outdated" neither: not posted. "oldCommit" says whether Comment on
  #              the old commit can post it, "fileGone" that its file left
  #              the PR, "context" the lines around it as it was.
  #
  #   plan = ReviewPlan.new(repo, base_ref: "origin/main", head: sha)
  #   plan.route(draft) # => { "route" => "head", "line" => 12, ... }
  class ReviewPlan
    CONTEXT = 3

    attr_reader :head

    def initialize(repo, base_ref:, head:)
      @repo = repo
      @base_ref = base_ref
      @head = ReviewAnchors.new(repo, base: base_ref, commit: head)
      @anchors = { @head.commit => @head }
    end

    def head_sha = @head.commit
    def base_sha = @head.base_sha

    def routes(entries) = entries.to_h { |entry| [entry["id"], route(entry)] }

    def route(entry)
      path = entry["path"].to_s
      if entry["subject"] == "file"
        return head_route(entry, "subject" => "file") if @head.file(path)

        return outdated(entry, "#{path} is no longer in the pull request", file_gone: true)
      end
      return commit_route(entry) || outdated(entry, "its commit's line can't take a comment any more") if pinned?(entry)
      return head_route(entry, at(entry)) if @head.refusal(entry).nil?

      if commit_anchored?(entry)
        commit_route(entry) || outdated(entry, gone_reason(entry))
      elsif (moved = reanchor(entry))
        head_route(entry, moved.merge("moved" => true))
      else
        outdated(entry, @head.file(path) ? "since the push its line isn't in the PR's diff once, unchanged" :
                                           "#{path} is no longer in the pull request", file_gone: !@head.file(path))
      end
    end

    # A draft made on selected commits anchors to their last one (F2).
    def commit_anchored?(entry) = !entry["range"].to_s.empty?

    # Moved to its old commit from the outdated card (D10).
    def pinned?(entry) = entry["pin"] == "commit"

    private

    def at(entry)
      entry.slice("line", "side", "start_line", "start_side").merge("subject" => "line")
    end

    def head_route(entry, fields)
      { "route" => "head", "path" => entry["path"], "moved" => false }.merge(fields)
    end

    # The draft's commit, or the PR commit with its patch, when its line
    # there still reads as the draft says.
    def commit_route(entry)
      commit = entry["commit"].to_s
      sha = pr_commits.include?(commit) ? commit : patch_match(commit)
      return nil unless sha

      anchors = anchors_at(sha)
      return nil unless anchors && anchors.refusal(entry).nil?

      { "route" => "commit", "path" => entry["path"], "commit" => sha, "moved" => sha != commit,
        "position" => anchors.position(entry["path"], entry["side"], entry["line"]) }
    end

    def outdated(entry, reason, file_gone: false)
      old = entry["subject"] == "file" ? nil : commit_route(entry)
      { "route" => "outdated", "path" => entry["path"], "reason" => reason, "fileGone" => file_gone,
        "oldCommit" => old && old["commit"], "context" => context(entry) }
    end

    def gone_reason(entry)
      sha = entry["commit"].to_s[0, 7]
      return "its line on #{sha} can't take a comment any more" if pr_commits.include?(entry["commit"].to_s)

      "commit #{sha} is no longer in the pull request and no commit there has its changes"
    end

    # The stored end line's text exactly once on its side of the head's diff
    # of that file; a range keeps its length and must still read the same.
    def reanchor(entry)
      path = entry["path"].to_s
      texts = entry["code"].to_s.split("\n", -1)
      return nil if texts.empty? || !@head.file(path)

      side = entry["side"]
      found = @head.lines(path, side).select { |n| @head.text(path, side, n) == texts.last }
      return nil unless found.size == 1

      moved = { "line" => found.first, "side" => side, "subject" => "line" }
      if entry["start_line"]
        return nil unless (entry["start_side"] || side) == side

        moved.merge!("start_line" => found.first - (entry["line"].to_i - entry["start_line"].to_i), "start_side" => side)
      end
      @head.refusal(entry.merge(moved)).nil? ? moved : nil
    end

    # The lines around the draft's line as its commit shows it, else just
    # its stored text: what the outdated card quotes.
    def context(entry)
      anchors = anchors_at(entry["commit"].to_s)
      hunk = anchors&.file(entry["path"].to_s)&.fetch("hunks")&.find do |h|
        h["lines"].any? { |l| l[side_key(entry)] == entry["line"].to_i }
      end
      unless hunk
        return entry["code"].to_s.split("\n", -1).map { |s| { "t" => " ", "s" => s, "at" => true } }
      end

      at = hunk["lines"].index { |l| l[side_key(entry)] == entry["line"].to_i }
      from = at - CONTEXT - (entry["start_line"] ? entry["line"].to_i - entry["start_line"].to_i : 0)
      hunk["lines"][[from, 0].max..(at + CONTEXT)].map do |l|
        l.slice("t", "s", "o", "n").merge("at" => l.equal?(hunk["lines"][at]))
      end
    end

    def side_key(entry) = entry["side"] == "old" || entry["side"] == "LEFT" ? "o" : "n"

    def anchors_at(sha)
      return @anchors[sha] if @anchors.key?(sha)

      @anchors[sha] = sha.match?(/\A\h{7,64}\z/) ? ReviewAnchors.new(@repo, base: @base_ref, commit: sha) : nil
    rescue ArgumentError
      @anchors[sha] = nil
    end

    def pr_commits
      @pr_commits ||= (git("rev-list", "#{base_sha}..#{head_sha}") || "").split
    end

    # The PR commit whose patch-id equals the gone commit's — a rebase or
    # amend that kept its changes (D11). nil when the commit isn't here at all.
    def patch_match(sha)
      return nil unless sha.match?(/\A\h{40}\z/) && git("cat-file", "-e", "#{sha}^{commit}")

      mine = patch_ids(git_raw("show", "--no-color", sha)).keys.first
      mine && patch_ids(pr_patches)[mine]
    end

    def pr_patches
      @pr_patches ||= git_raw("log", "-p", "--no-color", "#{base_sha}..#{head_sha}")
    end

    # patch-id => commit, from `git log -p`/`git show` output.
    def patch_ids(patches)
      return {} if patches.to_s.empty?

      out = Quartermaster.git(@repo, "patch-id", "--stable", stdin: patches) || ""
      out.lines.to_h { |line| line.split.first(2) }
    end

    def git(*args) = Quartermaster.git(@repo, *args)

    def git_raw(*args)
      out, _err, status = Open3.capture3("git", "-C", @repo, *args)
      status.success? ? out : ""
    end
  end
end
