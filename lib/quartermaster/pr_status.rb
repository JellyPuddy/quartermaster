# frozen_string_literal: true

module Quartermaster
  # PR state per work-item branch, via gh, cached on disk so viewer repaints
  # and previews don't hit the network (or hang offline) on every render.
  #
  # Two refresh modes. Synchronous (default): an expired entry blocks on gh —
  # right for the CLI, whose process would exit before a thread finished.
  # background: true (the GUI): an expired entry is served as-is and refetched
  # on a thread, so no page load ever waits on the network; #refreshing? tells
  # the caller whether the answer it just got may still improve.
  class PrStatus
    CACHE_FILE = File.join(ROOT, "pr-cache.json")
    # How long an answer holds depends on how soon it changes. Merged and
    # closed are as good as final. An open PR is the one about to merge, so
    # it's asked again as often as PrInbox refreshes. "No PR" usually gets
    # one within the hour.
    CACHE_TTL_SECONDS = 6 * 3600
    OPEN_TTL_SECONDS = 5 * 60
    NO_PR_TTL_SECONDS = 10 * 60

    # Shared across instances: one lives per request, threads outlive them.
    CACHE_MUTEX = Mutex.new
    IN_FLIGHT = {}
    IN_FLIGHT_MUTEX = Mutex.new

    def initialize(project_map: ProjectMap.new, fetcher: nil, now: Time.now, background: false)
      @project_map = project_map
      @fetcher = fetcher || method(:fetch_via_gh)
      @now = now
      @background = background
      @served_stale = false
    end

    def state_for(item, branch)
      return nil unless branch

      key = "#{item.project}##{branch}"
      entry = read_cache[key]
      return entry["state"] if entry && (@now.to_i - entry["ts"]) < ttl(entry)
      return serve_stale(item, branch, key, entry) if @background

      store(key, @fetcher.call(item, branch))
    end

    # The branch's PR as last fetched, {"number", "url"}, or nil. Reads the
    # cache only — state_for does the fetching; an entry cached before
    # numbers were kept gains them on its next refresh.
    def link_for(item, branch)
      entry = read_cache["#{item.project}##{branch}"]
      entry && entry["number"] ? entry.slice("number", "url") : nil
    end

    # True while this instance handed out an answer that a background fetch
    # may still improve — either it served a stale entry itself, or fetches
    # enqueued earlier are still running.
    def refreshing?
      @served_stale || IN_FLIGHT_MUTEX.synchronize { !IN_FLIGHT.empty? }
    end

    # Open the branch's PR in the browser. Defaults to the newest linked
    # branch — on a stack that's the tip, which is the PR you usually mean.
    # Returns the branch it opened; raises ArgumentError when it can't.
    def open_web(item, branch: nil)
      raise ArgumentError, "'#{item.slug}' has no branch linked" if item.branches.empty?

      root = @project_map.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root

      branch = item.branches.last if branch.to_s.empty?
      raise ArgumentError, "no PR found for branch #{branch}" unless system("gh", "pr", "view", branch, "--web", chdir: root)

      branch
    end

    private

    def ttl(entry)
      case entry["state"]
      when nil then NO_PR_TTL_SECONDS
      when "OPEN" then OPEN_TTL_SECONDS
      else CACHE_TTL_SECONDS
      end
    end

    def serve_stale(item, branch, key, entry)
      @served_stale = true
      if IN_FLIGHT_MUTEX.synchronize { IN_FLIGHT[key] ? false : IN_FLIGHT[key] = true }
        Thread.new do
          store(key, @fetcher.call(item, branch))
        rescue StandardError => e
          Quartermaster.log_error("pr-refresh", e)
        ensure
          IN_FLIGHT_MUTEX.synchronize { IN_FLIGHT.delete(key) }
        end
      end
      entry && entry["state"]
    end

    # A fetcher answers the state alone, or {"state", "number", "url"}.
    def store(key, fetched)
      pr = fetched.is_a?(Hash) ? fetched.slice("state", "number", "url") : { "state" => fetched }
      CACHE_MUTEX.synchronize do
        cache = read_cache
        cache[key] = pr.merge("ts" => @now.to_i)
        write_cache(cache)
      end
      pr["state"]
    end

    def fetch_via_gh(item, branch)
      root = @project_map.root_for(item.project)
      return nil unless root

      out, _err, status = Open3.capture3("gh", "pr", "view", branch, "--json", "state,number,url", chdir: root)
      status.success? ? JSON.parse(out) : nil
    rescue StandardError
      nil
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
