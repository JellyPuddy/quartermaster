# frozen_string_literal: true

module Quartermaster
  # The user's pending review on one PR, filled from their GitHub drafts (PR
  # review plan D4, D9, D13) and submitted with a verdict when he clicks
  # Submit in the GUI's verdict form (submit). GitHub keeps one pending
  # review per user per PR (F3), so one made on github.com is added to
  # rather than replaced, and is the one submitted.
  #
  # Each draft goes where ReviewPlan routes it: a thread on the head, a
  # comment on its commit by diff position (the deprecation-flagged route,
  # sent with POSITION_FEATURE; F4), or — when that route errors — a file
  # comment on the head quoting its line. Outdated drafts are skipped. GitHub
  # answers an unanchorable thread with thread: null and no error (F1), so
  # every result is checked: those drafts stay, marked failed. Posted ones
  # leave the store; one edited while posting stays. Thread-reply drafts
  # (D12, F5) go into the same pending review as replies to their threads
  # (ReviewThreads#reply); they need no route.
  #
  # All GitHub access is `gh api graphql` through the runner (stubbed in
  # tests); the PR's head is fetched with PrRevisions so local git routes
  # against what GitHub has. Other kinds (a review summary) are no GitHub
  # comment: preview and post leave them out.
  class PendingReview
    POSTED_KINDS = %w[github-comment thread-reply].freeze
    POSITION_FEATURE = "GraphQL-Features: pull_request_review_comment_position"

    PR_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        viewer { id login }
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            id baseRefName headRefOid state viewerDidAuthor
            author { login ... on User { id } } assignees(first: 50) { nodes { id login } }
            reviews(states: PENDING, first: 20) { nodes { id viewerDidAuthor comments { totalCount } } }
          }
        }
      }
    GRAPHQL

    ADD_REVIEW = <<~GRAPHQL
      mutation($pr: ID!, $commit: GitObjectID!) {
        addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) { pullRequestReview { id } }
      }
    GRAPHQL

    ADD_THREAD = <<~GRAPHQL
      mutation($review: ID!, $path: String!, $body: String!, $subject: PullRequestReviewThreadSubjectType,
               $line: Int, $side: DiffSide, $startLine: Int, $startSide: DiffSide) {
        addPullRequestReviewThread(input: { pullRequestReviewId: $review, path: $path, body: $body,
                                            subjectType: $subject, line: $line, side: $side,
                                            startLine: $startLine, startSide: $startSide }) { thread { id } }
      }
    GRAPHQL

    ADD_COMMENT = <<~GRAPHQL
      mutation($review: ID!, $commit: GitObjectID!, $path: String!, $position: Int!, $body: String!) {
        addPullRequestReviewComment(input: { pullRequestReviewId: $review, commitOID: $commit, path: $path,
                                             position: $position, body: $body }) { comment { id } }
      }
    GRAPHQL

    SUBMIT_REVIEW = <<~GRAPHQL
      mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
        submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) { pullRequestReview { id } }
      }
    GRAPHQL

    ADD_ASSIGNEE = <<~GRAPHQL
      mutation($assignable: ID!, $who: ID!) {
        addAssigneesToAssignable(input: { assignableId: $assignable, assigneeIds: [$who] }) { clientMutationId }
      }
    GRAPHQL

    REMOVE_ASSIGNEE = <<~GRAPHQL
      mutation($assignable: ID!, $who: ID!) {
        removeAssigneesFromAssignable(input: { assignableId: $assignable, assigneeIds: [$who] }) { clientMutationId }
      }
    GRAPHQL

    EVENTS = %w[APPROVE COMMENT REQUEST_CHANGES].freeze
    # Each event as a verdict is spelled where qm stores one (a review summary).
    VERDICTS = EVENTS.map { |event| event.downcase.tr("_", "-") }.freeze

    attr_reader :repo, :number

    # path: a checkout of the PR's repo (the project's root) to fetch into.
    def initialize(path, repo:, number:, runner: CommandRunner.new, revisions: nil)
      raise ArgumentError, "'#{repo}' is not a GitHub repo" unless repo.to_s.match?(Drafts::REPO)

      @path = path
      @repo = repo
      @number = Integer(number.to_s, exception: false)
      raise ArgumentError, "'#{number}' is not a PR number" unless @number&.positive?

      @runner = runner
      @revisions = revisions || PrRevisions.new(runner: runner)
      @threads = ReviewThreads.new(runner: runner)
    end

    def label = "#{@repo.split("/").last}##{@number}"

    # What the confirmation says before anything is posted: how many go to
    # the head, to their commit (falling back to a file comment if GitHub
    # refuses that route), are outdated, how many replies go to their
    # threads, whether a pending review of the user's is already there, and
    # whether the PR is the user's own (only a comment can be submitted).
    def preview(entries)
      entries = postable(entries)
      replies, comments = entries.partition { |entry| reply?(entry) }
      routes = comments.empty? ? {} : plan.routes(comments)
      counts = routes.values.map { |r| r["route"] }.tally
      { "pr" => label, "url" => PrPrerequisites.pr_url(@repo, @number), "count" => entries.size,
        "head" => counts.fetch("head", 0), "commit" => counts.fetch("commit", 0),
        "outdated" => counts.fetch("outdated", 0), "replies" => replies.size,
        "moved" => routes.values.count { |r| r["moved"] && r["route"] != "outdated" },
        "pending" => existing_review&.dig("comments", "totalCount"), "viewerIsAuthor" => pr["viewerDidAuthor"] == true }
    end

    # Posts the drafts into the pending review (created when the user has none
    # on the PR) and updates the store. Returns what happened, for the
    # job's toast.
    def post(entries, drafts)
      postable, replies, routes, outdated = sort(entries)
      result = { "posted" => 0, "failed" => [], "fallbacks" => 0, "outdated" => outdated }
      return result if postable.empty? && replies.empty?

      review = pending_review_id
      posted = {}
      (postable + replies).each do |entry|
        outcome = reply?(entry) ? post_reply(review, entry) : post_one(review, entry, routes[entry["id"]])
        if outcome[:ok]
          posted[entry["id"]] = entry["rev"]
          result["fallbacks"] += 1 if outcome[:fallback]
        else
          drafts.mark_failed(entry["id"], entry["rev"], outcome[:error])
          where = reply?(entry) ? "reply on #{entry["path"] || "a thread"}" : "#{entry["path"]}:#{entry["line"]}"
          result["failed"] << "#{where}: #{outcome[:error]}"
        end
      end
      drafts.remove(posted) unless posted.empty?
      ReviewThreads.forget(@repo, @number)
      result.merge("posted" => posted.size)
    end

    # Posts the drafts as #post does, then submits the pending review with
    # event (APPROVE, COMMENT or REQUEST_CHANGES; approve/request-changes
    # spelt as verdicts too) and body. Refused up front: an unknown event,
    # an approval or change request on the viewer's own PR, a change request
    # without a body, a comment with neither a body nor any line comment. A
    # draft that fails aborts before the submit: "submitted" stays nil.
    # With nothing to post and no pending review, one is made on the head and
    # submitted, so every submit goes the same way. Once submitted, the PR
    # goes back to its author (hand_back_to_author); "reassignError" says
    # why it couldn't.
    def submit(entries, drafts, event:, body:)
      event = self.class.event(event)
      self.class.check_body(event, body)
      if pr["viewerDidAuthor"] && event != "COMMENT"
        raise ArgumentError, "#{label} is your own pull request — only a comment can be submitted on it"
      end

      postable, replies, = sort(entries)
      pending = existing_review&.dig("comments", "totalCount").to_i
      if event == "COMMENT" && body.to_s.strip.empty? && postable.empty? && replies.empty? && pending.zero?
        raise ArgumentError, "a comment review needs a summary when it carries no comments"
      end

      result = post(entries, drafts).merge("submitted" => nil, "comments" => nil)
      return result unless result["failed"].empty?

      data = graphql(SUBMIT_REVIEW, strings: { "review" => pending_review_id, "event" => event, "body" => body.to_s })
      data.dig("submitPullRequestReview", "pullRequestReview", "id") or raise ArgumentError, "GitHub submitted no review on #{label}"
      ReviewThreads.forget(@repo, @number)
      result.merge("submitted" => event, "comments" => result["posted"] + pending, "reassignError" => hand_back_to_author)
    end

    # GitHub's event for a verdict, either spelling; an ArgumentError for
    # anything else.
    def self.event(verdict)
      event = verdict.to_s.strip.upcase.tr("-", "_")
      return event if EVENTS.include?(event)

      raise not_a_verdict(verdict)
    end

    # The one refusal for a verdict qm doesn't know, wherever it came in.
    def self.not_a_verdict(verdict)
      ArgumentError.new("'#{verdict}' is not a verdict: #{VERDICTS[0..-2].join(", ")} or #{VERDICTS.last}")
    end

    # The rule the server can check without GitHub: a change request says why.
    def self.check_body(event, body)
      return unless event == "REQUEST_CHANGES" && body.to_s.strip.empty?

      raise ArgumentError, "requesting changes needs a summary saying what to change"
    end

    # The routes as the diff pane shows them, re-anchoring stored drafts on
    # the way: a whole-PR draft whose line moved with a push takes its new
    # numbers and the new head, a commit draft follows its rebased commit.
    # Nothing the user wrote changes, so revs stay.
    def self.reanchor(plan, entries, drafts)
      routes = plan.routes(entries)
      entries.each do |entry|
        fields = moved_fields(plan, entry, routes[entry["id"]])
        drafts.relocate(entry["id"], fields, rev: entry["rev"]) if fields
      end
      routes
    end

    def self.moved_fields(plan, entry, route)
      if route["route"] == "head" && !plan.commit_anchored?(entry) && !plan.pinned?(entry) &&
         (route["moved"] || entry["commit"] != plan.head_sha)
        return route.slice("line", "side", "start_line", "start_side").merge(
          "commit" => plan.head_sha, "base" => plan.base_sha, "start_line" => route["start_line"],
          "start_side" => route["start_line"] && route["start_side"]
        )
      end
      { "commit" => route["commit"] } if route["route"] == "commit" && route["moved"]
    end

    private

    def reply?(entry) = entry["kind"] == "thread-reply"

    def postable(entries) = entries.select { |entry| POSTED_KINDS.include?(entry["kind"]) }

    # [comments to post, replies, each comment's route, how many are outdated]
    def sort(entries)
      replies, comments = postable(entries).partition { |entry| reply?(entry) }
      routes = comments.empty? ? {} : plan.routes(comments)
      posted = comments.reject { |entry| routes[entry["id"]]["route"] == "outdated" }
      [posted, replies, routes, comments.size - posted.size]
    end

    def existing_review = pr["reviews"]["nodes"].find { |r| r["viewerDidAuthor"] }

    # The author is added to the assignees and the viewer, if assigned,
    # removed; others stay. The viewer's own PR is left alone. nil, or
    # GitHub's reason it couldn't (the viewer stays when the add fails).
    def hand_back_to_author
      return if pr["viewerDidAuthor"]

      author = pr.dig("author", "id") or return "#{pr.dig("author", "login") || "the author"} can't be assigned"
      graphql(ADD_ASSIGNEE, strings: { "assignable" => pr["id"], "who" => author })
      viewer = pr.dig("viewer", "id")
      if viewer && Array(pr.dig("assignees", "nodes")).any? { |a| a["id"] == viewer }
        graphql(REMOVE_ASSIGNEE, strings: { "assignable" => pr["id"], "who" => viewer })
      end
      nil
    rescue ArgumentError => e
      e.message.delete_prefix("GitHub: ")
    end

    def plan
      @plan ||= begin
        revs = @revisions.fetch(@path, { "repo" => @repo, "number" => @number, "base" => pr["baseRefName"] })
        if revs["headSha"] != pr["headRefOid"]
          raise ArgumentError, "#{label}'s head moved while it was fetched — try again"
        end

        ReviewPlan.new(@path, base_ref: revs["baseRef"], head: revs["headSha"])
      end
    end

    def pr
      @pr ||= begin
        owner, name = @repo.split("/")
        data = graphql(PR_QUERY, strings: { "owner" => owner, "name" => name }, ints: { "number" => @number })
        node = data.dig("repository", "pullRequest") or raise ArgumentError, "#{label} wasn't found on GitHub"
        raise ArgumentError, "#{label} is #{node["state"].downcase} — there is no review to add to" unless node["state"] == "OPEN"

        node.merge("viewer" => data["viewer"])
      end
    end

    # The user's pending review (one from github.com included), else a new one
    # on the head — no event, so it stays pending (F4). Made once: a submit
    # after a post takes the review the post made.
    def pending_review_id
      @pending_review_id ||= existing_review&.dig("id") || begin
        data = graphql(ADD_REVIEW, strings: { "pr" => pr["id"], "commit" => pr["headRefOid"] })
        data.dig("addPullRequestReview", "pullRequestReview", "id") or
          raise ArgumentError, "GitHub made no pending review on #{label}"
      end
    end

    # A reply joins its thread inside the pending review (F5); a reply
    # GitHub answers with no comment is a failure, not a post.
    def post_reply(review, entry)
      @threads.reply(@repo, @number, review_id: review, thread_id: entry["thread"], body: entry["comment"])
      { ok: true }
    rescue ArgumentError => e
      { ok: false, error: e.message }
    end

    def post_one(review, entry, route)
      return post_thread(review, entry, route) if route["route"] == "head"

      begin
        comment = graphql(ADD_COMMENT, strings: { "review" => review, "commit" => route["commit"], "path" => entry["path"],
                                                  "body" => commit_body(entry) },
                                       ints: { "position" => route["position"] }, header: POSITION_FEATURE)
        return { ok: true } if comment.dig("addPullRequestReviewComment", "comment", "id")

        error = "GitHub took no comment at #{route["commit"][0, 7]}"
      rescue ArgumentError => e
        error = e.message
      end
      fallback(review, entry, route, error)
    end

    # The commit route errored (the flagged API gone, or the line refused):
    # a file comment on the head that says which line of which commit.
    def fallback(review, entry, route, error)
      return { ok: false, error: "#{error}; #{entry["path"]} isn't in the head's diff for a file comment" } unless plan.head.file(entry["path"])

      quoted = entry["code"].to_s.split("\n", -1).map { |line| "> #{line}" }.join("\n")
      body = "on #{route["commit"][0, 7]}, #{entry["path"]}:#{DiffComments.lines_label(entry).delete_prefix(":")}:\n" \
             "#{quoted}\n\n#{entry["comment"]}"
      outcome = post_thread(review, entry.merge("comment" => body), { "subject" => "file" })
      outcome[:ok] ? outcome.merge(fallback: true) : outcome
    end

    def post_thread(review, entry, route)
      strings = { "review" => review, "path" => entry["path"], "body" => entry["comment"].to_s }
      ints = {}
      if route["subject"] == "file"
        strings["subject"] = "FILE"
      else
        strings.merge!("subject" => "LINE", "side" => github_side(route["side"]))
        ints["line"] = route["line"]
        if route["start_line"] && route["start_line"] != route["line"]
          ints["startLine"] = route["start_line"]
          strings["startSide"] = github_side(route["start_side"] || route["side"])
        end
      end
      data = graphql(ADD_THREAD, strings: strings, ints: ints)
      return { ok: true } if data.dig("addPullRequestReviewThread", "thread", "id")

      { ok: false, error: "GitHub didn't take a comment on that line (no thread came back)" }
    rescue ArgumentError => e
      { ok: false, error: e.message }
    end

    # The commit route takes one position: a range says which lines in words.
    def commit_body(entry)
      return entry["comment"].to_s unless entry["start_line"] && entry["start_line"] != entry["line"]

      "Lines #{entry["start_line"]}–#{entry["line"]}:\n\n#{entry["comment"]}"
    end

    def github_side(side) = side.to_s == "old" || side.to_s == "LEFT" ? "LEFT" : "RIGHT"

    # `gh api graphql`: strings as -f (raw, never read from a file), ints as
    # -F. The data, or an ArgumentError carrying GitHub's message.
    def graphql(query, strings: {}, ints: {}, header: nil)
      argv = ["gh", "api", "graphql"]
      argv += ["-H", header] if header
      argv += ["-f", "query=#{query}"]
      strings.each { |key, value| argv += ["-f", "#{key}=#{value}"] }
      ints.each { |key, value| argv += ["-F", "#{key}=#{Integer(value)}"] }
      result = @runner.call(argv)
      body = begin
        JSON.parse(result.out.to_s)
      rescue JSON::ParserError
        {}
      end
      errors = Array(body["errors"]).map { |e| e["message"] }.compact
      unless result.success? && errors.empty? && body["data"]
        detail = errors.first || result.err.to_s.strip.then { |e| e.empty? ? result.out.to_s.strip : e }
        raise ArgumentError, "GitHub: #{detail[0, 300]}"
      end
      body["data"]
    end
  end
end
