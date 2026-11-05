# frozen_string_literal: true

module Quartermaster
  # A pull request's review threads as the diff pane's PR scope shows them,
  # and the three GitHub writes a thread takes: resolve, unresolve and a
  # reply into the user's pending review. All through `gh api graphql` on the
  # CommandRunner, so tests stub it.
  #
  # The read is cached per PR and head for TTL seconds: the scope reloads on
  # every turn's end and ↻, and threads move far slower than that. A write
  # through this class forgets its PR's entry, so the refetch after it is
  # fresh.
  #
  # Pending comments are only ever the viewer's (GitHub shows nobody else's),
  # so a comment in state PENDING is "pending (yours)" — also those of a
  # pending review started on github.com (D13).
  class ReviewThreads
    TTL = 30
    PAGE = 50
    MAX_PAGES = 10
    REPO = %r{\A[\w.-]+/[\w.-]+\z}
    NODE_ID = /\A[\w-]{1,200}\z/
    CACHE = {}
    CACHE_MUTEX = Mutex.new

    QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        viewer { login }
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            id
            reviews(states: PENDING, first: 5) { nodes { id viewerDidAuthor } }
            reviewThreads(first: #{PAGE}, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id path line originalLine startLine originalStartLine diffSide subjectType
                isResolved isOutdated viewerCanResolve viewerCanUnresolve viewerCanReply
                resolvedBy { login }
                comments(first: 100) {
                  nodes { id body createdAt url state diffHunk author { login } }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    RESOLVE = {
      true => "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }",
      false => "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }",
    }.freeze

    REPLY = <<~GRAPHQL
      mutation($review: ID!, $thread: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: {pullRequestReviewId: $review, pullRequestReviewThreadId: $thread, body: $body}) {
          comment { id url }
        }
      }
    GRAPHQL

    def self.forget(repo, number)
      CACHE_MUTEX.synchronize { CACHE.delete_if { |key, _| key.start_with?("#{repo.downcase}##{number}@") } }
    end

    def initialize(runner: CommandRunner.new, clock: -> { Time.now })
      @runner = runner
      @clock = clock
    end

    # { "threads" => [thread…], "viewer" => login, "prId", "pendingReview" =>
    # { "id" } or nil }. `head` only keys the cache: a push moves it, so the
    # pane never shows the threads of a head it no longer diffs. Each thread:
    # id, path, side ("old" | "new", GitHub's LEFT | RIGHT), line and
    # startLine (nil once outdated: GitHub can't place it on the head's
    # diff), originalLine, file (a comment on the whole file), resolved,
    # outdated, resolvedBy, canResolve/canUnresolve/canReply, quote (the
    # commented line as GitHub quotes it: the last line of the first
    # comment's diff hunk, sign included) and comments (id, author, body,
    # createdAt, url, pending).
    def fetch(repo, number, head: nil, fresh: false)
      repo, number = checked(repo, number)
      key = "#{repo.downcase}##{number}@#{head}"
      now = @clock.call.to_f
      unless fresh
        hit = CACHE_MUTEX.synchronize { CACHE[key] }
        return hit[:value] if hit && now - hit[:at] < TTL
      end

      value = read(repo, number)
      CACHE_MUTEX.synchronize do
        CACHE.delete_if { |_, entry| now - entry[:at] >= TTL }
        CACHE[key] = { at: now, value: value }
      end
      value
    end

    # Resolves (or unresolves) a thread at once — no pending review involved
    # (F6). Returns the thread's new isResolved.
    def resolve(repo, number, thread_id, resolved: true)
      repo, number = checked(repo, number)
      raise ArgumentError, "'#{thread_id}' is not a review thread id" unless thread_id.is_a?(String) && thread_id.match?(NODE_ID)

      data = graphql(RESOLVE.fetch(resolved ? true : false), "id" => thread_id)
      thread = data.dig(resolved ? "resolveReviewThread" : "unresolveReviewThread", "thread")
      raise ArgumentError, "GitHub did not #{resolved ? "resolve" : "unresolve"} the thread" unless thread

      thread["isResolved"]
    ensure
      self.class.forget(repo, number) if repo.is_a?(String)
    end

    # A reply into the pending review review_id (addPullRequestReviewThreadReply,
    # F5) — PendingReview#post finds or starts that review:
    # { "id", "url" } of the comment. A thread:null-style silent failure
    # (no comment back) raises rather than passing for posted.
    def reply(repo, number, review_id:, thread_id:, body:)
      raise ArgumentError, "a reply can't be blank" if body.to_s.strip.empty?

      comment = graphql(REPLY, "review" => review_id.to_s, "thread" => thread_id.to_s, "body" => body.to_s)
                .dig("addPullRequestReviewThreadReply", "comment")
      raise ArgumentError, "GitHub took no reply on thread #{thread_id}" unless comment

      comment
    ensure
      self.class.forget(repo, number) if repo.is_a?(String)
    end

    private

    def checked(repo, number)
      raise ArgumentError, "'#{repo}' is not an owner/name repo" unless repo.is_a?(String) && repo.match?(REPO)

      number = Integer(number.to_s, 10)
      raise ArgumentError, "a pull request number must be positive" unless number.positive?

      [repo, number]
    rescue TypeError
      raise ArgumentError, "'#{number}' is not a pull request number"
    end

    def read(repo, number)
      owner, name = repo.split("/", 2)
      threads = []
      cursor = nil
      data = nil
      MAX_PAGES.times do
        vars = { "owner" => owner, "name" => name, "number" => number }
        vars["cursor"] = cursor if cursor
        data = graphql(QUERY, vars)
        pr = data.dig("repository", "pullRequest") or raise ArgumentError, "#{repo}##{number} is not a pull request GitHub knows"
        page = pr["reviewThreads"] || {}
        threads.concat(Array(page["nodes"]).compact.map { |node| thread(node) })
        info = page["pageInfo"] || {}
        break unless info["hasNextPage"] && info["endCursor"]

        cursor = info["endCursor"]
      end
      pr = data.dig("repository", "pullRequest")
      pending = Array(pr.dig("reviews", "nodes")).compact.find { |review| review["viewerDidAuthor"] }
      { "threads" => threads, "viewer" => data.dig("viewer", "login"), "prId" => pr["id"],
        "pendingReview" => pending && { "id" => pending["id"] } }
    end

    def thread(node)
      comments = Array(node.dig("comments", "nodes")).compact
      hunk = comments.first && comments.first["diffHunk"].to_s.split("\n").last
      { "id" => node["id"], "path" => node["path"], "side" => node["diffSide"] == "LEFT" ? "old" : "new",
        "line" => node["line"], "startLine" => node["startLine"], "originalLine" => node["originalLine"],
        "file" => node["subjectType"] == "FILE", "resolved" => node["isResolved"] == true,
        "outdated" => node["isOutdated"] == true, "resolvedBy" => node.dig("resolvedBy", "login"),
        "canResolve" => node["viewerCanResolve"] == true, "canUnresolve" => node["viewerCanUnresolve"] == true,
        "canReply" => node["viewerCanReply"] == true, "quote" => hunk,
        "comments" => comments.map do |comment|
          { "id" => comment["id"], "author" => comment.dig("author", "login") || "ghost", "body" => comment["body"].to_s,
            "createdAt" => comment["createdAt"], "url" => comment["url"], "pending" => comment["state"] == "PENDING" }
        end }
    end

    # gh api graphql with string variables (-f) and the PR number typed (-F).
    def graphql(query, vars)
      argv = ["gh", "api", "graphql", "-f", "query=#{query}"]
      vars.each { |name, value| argv.push(value.is_a?(Integer) ? "-F" : "-f", "#{name}=#{value}") }
      result = @runner.call(argv)
      body = begin
        JSON.parse(result.out.to_s)
      rescue JSON::ParserError
        nil
      end
      errors = body.is_a?(Hash) ? Array(body["errors"]) : []
      unless result.success? && body.is_a?(Hash) && errors.empty?
        why = errors.map { |error| error["message"] }.compact.join("; ")
        why = (result.err.to_s.strip.empty? ? result.out : result.err).to_s.strip if why.empty?
        raise ArgumentError, "gh api graphql failed: #{why[0, 300]}"
      end
      body["data"] || {}
    end
  end
end
