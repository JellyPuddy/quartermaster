# frozen_string_literal: true

module Quartermaster
  # Local bookkeeping that a PR may only merge once an earlier PR or commit
  # of the same repo is deployed. Nothing here is ever written to GitHub: the
  # store is one JSON file, keyed by the dependent PR's URL, and `gh` is only
  # asked read-only questions to resolve what the CLI was given.
  #
  # Each prerequisite: { "kind" => "pr"|"commit", "ref" => PR URL or full
  # sha, "repo" => "owner/repo", "addedAt", "session" }, plus an optional
  # "note" (e.g. a backfill to run between deploy and merge); an entry
  # without one, older entries included, has no note.
  class PrPrerequisites
    FILE = File.join(ROOT, "pr-prerequisites.json")
    LOCK_FILE = File.join(ROOT, "pr-prerequisites.lock")
    VERSION = 1
    KINDS = %w[pr commit].freeze

    PR_URL = %r{\Ahttps?://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)/?\z}i
    REPO_PR = %r{\A([\w.-]+/[\w.-]+)#(\d+)\z}
    LOCAL_PR = /\A#?(\d+)\z/
    SHA = /\A[0-9a-f]{7,40}\z/i
    FULL_SHA = /\A[0-9a-f]{40}\z/
    ORIGIN = %r{github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?\z}

    # The GUI's threads and a CLI process may write at once: the mutex
    # covers threads, the flock covers processes.
    MUTEX = Mutex.new

    # gh: (args, chdir) -> stdout, raising ArgumentError on failure. Tests
    # pass a stub; nothing in here may change state on GitHub.
    def initialize(gh: nil, now: -> { Time.now })
      @gh = gh || method(:gh_via_cli)
      @now = now
    end

    def self.pr_url(repo, number) = "https://github.com/#{repo}/pull/#{number}"

    # Every PR URL with its prerequisites, in insertion order.
    def all
      read["prs"]
    end

    def for_pr(pr_url)
      all.fetch(pr_url, [])
    end

    # Returns the stored entry, or nil when that prerequisite was already there.
    def add(pr_url, kind:, ref:, session: nil, note: nil)
      raise ArgumentError, "unknown prerequisite kind '#{kind}'" unless KINDS.include?(kind)

      repo = repo_of_pr_url(pr_url)
      ref_repo = kind == "pr" ? repo_of_pr_url(ref) : repo
      raise ArgumentError, "a commit prerequisite needs the full 40-char sha, not '#{ref}'" if kind == "commit" && !ref.match?(FULL_SHA)
      unless ref_repo.casecmp?(repo)
        raise ArgumentError, "#{ref} is in #{ref_repo}, not #{repo}: a prerequisite must be in the same repo as its PR"
      end
      raise ArgumentError, "a PR can't require itself" if ref.casecmp?(pr_url)

      update do |prs|
        list = prs[pr_url] ||= []
        next nil if list.any? { |entry| entry["ref"] == ref }

        entry = { "kind" => kind, "ref" => ref, "repo" => repo, "addedAt" => @now.call.utc.iso8601, "session" => session }
        entry["note"] = note.strip unless note.to_s.strip.empty?
        list << entry
        entry
      end
    end

    # Sets, replaces or (blank) clears an existing prerequisite's note.
    # Returns the updated entry, or nil when there is no such prerequisite.
    def set_note(pr_url, ref, note)
      update do |prs|
        entry = prs.fetch(pr_url, []).find { |candidate| candidate["ref"] == ref } or next nil
        if note.to_s.strip.empty?
          entry.delete("note")
        else
          entry["note"] = note.strip
        end
        entry
      end
    end

    # True when it was there.
    def remove(pr_url, ref)
      update do |prs|
        list = prs[pr_url] or next false
        removed = list.reject! { |entry| entry["ref"] == ref } ? true : false
        prs.delete(pr_url) if list.empty?
        removed
      end
    end

    # Drop the entries of dependent PRs GitHub confirmed merged or closed,
    # the store's only automatic removal (PrDeployment's refresh calls it).
    # Returns the pruned URLs.
    def prune(closed_urls)
      return [] if closed_urls.empty? || all.empty?

      update do |prs|
        gone = prs.keys & closed_urls
        gone.each { |url| prs.delete(url) }
        gone
      end
    end

    # --- What the CLI was given -> canonical refs (read-only gh/git) ---

    # A PR URL, owner/repo#n, #n or n (repo from cwd's origin), or nil: the
    # PR of cwd's current branch. Always GitHub's own spelling of the URL.
    def resolve_pr(spec, cwd:)
      return viewed_pr_url([], cwd) if spec.nil? || spec.empty?

      url = parse_pr(spec, cwd: cwd) or raise ArgumentError, "'#{spec}' is not a PR (URL, owner/repo#n or #n)"
      viewed_pr_url([url], nil)
    end

    # { "kind", "ref" } for a prerequisite spec: the PR forms, or a commit
    # sha, short or full, resolved to the full sha so the store never holds
    # an ambiguous one. A bare number is a PR, never a sha.
    def resolve_prerequisite(spec, repo:, cwd:)
      raise ArgumentError, "no prerequisite given" if spec.nil? || spec.empty?

      if (url = parse_pr(spec, cwd: cwd, repo: repo))
        { "kind" => "pr", "ref" => viewed_pr_url([url], nil) }
      elsif spec.match?(SHA)
        { "kind" => "commit", "ref" => full_sha(repo, spec) }
      else
        raise ArgumentError, "'#{spec}' is neither a PR (URL, owner/repo#n, #n) nor a commit sha"
      end
    end

    # The stored ref a removal spec names, without asking GitHub: a PR form,
    # or a sha prefix matching exactly one stored commit.
    def stored_ref(pr_url, spec, cwd:)
      entries = for_pr(pr_url)
      if (url = parse_pr(spec, cwd: cwd, repo: repo_of_pr_url(pr_url)))
        stored = entries.find { |entry| entry["ref"].casecmp?(url) }
        return stored["ref"] if stored
      elsif spec.match?(SHA)
        matches = entries.select { |entry| entry["kind"] == "commit" && entry["ref"].start_with?(spec.downcase) }
        raise ArgumentError, "'#{spec}' matches #{matches.size} commit prerequisites of #{pr_url}" if matches.size > 1
        return matches.first["ref"] if matches.one?
      end
      raise ArgumentError, "#{pr_url} has no prerequisite '#{spec}'"
    end

    def repo_of_pr_url(url)
      match = PR_URL.match(url.to_s) or raise ArgumentError, "'#{url}' is not a GitHub PR URL"
      match[1]
    end

    private

    # cwd-relative #n and n take their repo from `repo:` (the dependent PR's,
    # for a prerequisite) or else from cwd's origin remote.
    def parse_pr(spec, cwd:, repo: nil)
      if (match = PR_URL.match(spec))
        self.class.pr_url(match[1], match[2])
      elsif (match = REPO_PR.match(spec))
        self.class.pr_url(match[1], match[2])
      elsif (match = LOCAL_PR.match(spec))
        self.class.pr_url(repo || origin_repo(cwd), match[1])
      end
    end

    def origin_repo(cwd)
      url = Quartermaster.git(cwd, "remote", "get-url", "origin")
      match = url && ORIGIN.match(url) or raise ArgumentError, "no GitHub origin remote in #{cwd} to resolve a bare PR number against"
      match[1]
    end

    # `gh pr view` of a URL, or of cwd's branch when target is empty: proves
    # the PR exists and gives GitHub's casing of owner/repo, which the PR
    # inbox's and the deploy check's URLs match exactly.
    def viewed_pr_url(target, cwd)
      url = JSON.parse(@gh.call(["pr", "view", *target, "--json", "url"], cwd))["url"].to_s
      raise ArgumentError, "gh pr view #{target.first || "(current branch)"} gave no PR URL" unless url.match?(PR_URL)

      url
    rescue JSON::ParserError
      raise ArgumentError, "gh pr view #{target.first || "(current branch)"} returned no JSON"
    end

    def full_sha(repo, sha)
      full = @gh.call(["api", "repos/#{repo}/commits/#{sha}", "--jq", ".sha"], nil).strip
      raise ArgumentError, "#{sha} did not resolve to a commit in #{repo}" unless full.match?(FULL_SHA)

      full
    end

    def gh_via_cli(args, chdir)
      out, err, status = Open3.capture3("gh", *args, **(chdir ? { chdir: chdir } : {}))
      raise ArgumentError, "gh #{args.first(2).join(" ")} failed: #{(err.strip.empty? ? out : err).strip.lines.first.to_s.strip[0, 200]}" unless status.success?

      out
    rescue SystemCallError => e
      raise ArgumentError, "gh failed: #{e.message}"
    end

    def read
      data = JSON.parse(File.read(FILE))
      data["prs"].is_a?(Hash) ? data : { "v" => VERSION, "prs" => {} }
    rescue StandardError
      { "v" => VERSION, "prs" => {} }
    end

    # Read-modify-write under both locks, then write-temp-and-rename so a
    # reader never sees half a file.
    def update
      Quartermaster.ensure_setup
      MUTEX.synchronize do
        File.open(LOCK_FILE, File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          data = read
          result = yield data["prs"]
          temp = "#{FILE}.#{Process.pid}.#{Thread.current.object_id}.tmp"
          File.write(temp, JSON.pretty_generate(data.merge("v" => VERSION)))
          File.rename(temp, FILE)
          result
        end
      end
    end
  end
end
