# frozen_string_literal: true

module Quartermaster
  # Whether each PR prerequisite (PrPrerequisites) is deployed: contained in
  # its repo's latest published release. Answers come from a disk cache
  # only; GitHub is asked (read-only) on a background thread, like PrInbox,
  # so no caller ever waits on gh.
  #
  # States: "deployed" (with the release "tag"), "pending" (merged or a
  # commit, not in the latest release), "unmerged" (an open PR), "closed" (a
  # PR closed without merging), "unknown" (not fetched yet, or every lookup
  # so far failed) — never shown as deployed.
  #
  # The same refresh also asks each dependent PR's state and prunes the
  # store's entries whose PR GitHub confirms merged or closed.
  class PrDeployment
    CACHE_FILE = File.join(ROOT, "pr-deployment.json")
    VERSION = 1
    TTL_SECONDS = 5 * 60
    # gh pr view states that never change again (once the merge commit is known).
    FINAL_PR_STATES = %w[MERGED].freeze

    REFRESH_MUTEX = Mutex.new
    @in_flight = false
    class << self
      attr_accessor :in_flight
    end

    # fetcher: responds to latest_release(repo) -> tag, pull(url) ->
    # { "state", "mergeCommit" } and compare(repo, tag, sha) -> GitHub's
    # compare status, each raising on failure. Defaults to gh; tests stub it.
    def initialize(store: PrPrerequisites.new, fetcher: nil, now: -> { Time.now })
      @store = store
      @fetcher = fetcher || self
      @now = now
    end

    # Every dependent PR's prerequisites, each with "state" (and "tag" when
    # it names a release), from the cache. With refresh: (the GUI) a stale
    # or missing answer starts a background refresh; the CLI passes false,
    # since its process would exit before the thread finished.
    def states(prs = @store.all, refresh: true)
      cache = read_cache
      refresh_in_background if refresh && stale?(cache, prs)
      prs.transform_values { |entries| entries.map { |entry| entry.merge(verdict(cache, entry)) } }
    end

    def refreshing? = self.class.in_flight

    # Blocking: what the background thread runs, and tests call. Each lookup
    # fails on its own and keeps that part's last good answer.
    def refresh(prs = @store.all)
      cache = read_cache
      releases = prs.values.flatten.map { |entry| entry["repo"] }.uniq
      releases.each { |repo| fetch_release(cache, repo) }

      closed = prs.keys.select do |url|
        pull = fetch_pull(cache, url)
        pull && %w[MERGED CLOSED].include?(pull["state"])
      end
      prs.values.flatten.each { |entry| check_entry(cache, entry) }
      forget_unreferenced(cache, prs)
      write_cache(cache)
      prune(closed)
    end

    # --- The default fetcher: read-only gh ---

    def latest_release(repo)
      tag = gh("api", "repos/#{repo}/releases/latest", "--jq", ".tag_name").strip
      raise "#{repo} has no latest release" if tag.empty?

      tag
    end

    def pull(url)
      data = JSON.parse(gh("pr", "view", url, "--json", "state,mergeCommit"))
      { "state" => data["state"], "mergeCommit" => data.dig("mergeCommit", "oid") }
    end

    def compare(repo, tag, sha)
      gh("api", "repos/#{repo}/compare/#{tag}...#{sha}", "--jq", ".status").strip
    end

    private

    def verdict(cache, entry)
      sha = entry_sha(cache, entry)
      return sha if sha.is_a?(Hash)

      checked = cache["verdicts"][sha]
      return { "state" => "deployed", "tag" => checked["tag"] } if checked && checked["deployed"]
      # A pending verdict against an older tag stays true of that tag until
      # the refresh re-checks it against the new one.
      return { "state" => "pending", "tag" => checked["tag"] } if checked

      { "state" => "unknown" }
    end

    # The commit an entry waits on, or its whole verdict when it has none.
    def entry_sha(cache, entry)
      return entry["ref"] if entry["kind"] == "commit"

      pull = cache["pulls"][entry["ref"]]
      case pull && pull["state"]
      when "OPEN" then { "state" => "unmerged" }
      when "CLOSED" then { "state" => "closed" }
      when "MERGED" then pull["mergeCommit"] || { "state" => "unknown" }
      else { "state" => "unknown" }
      end
    end

    def stale?(cache, prs)
      entries = prs.values.flatten
      entries.map { |entry| entry["repo"] }.uniq.any? { |repo| expired?(cache["releases"][repo]) } ||
        prs.keys.any? { |url| pull_stale?(cache, url) } ||
        entries.any? { |entry| entry["kind"] == "pr" && pull_stale?(cache, entry["ref"]) } ||
        entries.any? { |entry| sha_stale?(cache, entry) }
    end

    def expired?(cached)
      cached.nil? || @now.call.to_i - cached["ts"].to_i >= TTL_SECONDS
    end

    def pull_stale?(cache, url)
      pull = cache["pulls"][url]
      final = pull && FINAL_PR_STATES.include?(pull["state"]) && pull["mergeCommit"]
      !final && expired?(pull)
    end

    # A deployed verdict holds for good; any other is re-checked once the
    # latest tag moves on or its TTL passes.
    def sha_stale?(cache, entry)
      sha = entry_sha(cache, entry)
      return false if sha.is_a?(Hash)

      checked = cache["verdicts"][sha]
      return false if checked && checked["deployed"]

      tag = cache.dig("releases", entry["repo"], "tag")
      tag.nil? ? false : checked.nil? || checked["tag"] != tag || expired?(checked)
    end

    def fetch_release(cache, repo)
      return unless expired?(cache["releases"][repo])

      cache["releases"][repo] = { "tag" => @fetcher.latest_release(repo), "ts" => @now.call.to_i }
    rescue StandardError => e
      Quartermaster.log_error("pr-deployment", e)
      stamp_failure(cache["releases"], repo)
    end

    # Fetched pulls this round: the dependent PRs, then each PR prerequisite.
    def fetch_pull(cache, url)
      return cache["pulls"][url] unless pull_stale?(cache, url)

      cache["pulls"][url] = @fetcher.pull(url).merge("ts" => @now.call.to_i)
    rescue StandardError => e
      Quartermaster.log_error("pr-deployment", e)
      stamp_failure(cache["pulls"], url)
      nil
    end

    # A failed lookup keeps its last good answer but counts as attempted, so
    # a lookup that keeps failing waits out the TTL like a good one.
    def stamp_failure(section, key)
      section[key] = (section[key] || {}).merge("ts" => @now.call.to_i)
    end

    def check_entry(cache, entry)
      fetch_pull(cache, entry["ref"]) if entry["kind"] == "pr"
      return unless sha_stale?(cache, entry)

      sha = entry_sha(cache, entry)
      tag = cache["releases"][entry["repo"]]["tag"]
      status = @fetcher.compare(entry["repo"], tag, sha)
      cache["verdicts"][sha] = { "tag" => tag, "deployed" => %w[behind identical].include?(status), "ts" => @now.call.to_i }
    rescue StandardError => e
      Quartermaster.log_error("pr-deployment", e)
    end

    # Keeps the cache to what the store still names.
    def forget_unreferenced(cache, prs)
      entries = prs.values.flatten
      urls = prs.keys + entries.select { |entry| entry["kind"] == "pr" }.map { |entry| entry["ref"] }
      shas = entries.map { |entry| entry_sha(cache, entry) }.grep(String)
      cache["pulls"].select! { |url, _| urls.include?(url) }
      cache["verdicts"].select! { |sha, _| shas.include?(sha) }
      cache["releases"].select! { |repo, _| entries.any? { |entry| entry["repo"] == repo } }
    end

    def prune(closed)
      @store.prune(closed) unless closed.empty?
    rescue StandardError => e
      Quartermaster.log_error("pr-deployment", e)
    end

    def refresh_in_background
      REFRESH_MUTEX.synchronize do
        return if self.class.in_flight

        self.class.in_flight = true
      end
      Thread.new do
        refresh
      rescue StandardError => e
        Quartermaster.log_error("pr-deployment", e)
      ensure
        REFRESH_MUTEX.synchronize { self.class.in_flight = false }
      end
    end

    def gh(*args)
      out, err, status = Open3.capture3("gh", *args)
      raise "gh #{args.first(2).join(" ")} failed: #{(err.strip.empty? ? out : err).strip[0, 200]}" unless status.success?

      out
    end

    def read_cache
      data = JSON.parse(File.read(CACHE_FILE))
      raise "unknown cache version" unless data["v"] == VERSION

      %w[releases pulls verdicts].each { |key| data[key] = {} unless data[key].is_a?(Hash) }
      data
    rescue StandardError
      { "v" => VERSION, "releases" => {}, "pulls" => {}, "verdicts" => {} }
    end

    def write_cache(cache)
      Quartermaster.ensure_setup
      temp = "#{CACHE_FILE}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(temp, JSON.pretty_generate(cache))
      File.rename(temp, CACHE_FILE)
    end
  end
end
