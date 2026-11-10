# frozen_string_literal: true

module Quartermaster
  # The review drafts a chat records with `qm draft add` (plan D14): GitHub
  # drafts on the item's PR, authored "claude", which the user curates in the
  # diff pane and posts as a pending review. Stored straight into the Drafts
  # file — its flock and write-and-rename make a write from this process
  # safe beside a running GUI, whose pulse sees the change (Drafts.signature)
  # — so the GUI needn't run.
  #
  # Which PR: --pr's URL, else a Review item's own, else the open PR of the
  # item's branch: --branch, else the one checked out where the command runs
  # when the item links it, else the one linked branch that has an open PR.
  #
  # A line draft is held to what the diff pane's editor holds a GitHub draft
  # to (D8, ReviewAnchors.refusal): a line GitHub can't take is refused,
  # never quietly turned into a file comment — --file asks for that. The
  # numbers are those of the PR diff up to the anchor commit (base..commit):
  # the PR head, or --commit, which then carries the run of commits from the
  # PR's first to it as its range, so the pane shows it under that selection,
  # numbered the same.
  class ChatReviewDrafts
    SIDES = %w[old new].freeze

    def initialize(runner: CommandRunner.new, project_map: ProjectMap.new, cwd: Dir.pwd, revisions: nil)
      @project_map = project_map
      @cwd = cwd
      @revisions = revisions || PrRevisions.new(runner: runner)
    end

    # A line or file comment (path:, line:, start_line:, side:, commit:,
    # file:), with reply_to: a reply to that review thread, or with
    # summary: the PR's review summary and its optional verdict:. Returns
    # [entry, replaced] — replaced when it took the place of Claude's own
    # draft on the same line, thread or PR; a draft of the user's there is refused.
    def add(item, body:, path: nil, line: nil, start_line: nil, side: nil, commit: nil, file: false, reply_to: nil,
            pr: nil, branch: nil, summary: false, verdict: nil)
      raise ArgumentError, "the comment is empty" if body.to_s.strip.empty?

      if summary
        flag = { "--path" => path, "--line" => line, "--start-line" => start_line, "--side" => side, "--commit" => commit,
                 "--file" => file || nil, "--reply-to" => reply_to }.compact.keys.first
        raise ArgumentError, "a summary is on the whole PR — #{flag} doesn't apply" if flag
      elsif verdict
        raise ArgumentError, "--verdict goes with --summary"
      end

      root = repo_root(item)
      pr = which_pr(item, root, pr, branch)
      drafts = Drafts.new(item.slug)
      return add_summary(drafts, pr, verdict, body) if summary

      if reply_to
        raise ArgumentError, "a reply goes to its thread — --commit, --file and --start-line don't apply" if commit || file || start_line

        return add_reply(drafts, pr, reply_to, body, path, line)
      end

      entry = line_entry(root, pr, path, line, start_line, side || "new", commit, file).merge("comment" => body.to_s)
      refusal = ReviewAnchors.refusal(root, entry)
      raise ArgumentError, file ? refusal : "#{refusal}. Record it as a file comment with --file instead" if refusal

      where = "#{path}:#{DiffComments.lines_label(entry).delete_prefix(":")}"
      replaced = nil
      stored = drafts.put_diff_comment(entry) { |existing| replaced = keep_users(existing, where) }
      [stored, !replaced.nil?]
    end

    private

    def add_reply(drafts, pr, thread, body, path, line)
      replaced = nil
      reply = { "thread" => thread, "repo" => pr["repo"], "number" => pr["number"], "url" => pr["url"],
                "path" => path, "line" => line, "author" => "claude", "comment" => body.to_s }
      entry = drafts.put_thread_reply(reply) { |existing| replaced = keep_users(existing, "thread #{thread}") }
      [entry, !replaced.nil?]
    end

    def add_summary(drafts, pr, verdict, body)
      replaced = nil
      where = "#{@revisions.label(pr)}'s review summary"
      summary = { "repo" => pr["repo"], "number" => pr["number"], "verdict" => verdict, "author" => "claude", "comment" => body.to_s }
      entry = drafts.put_review_summary(summary) { |existing| replaced = keep_users(existing, where, "leave it") }
      [entry, !replaced.nil?]
    end

    # Claude may replace its own draft, never one the user wrote or edited —
    # checked under the drafts file's lock, so a GUI edit can't slip between.
    def keep_users(existing, where, advice = "leave it, or put yours on another line")
      return existing if existing.nil? || existing["author"] == "claude"

      raise ArgumentError, "#{where} already holds the user's draft #{existing["id"]} — #{advice}"
    end

    def repo_root(item)
      root = @project_map.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      root
    end

    def which_pr(item, root, url, branch)
      repo = Quartermaster.github_repo(root)
      pr = if url then @revisions.at_url(url)
           elsif @revisions.review?(item) || branch then pr_of(item, repo, branch)
           else branch_pr(item, repo)
           end
      unless repo.to_s.casecmp?(pr["repo"].to_s)
        raise ArgumentError, "#{pr["url"]} is not in #{item.slug}'s repo (its origin is #{repo || "unknown"})"
      end

      pr
    end

    def pr_of(item, repo, branch)
      @revisions.find(item, repo, branch) or raise ArgumentError, "#{branch || item.slug} has no open pull request — name it with --pr URL"
    end

    # The branch checked out here when the item links it, else the one
    # linked branch with an open PR.
    def branch_pr(item, repo)
      here = Quartermaster.git(@cwd, "symbolic-ref", "--quiet", "--short", "HEAD")
      return pr_of(item, repo, here) if here && item.branches.include?(here)

      prs = item.branches.filter_map { |b| @revisions.find(item, repo, b) }
      return prs.first if prs.size == 1

      raise ArgumentError, "none of #{item.slug}'s branches has an open pull request — name it with --pr URL" if prs.empty?

      raise ArgumentError, "#{item.slug} has several open pull requests (#{prs.map { |pr| @revisions.label(pr) }.join(", ")}) " \
                           "— pick one with --branch or --pr URL"
    end

    # The Drafts line fields of a GitHub draft, the line's text(s) read from
    # base..commit so the anchor check compares like with like.
    def line_entry(root, pr, path, line, start_line, side, commit, file)
      raise ArgumentError, "a draft needs --path and --line" if path.to_s.empty? || line.nil?
      raise ArgumentError, "--side is old or new" unless SIDES.include?(side)
      raise ArgumentError, "--line and --start-line are line numbers" unless line.to_i.positive? && (start_line.nil? || start_line.to_i.positive?)
      raise ArgumentError, "--start-line #{start_line} comes after --line #{line}" if start_line && start_line.to_i > line.to_i

      revs = @revisions.fetch(root, pr)
      anchor, range = anchor_commit(root, revs, commit)
      anchors = ReviewAnchors.new(root, base: revs["baseSha"], commit: anchor)
      start_line = nil if start_line.to_i == line.to_i
      texts = start_line ? anchors.span(path, side, start_line, side, line) : [anchors.text(path, side, line)].compact
      texts ||= [anchors.text(path, side, start_line), anchors.text(path, side, line)].compact
      # A file comment quotes its line, which needn't be in the diff.
      texts = blob_lines(root, side == "old" ? revs["baseSha"] : anchor, path, start_line || line, line) if file && texts.empty?
      { "kind" => "github-comment", "path" => path, "side" => side, "line" => line.to_i, "code" => texts.join("\n"),
        "start_line" => start_line&.to_i, "start_side" => start_line && side, "range" => range,
        "repo" => pr["repo"], "number" => pr["number"], "base" => revs["baseSha"], "commit" => anchor,
        "subject" => file ? "file" : "line", "author" => "claude" }.compact
    end

    def blob_lines(root, commit, path, from, to)
      content, _err, status = Open3.capture3("git", "-C", root, "show", "#{commit}:#{path}")
      return [] unless status.success?

      content.force_encoding(Encoding::UTF_8).scrub("?").lines(chomp: true)[(from.to_i - 1)..(to.to_i - 1)] || []
    end

    # The PR head, or --commit when it is one of the PR's commits, with the
    # run from the PR's first commit to it (the pane's label for it).
    def anchor_commit(root, revs, commit)
      head = revs["headSha"]
      return [head, nil] if commit.nil?

      sha = Quartermaster.git(root, "rev-parse", "--verify", "--quiet", "#{commit}^{commit}")
      commits = Quartermaster.git(root, "log", "--reverse", "--format=%H %h", "#{revs["baseSha"]}..#{head}").to_s.lines.map(&:split)
      raise ArgumentError, "#{commit} is not one of the pull request's commits" unless sha && commits.any? { |full, _| full == sha }
      return [head, nil] if sha == head

      first = commits.first
      last = commits.find { |full, _| full == sha }
      [sha, first == last ? last[1] : "#{first[1]}..#{last[1]}"]
    end
  end
end
