# frozen_string_literal: true

module Quartermaster
  # A local automation's run as a PR review: the item's `url` names the PR,
  # whose Review item gets its own chat through PrReviewStart — the Review
  # button's argv and kickoff, plus qm's session id, the yml's flags and the
  # automation's prompt as extra instructions. While that chat runs the run
  # waits instead of starting.
  class PrReviewFlow
    GH_FIELDS = "number,title,url,headRefName,baseRefName,author"
    PR_URL = %r{\Ahttps://github\.com/([^/\s]+/[^/\s]+)/pull/\d+}

    def initialize(tmux:, runner:, project_map: nil, pr_items: PrItems.new, pr_inbox: PrInbox.new)
      @runner = runner
      @pr_items = pr_items
      @pr_inbox = pr_inbox
      @service = PrReviewStart.new(tmux: tmux, pr_items: pr_items, project_map: project_map)
    end

    def name = "pr-review"

    def needs = %w[url]

    def start(automation, item, prompt, run_id:, session_id:)
      pr = pr_for(item["url"].to_s.strip)
      return { waiting: "Review chat for #{@pr_items.pr_label(pr)} is open" } if @service.live?(pr)

      reply = @service.start(pr, extra_argv: AutomationFlows.flags(automation.record, session_id), kickoff_suffix: prompt)
      { item_slug: reply["slug"], tmux: reply["slug"] }
    end

    private

    # The PR as the inbox caches it, else one `gh pr view` mapped to that shape.
    def pr_for(url)
      @pr_inbox.cached_prs.find { |pr| pr["url"] == url } || fetch(url)
    end

    def fetch(url)
      repo = PR_URL.match(url)&.[](1) or raise ArgumentError, "not a pull request URL: #{url.inspect}"
      result = @runner.call(["gh", "pr", "view", url, "--json", GH_FIELDS])
      raise ArgumentError, "gh pr view #{url} failed: #{(result.err.strip.empty? ? result.out : result.err).strip[0, 200]}" unless result.success?

      data = JSON.parse(result.out)
      { "url" => data["url"] || url, "repo" => repo, "number" => data["number"], "title" => data["title"],
        "author" => data.dig("author", "login"), "head" => data["headRefName"], "base" => data["baseRefName"] }
    rescue JSON::ParserError
      raise ArgumentError, "gh pr view #{url} answered no JSON"
    end
  end
end
