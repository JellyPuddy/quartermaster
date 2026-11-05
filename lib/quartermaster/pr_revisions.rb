# frozen_string_literal: true

module Quartermaster
  # The pull request the diff pane's PR scope shows, and its two ends in
  # local git: the PR's head fetched into a qm-private ref and its merge-base
  # with origin/<base>, so a local diff matches GitHub's line for line — no
  # worktree needed, and in a gh-stack each PR diffs against its parent
  # branch because that is its base on GitHub.
  #
  # Which PR: a Review item's own (PrItems#review_pr), else the selected
  # branch's open PR — from the PRs view's cache (PrInbox), else asked of gh.
  #
  # memo (the GUI's PrMemo): find and fetch reuse what they found for a
  # minute unless asked fresh. Without one (the CLI, review posting) both
  # always ask the network.
  class PrRevisions
    REF_PREFIX = "refs/quartermaster/pr/"
    GH_FIELDS = "number,url,title,headRefName,baseRefName,state"
    # What may reach a fetch refspec as a branch name.
    BRANCH_NAME = %r{\A(?!-)(?!.*\.\.)[\w./-]+\z}
    FETCH_MUTEX = Mutex.new
    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)/?\z}

    def initialize(runner: CommandRunner.new, inbox: PrInbox.new, pr_items: PrItems.new, memo: nil)
      @runner = runner
      @inbox = inbox
      @pr_items = pr_items
      @memo = memo
    end

    def review?(item) = !@pr_items.review_pr(item).nil?

    # { "repo", "number", "url", "title", "head", "base" }, or nil when the
    # branch has no open PR. `repo` is the project's origin ("owner/name").
    # cached_only: only what is known without GitHub (the PRs view's cache,
    # a Review item's own PR) — whether to offer the scope, asked on every
    # diff load, must never wait on the network.
    def find(item, repo, branch, cached_only: false, fresh: false)
      return lookup(item, repo, branch, cached_only) if cached_only || !@memo

      @memo.fetch(["find", item.slug, repo, branch], fresh: fresh) { lookup(item, repo, branch, false) }
    end

    private def lookup(item, repo, branch, cached_only)
      if (review = @pr_items.review_pr(item))
        hit = @inbox.cached_prs.find { |pr| pr["url"] == review["url"] }
        return hit || (cached_only ? review : gh_view(review["url"], review["repo"]))
      end
      return nil unless repo && branch && !branch.empty?

      hit = @inbox.cached_prs.find { |pr| pr["repo"].to_s.casecmp?(repo) && pr["head"] == branch }
      return hit if hit || cached_only

      pr = gh_view(branch, repo)
      pr if pr && pr["state"] == "OPEN"
    end

    # The PR a github.com pull URL names, open or not: the PRs view's cache,
    # else asked of gh.
    def at_url(url)
      m = PR_URL.match(url.to_s.strip) or raise ArgumentError, "#{url} is not a GitHub pull request URL"
      url = "https://github.com/#{m[1]}/pull/#{m[2]}"
      @inbox.cached_prs.find { |pr| pr["url"] == url } || gh_view(url, m[1]) or
        raise ArgumentError, "gh found no pull request #{url}"
    end

    # Fetches the PR's head into refs/quartermaster/pr/<n> and its base branch
    # into origin/<base>: { "headSha", "baseSha" (the merge-base GitHub diffs
    # from), "baseRef" }. With a memo, a fetch of the last minute is reused
    # while the ref here still holds the head it fetched and the base commit
    # is here too.
    def fetch(path, pr, fresh: false)
      number = pr["number"].to_i
      base = pr["base"].to_s
      raise ArgumentError, "#{label(pr)} has no usable base branch (#{base.inspect})" unless number.positive? && BRANCH_NAME.match?(base)

      ref = "#{REF_PREFIX}#{number}"
      return fetch_now(path, pr, ref, number, base) unless @memo

      held = lambda do |revs|
        Quartermaster.git(path, "rev-parse", "--quiet", "#{ref}^{commit}", "#{revs["baseSha"]}^{commit}") ==
          "#{revs["headSha"]}\n#{revs["baseSha"]}"
      end
      @memo.fetch(["fetch", pr["repo"].to_s.downcase, number, base], fresh: fresh, usable: held) do
        fetch_now(path, pr, ref, number, base)
      end
    end

    def label(pr) = "#{pr["repo"].to_s.split("/").last}##{pr["number"]}"

    private

    def fetch_now(path, pr, ref, number, base)
      result = FETCH_MUTEX.synchronize do
        @runner.call(["git", "-C", path, "fetch", "--quiet", "--no-tags", "origin",
                      "+refs/pull/#{number}/head:#{ref}", "+refs/heads/#{base}:refs/remotes/origin/#{base}"])
      end
      raise ArgumentError, "could not fetch #{label(pr)} from origin: #{result.err.strip[0, 200]}" unless result.success?

      head = Quartermaster.git(path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      raise ArgumentError, "#{label(pr)}'s head did not arrive in #{ref}" unless head

      base_sha = Quartermaster.git(path, "merge-base", "origin/#{base}", head)
      raise ArgumentError, "#{label(pr)} shares no history with origin/#{base}" unless base_sha

      { "headSha" => head, "baseSha" => base_sha, "baseRef" => "origin/#{base}" }
    end

    # nil when gh finds no PR; any other failure is the pane's error.
    def gh_view(selector, repo)
      result = @runner.call(["gh", "pr", "view", selector, "--repo", repo, "--json", GH_FIELDS])
      unless result.success?
        return nil if result.err.to_s.match?(/no (open )?pull requests? found/i)

        raise ArgumentError, "gh pr view #{selector} failed: #{(result.err.to_s.strip.empty? ? result.out : result.err).to_s.strip[0, 200]}"
      end
      node = JSON.parse(result.out)
      { "repo" => repo, "number" => node["number"], "url" => node["url"], "title" => node["title"],
        "head" => node["headRefName"], "base" => node["baseRefName"], "state" => node["state"] }
    rescue JSON::ParserError
      raise ArgumentError, "gh pr view #{selector} answered no JSON"
    end
  end
end
