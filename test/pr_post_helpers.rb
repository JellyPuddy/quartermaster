# frozen_string_literal: true

# The stub gh and the PR fixture shared by the post and submit tests.
require_relative "test_helper"

# A stand-in for `gh api graphql`: answers the PR query and the review
# mutations from what the test sets, records each call's operation,
# variables and header, and passes git through to the real thing.
class GraphqlStub < GitPassThroughRunner
  attr_accessor :pending, :thread, :comment_error, :reply, :own, :submit_error, :assignees, :assign_error
  attr_reader :graphql

  def initialize(origin)
    super()
    @origin = origin
    @graphql = []
    @pending = nil
    @assignees = []
    @thread = ->(_vars) { { "id" => "T#{@graphql.size}" } }
    @reply = ->(_vars) { { "id" => "RC#{@graphql.size}" } }
  end

  def call(argv, chdir: nil)
    return super unless argv.first(3) == %w[gh api graphql]

    @calls << { argv: argv, chdir: chdir }
    vars = {}
    header = nil
    argv.drop(3).each_slice(2) do |flag, value|
      next header = value if flag == "-H"

      key, val = value.split("=", 2)
      vars[key] = flag == "-F" ? Integer(val) : val
    end
    query = vars.delete("query")
    name = query[/\b((?:add|submit)PullRequest\w+|(?:add|remove)Assignees\w+)\(/, 1] || "query"
    @graphql << { name: name, vars: vars, header: header }
    out, ok = answer(name, vars)
    Quartermaster::CommandRunner::Result.new(out: JSON.generate(out), err: ok ? "" : "gh: GraphQL error", success: ok)
  end

  private

  def answer(name, vars)
    case name
    when "query"
      reviews = @pending ? [{ "id" => @pending, "viewerDidAuthor" => true, "comments" => { "totalCount" => 2 } }] : []
      head = `git --git-dir #{@origin} rev-parse refs/pull/7/head`.strip
      author = @own ? { "login" => "me", "id" => "U_me" } : { "login" => "ann", "id" => "U_ann" }
      [{ "data" => { "viewer" => { "login" => "me", "id" => "U_me" },
                     "repository" => { "pullRequest" => { "id" => "PR_1", "baseRefName" => "main", "headRefOid" => head,
                                                          "state" => "OPEN", "viewerDidAuthor" => @own ? true : false,
                                                          "author" => author, "assignees" => { "nodes" => @assignees },
                                                          "reviews" => { "nodes" => reviews } } } } }, true]
    when "addAssigneesToAssignable", "removeAssigneesFromAssignable"
      return [{ "errors" => [{ "message" => @assign_error }] }, false] if @assign_error

      [{ "data" => { name => { "clientMutationId" => nil } } }, true]
    when "addPullRequestReview"
      [{ "data" => { name => { "pullRequestReview" => { "id" => "PRR_new" } } } }, true]
    when "addPullRequestReviewThread"
      [{ "data" => { name => { "thread" => @thread.call(vars) } } }, true]
    when "addPullRequestReviewThreadReply"
      [{ "data" => { name => { "comment" => @reply.call(vars) } } }, true]
    when "addPullRequestReviewComment"
      return [{ "errors" => [{ "message" => @comment_error }] }, false] if @comment_error

      [{ "data" => { name => { "comment" => { "id" => "C1" } } } }, true]
    when "submitPullRequestReview"
      return [{ "errors" => [{ "message" => @submit_error }] }, false] if @submit_error

      [{ "data" => { name => { "pullRequestReview" => { "id" => vars["review"] } } } }, true]
    end
  end
end

# A PR on acme/widgets#7 with a work item on its branch, its drafts and
# PendingReview over the stub gh: what the post and submit tests share.
module PrPostHelpers
  LINES = ANCHOR_LINES

  # main: a.txt of 20 lines. The PR's c1 makes line 5 "line five". Yields
  # the checkout, the PR's worktree, c1, main's sha and a stub gh.
  def with_pr
    with_pr_repo do |repo|
      commit(repo, "a.txt", LINES)
      push(repo, "main")
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "a.txt", LINES.sub("line 5\n", "line five\n"), message: "c1")
      push(wt, "feature:refs/pull/7/head")
      @wt = wt
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      yield repo, sha_of(wt, "HEAD"), sha_of(repo, "main"), GraphqlStub.new(Quartermaster.git(repo, "remote", "get-url", "origin"))
    end
  end

  # A new PR head: a.txt as given, pushed (forced) to the PR.
  def push_head(content, message: "next")
    commit(@wt, "a.txt", content, message: message)
    system("git", "-C", @wt, "push", "-q", "-f", "origin", "feature:refs/pull/7/head", exception: true)
    sha_of(@wt, "HEAD")
  end

  def drafts = Quartermaster::Drafts.new("feat")

  def draft(base, commit, **fields)
    drafts.put_diff_comment({ "kind" => "github-comment", "repo" => "acme/widgets", "number" => 7, "base" => base,
                              "commit" => commit, "path" => "a.txt", "side" => "new", "line" => 5,
                              "code" => "line five", "comment" => "why five?" }.merge(fields.transform_keys(&:to_s)))
  end

  def review(repo, gh) = Quartermaster::PendingReview.new(repo, repo: "acme/widgets", number: 7, runner: gh)

  def post(repo, gh) = review(repo, gh).post(drafts.entries, drafts)

  def routes(repo, gh) = review(repo, gh).send(:plan).routes(drafts.entries).values

  def act(gui, cmd, args) = gui.actions.dispatch("cmd" => cmd, "slug" => "feat", "args" => args)
end
