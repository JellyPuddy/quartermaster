# frozen_string_literal: true

module Quartermaster
  # The GUI's PRs view: every open pull request the user wrote, is asked to
  # review, or is assigned, across all repos — one `gh api graphql` call with
  # a search per role. That call takes ~10 s, so like PrStatus the answer is
  # cached on disk and refetched on a thread: a list request never waits on
  # GitHub, it says "refreshing" and the page polls.
  class PrInbox
    CACHE_FILE = File.join(ROOT, "pr-inbox.json")
    TTL_SECONDS = 5 * 60

    # user-review-requested, not review-requested: the latter also matches
    # every team the user is on, which buried the direct requests.
    ROLES = {
      "author" => "author:@me",
      "review" => "user-review-requested:@me",
      "assignee" => "assignee:@me"
    }.freeze
    FIELDS = "number title url isDraft updatedAt headRefName baseRefName reviewDecision " \
             "latestReviews(first: 20) { nodes { state } } author { login } repository { nameWithOwner } " \
             "commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { " \
             "... on CheckRun { name status conclusion startedAt " \
             "checkSuite { databaseId createdAt app { slug } workflowRun { workflow { name } } } } " \
             "... on StatusContext { context state createdAt } } } } } } }"
    # Conclusions (check runs) and states (commit statuses) GitHub counts as
    # passing in its "28 / 31", and the ones that make it a red ✗.
    CI_OK = %w[SUCCESS NEUTRAL SKIPPED].freeze
    CI_BAD = %w[FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE STALE].freeze

    REFRESH_MUTEX = Mutex.new
    @in_flight = false
    class << self
      attr_accessor :in_flight
    end

    def initialize(fetcher: nil, now: Time.now)
      @fetcher = fetcher || method(:fetch_via_gh)
      @now = now
    end

    # { "prs", "fetchedAt", "error", "refreshing" }. An expired or missing
    # cache (or force: the page's Refresh) starts a background fetch and
    # answers with what it has meanwhile.
    def list(force: false)
      cache = read_cache
      stale = force || cache["ts"].nil? || @now.to_i - cache["ts"] >= TTL_SECONDS
      refreshing = stale ? refresh_in_background : self.class.in_flight
      { "prs" => cache["prs"] || [], "fetchedAt" => cache["ts"] && Time.at(cache["ts"]).utc.iso8601,
        "error" => cache["error"], "refreshing" => refreshing }
    end

    # The cached PR at this URL: actions name a PR by URL and take every
    # other field from here, never from the page.
    def find(url)
      (read_cache["prs"] || []).find { |pr| pr["url"] == url } or
        raise ArgumentError, "no open PR #{url} in the PR list — refresh it"
    end

    # The cached list as it stands: never fetches, so cheap enough to ask on
    # every diff load.
    def cached_prs = read_cache["prs"] || []

    # Blocking fetch; the background refresh and tests call it. A failure
    # keeps the last good list and records why.
    def refresh
      write_cache("prs" => @fetcher.call, "ts" => Time.now.to_i, "error" => nil)
      Quartermaster.log_success("pr-inbox")
    rescue StandardError => e
      Quartermaster.log_error("pr-inbox", e)
      write_cache(read_cache.merge("ts" => Time.now.to_i, "error" => e.message))
    end

    # Three searches' results merged by URL, each PR carrying every role it
    # matched, newest activity first.
    def self.merge(by_role)
      merged = {}
      by_role.each do |role, nodes|
        nodes.each do |node|
          next unless node && node["url"]

          pr = merged[node["url"]] ||= {
            "url" => node["url"], "number" => node["number"], "title" => node["title"],
            "repo" => node.dig("repository", "nameWithOwner"), "author" => node.dig("author", "login"),
            "head" => node["headRefName"], "base" => node["baseRefName"], "draft" => node["isDraft"] ? true : false,
            "reviewDecision" => review_decision(node), "ci" => ci(node), "updatedAt" => node["updatedAt"], "roles" => []
          }
          pr["roles"] << role
        end
      end
      merged.values.sort_by { |pr| pr["updatedAt"].to_s }.reverse
    end

    # GitHub only sets reviewDecision where branch protection requires
    # reviews, so a PR onto a stacked branch has none however it was
    # reviewed: then each reviewer's latest review decides, changes
    # requested over approved.
    def self.review_decision(node)
      return node["reviewDecision"] if node["reviewDecision"]

      states = Array(node.dig("latestReviews", "nodes")).map { |review| review && review["state"] }
      %w[CHANGES_REQUESTED APPROVED].find { |state| states.include?(state) }
    end

    # The head commit's checks as GitHub's PR page shows them: passing /
    # total and SUCCESS, FAILURE or PENDING; nil for a PR without any. The
    # rollup keeps superseded runs, so like GitHub only each workflow's newest
    # check suite counts — a push twice in a row leaves a concurrency-cancelled
    # suite whose jobs even started later — and within it each check's latest
    # attempt, so a cancelled first attempt can't fail a green re-run.
    def self.ci(node)
      contexts = Array(node.dig("commits", "nodes", 0, "commit", "statusCheckRollup", "contexts", "nodes")).compact
      statuses, runs = contexts.partition { |c| c.key?("context") }
      suites = runs.group_by { |c| [c.dig("checkSuite", "app", "slug"), c.dig("checkSuite", "workflowRun", "workflow", "name")] }
                   .values.map { |rs| rs.group_by { |c| c["checkSuite"] }.max_by { |s, _| [s&.dig("createdAt").to_s, s&.dig("databaseId").to_i] }.last }
      latest = (suites + [statuses]).flat_map do |checks|
        checks.group_by { |c| c["name"] || c["context"] }.map { |_, attempts| attempts.max_by { |c| (c["startedAt"] || c["createdAt"]).to_s } }
      end
      return nil if latest.empty?

      results = latest.map { |c| c.key?("context") ? c["state"] : c["conclusion"] }
      state = if results.any? { |r| CI_BAD.include?(r) } then "FAILURE"
              elsif results.all? { |r| CI_OK.include?(r) } then "SUCCESS"
              else "PENDING"
              end
      { "state" => state, "ok" => results.count { |r| CI_OK.include?(r) }, "total" => latest.size }
    end

    private

    def refresh_in_background
      REFRESH_MUTEX.synchronize do
        return true if self.class.in_flight

        self.class.in_flight = true
      end
      Thread.new do
        refresh
      ensure
        REFRESH_MUTEX.synchronize { self.class.in_flight = false }
      end
      true
    end

    def fetch_via_gh
      searches = ROLES.map do |role, qualifier|
        %(#{role}: search(query: "is:open is:pr archived:false #{qualifier}", type: ISSUE, first: 50) { nodes { ...pr } })
      end
      query = "query { #{searches.join(" ")} } fragment pr on PullRequest { #{FIELDS} }"
      out, err, status = Open3.capture3("gh", "api", "graphql", "-f", "query=#{query}")
      raise "gh api graphql failed: #{(err.strip.empty? ? out : err).strip[0, 200]}" unless status.success?

      # A GraphQL error (a timeout, say) still exits 0, with the searches
      # null: that must not pass for "no open PRs".
      body = JSON.parse(out)
      raise "gh api graphql: #{Array(body["errors"]).map { |e| e["message"] }.join("; ")[0, 200]}" if body["errors"]

      data = body["data"] || {}
      self.class.merge(ROLES.keys.to_h { |role| [role, data.dig(role, "nodes") || []] })
    end

    def read_cache
      JSON.parse(File.read(CACHE_FILE))
    rescue StandardError
      {}
    end

    def write_cache(cache)
      Quartermaster.ensure_setup
      File.write(CACHE_FILE, JSON.generate(cache))
    end
  end
end
