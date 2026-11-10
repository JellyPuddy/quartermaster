# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_post_test.rb`).
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

# Posting GitHub drafts as a pending review (PR review plan D4, D9-D11, D13)
# and how each draft routes when the PR moved under it.
class PrPostTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers
  include PrPostHelpers

  def test_head_drafts_go_into_a_new_pending_review_and_leave_the_store
    with_pr do |repo, c1, base, gh|
      draft(base, c1)
      draft(base, c1, line: 9, code: "line 9", subject: "file", comment: "whole file")

      result = post(repo, gh)

      assert_equal({ "posted" => 2, "failed" => [], "fallbacks" => 0, "outdated" => 0 }, result)
      assert_equal %w[query addPullRequestReview addPullRequestReviewThread addPullRequestReviewThread], gh.graphql.map { |c| c[:name] }
      assert_equal({ "pr" => "PR_1", "commit" => c1 }, gh.graphql[1][:vars])
      line, file = gh.graphql.last(2).map { |c| c[:vars] }
      assert_equal({ "review" => "PRR_new", "path" => "a.txt", "body" => "why five?", "subject" => "LINE", "side" => "RIGHT",
                     "line" => 5 }, line)
      assert_equal({ "review" => "PRR_new", "path" => "a.txt", "body" => "whole file", "subject" => "FILE" }, file)
      assert(gh.graphql.none? { |c| c[:header] }, "only the commit route needs the feature header")
      assert_empty drafts.entries
    end
  end

  def test_a_pending_review_the_user_already_has_is_added_to
    with_pr do |repo, c1, base, gh|
      gh.pending = "PRR_mine"
      draft(base, c1, start_line: 4, start_side: "new", code: "line 4\nline five")

      preview = review(repo, gh).preview(drafts.entries)
      post(repo, gh)

      assert_equal({ "pr" => "widgets#7", "url" => "https://github.com/acme/widgets/pull/7", "count" => 1, "head" => 1,
                     "commit" => 0, "outdated" => 0, "replies" => 0, "moved" => 0, "pending" => 2, "viewerIsAuthor" => false }, preview)
      refute_includes gh.graphql.map { |c| c[:name] }, "addPullRequestReview"
      thread = gh.graphql.last[:vars]
      assert_equal ["PRR_mine", 4, "RIGHT", 5], thread.values_at("review", "startLine", "startSide", "line")
    end
  end

  def test_thread_replies_post_into_the_same_pending_review_and_a_silent_one_stays
    with_pr do |repo, c1, base, gh|
      draft(base, c1)
      reply = drafts.put_thread_reply("thread" => "PRRT_1", "repo" => "acme/widgets", "number" => 7, "path" => "a.txt",
                                      "line" => 2, "comment" => "fixed")

      assert_equal [1, 1, 2], review(repo, gh).preview(drafts.entries).values_at("head", "replies", "count")
      gh.graphql.clear
      result = post(repo, gh)

      assert_equal 2, result["posted"]
      assert_equal %w[query addPullRequestReview addPullRequestReviewThread addPullRequestReviewThreadReply],
                   gh.graphql.map { |c| c[:name] }
      assert_equal({ "review" => "PRR_new", "thread" => "PRRT_1", "body" => "fixed" }, gh.graphql.last[:vars])
      assert_empty drafts.entries

      gh.reply = ->(_vars) {}
      kept = drafts.put_thread_reply(reply.slice("thread", "repo", "number", "path", "line").merge("comment" => "again"))
      result = post(repo, gh)
      assert_match(/reply on a.txt: .*no reply/, result["failed"].first)
      assert drafts.find(kept["id"])["failed"]
    end
  end

  def test_a_thread_github_answers_with_null_stays_in_the_store_marked_failed
    with_pr do |repo, c1, base, gh|
      gh.thread = ->(_vars) {}
      kept = draft(base, c1)

      result = post(repo, gh)

      assert_equal 0, result["posted"]
      assert_match(/no thread came back/, result["failed"].first)
      assert_match(/no thread came back/, drafts.find(kept["id"])["failed"])
      refute drafts.edit(kept["id"], "reworded").key?("failed"), "an edit is a new try"
    end
  end

  def test_a_commit_draft_posts_on_its_commit_by_position_with_the_feature_header
    with_pr do |repo, c1, base, gh|
      draft(base, c1, range: c1[0, 7])
      push_head(LINES.sub("line 5\n", "line FIVE\n"))

      result = post(repo, gh)

      assert_equal 1, result["posted"]
      comment = gh.graphql.last
      assert_equal ["addPullRequestReviewComment", Quartermaster::PendingReview::POSITION_FEATURE], comment.values_at(:name, :header)
      # base..c1: @@ -2,7 +2,7 @@ then lines 2, 3, 4, -5, +5 — the added line 5 is position 5.
      assert_equal({ "review" => "PRR_new", "commit" => c1, "path" => "a.txt", "body" => "why five?", "position" => 5 },
                   comment[:vars])
    end
  end

  def test_when_the_commit_route_errors_it_falls_back_to_a_file_comment_quoting_the_line
    with_pr do |repo, c1, base, gh|
      gh.comment_error = "Field 'position' doesn't exist"
      draft(base, c1, range: c1[0, 7])
      push_head(LINES.sub("line 5\n", "line FIVE\n"))

      result = post(repo, gh)

      assert_equal [1, 1], result.values_at("posted", "fallbacks")
      fallback = gh.graphql.last
      assert_equal %w[addPullRequestReviewThread FILE], [fallback[:name], fallback[:vars]["subject"]]
      assert_equal "on #{c1[0, 7]}, a.txt:5:\n> line five\n\nwhy five?", fallback[:vars]["body"]
      refute fallback[:vars].key?("line")
    end
  end

  def test_a_whole_pr_draft_follows_its_line_after_a_push_and_is_reanchored_in_the_store
    with_pr do |repo, c1, base, gh|
      kept = draft(base, c1)
      head = push_head("new a\nnew b\n" + LINES.sub("line 5\n", "line five\n"))

      route, = routes(repo, gh)
      assert_equal ["head", 7, true], route.values_at("route", "line", "moved")

      plan = Quartermaster::ReviewPlan.new(repo, base_ref: "origin/main", head: head)
      Quartermaster::PendingReview.reanchor(plan, drafts.entries, drafts)
      assert_equal [7, head, kept["rev"]], drafts.find(kept["id"]).values_at("line", "commit", "rev")
    end
  end

  def test_a_whole_pr_draft_whose_line_changed_is_outdated_and_not_posted
    with_pr do |repo, c1, base, gh|
      draft(base, c1)
      push_head(LINES.sub("line 5\n", "line FIVE\n"))

      route, = routes(repo, gh)
      result = post(repo, gh)

      assert_equal ["outdated", false, c1], route.values_at("route", "fileGone", "oldCommit")
      assert_equal [true], route["context"].select { |l| l["s"] == "line five" }.map { |l| l["at"] }
      assert_equal %w[line\ 3 line\ 8], [route["context"].first["s"], route["context"].last["s"]]
      assert_equal({ "posted" => 0, "failed" => [], "fallbacks" => 0, "outdated" => 1 }, result)
      assert_equal ["query"], gh.graphql.map { |c| c[:name] }.uniq, "nothing to post, no review made"
      assert_equal 1, drafts.entries.size
    end
  end

  def test_pinned_to_its_old_commit_an_outdated_draft_posts_there
    with_pr do |repo, c1, base, gh|
      kept = draft(base, c1)
      push_head(LINES.sub("line 5\n", "line FIVE\n"))
      drafts.relocate(kept["id"], { "pin" => "commit" }, bump: true)

      route, = routes(repo, gh)

      assert_equal ["commit", c1, 5], route.values_at("route", "commit", "position")
    end
  end

  def test_a_commit_draft_follows_a_rebase_to_the_commit_with_its_patch
    with_pr do |repo, c1, base, gh|
      kept = draft(base, c1, range: c1[0, 7])
      system("git", "-C", @wt, "reset", "-q", "--hard", "main", exception: true)
      commit(@wt, "z.txt", "z\n", message: "first now")
      system("git", "-C", @wt, *GIT_ID, "cherry-pick", c1, out: File::NULL, exception: true)
      rebased = sha_of(@wt, "HEAD")
      push_head(LINES.sub("line 5\n", "line FIVE\n"))

      route, = routes(repo, gh)

      refute_equal c1, rebased
      assert_equal ["commit", rebased, true], route.values_at("route", "commit", "moved")
      plan = review(repo, gh).send(:plan)
      Quartermaster::PendingReview.reanchor(plan, drafts.entries, drafts)
      assert_equal rebased, drafts.find(kept["id"])["commit"]
    end
  end

  def test_a_file_comment_on_a_file_that_left_the_pr_is_outdated_with_no_old_commit_route
    with_pr do |repo, c1, base, gh|
      draft(base, c1, subject: "file")
      push_head(LINES)

      route, = routes(repo, gh)

      assert_equal ["outdated", true, nil], route.values_at("route", "fileGone", "oldCommit")
    end
  end

  # The GUI's side: preview and post as actions, the outdated card's places.
  def test_preview_counts_and_post_runs_as_the_items_job
    with_pr do |_repo, c1, base, gh|
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      draft(base, c1)
      pr = { "repo" => "acme/widgets", "number" => 7 }

      assert_equal 1, act(gui, "review-preview", pr).dig("preview", "head")
      assert_includes Quartermaster::GuiActions::UNLOCKED, "review-preview"
      assert act(gui, "review-post", pr)["background"]
      finished = nil
      50.times { break if (finished = gui.jobs.take_finished.first); sleep 0.1 }

      assert_equal [true, "feat"], finished.values_at("ok", "key")
      assert_match(/1 added to your pending review on widgets#7 — submit it here or on GitHub/, finished["message"])
      assert_empty Quartermaster::Drafts.new("feat").entries
      assert_match(/no review drafts/, act(gui, "review-post", pr)["error"])
    end
  end

  def test_a_review_summary_is_never_posted_as_a_comment
    with_pr do |repo, c1, base, gh|
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      pr = { "repo" => "acme/widgets", "number" => 7 }
      drafts.put_review_summary(pr.merge("verdict" => "approve", "author" => "claude", "comment" => "LGTM"))

      assert_match(/no review drafts for widgets#7/, act(gui, "review-preview", pr)["error"])
      draft(base, c1)
      assert_equal [1, 1], act(gui, "review-preview", pr)["preview"].values_at("count", "head")

      assert_equal 1, post(repo, gh)["posted"]
      assert_equal %w[review-summary], drafts.entries.map { |entry| entry["kind"] }
    end
  end

  def test_the_outdated_card_places_a_draft_on_a_line_the_file_or_its_old_commit
    with_pr do |_repo, c1, base, _gh|
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      kept = draft(base, c1, range: c1[0, 7], start_line: 4, start_side: "new", code: "line 4\nline five")
      head = { "commit" => c1, "base" => base }

      far = act(gui, "draft-place", head.merge("id" => kept["id"], "how" => "line", "path" => "a.txt", "side" => "new",
                                                "line" => 15, "code" => "line 15"))
      placed = act(gui, "draft-place", head.merge("id" => kept["id"], "how" => "line", "path" => "a.txt", "side" => "new",
                                                   "line" => 6, "code" => "line 6"))
      assert_match(/can't take a comment/, far["error"])
      assert_equal [6, nil, nil, c1, 2], placed["draft"].values_at("line", "start_line", "range", "commit", "rev")

      file = act(gui, "draft-place", head.merge("id" => kept["id"], "how" => "file"))
      assert_equal "file", file.dig("draft", "subject")
      pinned = act(gui, "draft-place", "id" => kept["id"], "how" => "commit")
      assert_equal "commit", pinned.dig("draft", "pin")
      assert_match(/not "elsewhere"/, act(gui, "draft-place", "id" => kept["id"], "how" => "elsewhere")["error"])
    end
  end
end

class PrPostScopeTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers

  def test_the_pr_scope_routes_the_items_drafts_and_reanchors_the_moved_ones
    with_pr_repo do |repo|
      commit(repo, "a.txt", PrPostHelpers::LINES)
      push(repo, "main")
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "a.txt", PrPostHelpers::LINES.sub("line 5\n", "line five\n"), message: "c1")
      c1 = sha_of(wt, "HEAD")
      push(wt, "feature:refs/pull/7/head")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      cache_prs(pr_entry)
      store = Quartermaster::Drafts.new(item.slug)
      pr = { "kind" => "github-comment", "repo" => "acme/widgets", "number" => 7, "base" => sha_of(repo, "main"),
             "commit" => c1, "path" => "a.txt", "side" => "new", "comment" => "c" }
      moving = store.put_diff_comment(pr.merge("line" => 5, "code" => "line five"))
      stale = store.put_diff_comment(pr.merge("line" => 4, "code" => "line 4"))
      other = store.put_diff_comment(pr.merge("number" => 8, "line" => 5, "code" => "line five"))
      commit(wt, "a.txt", "top\n" + PrPostHelpers::LINES.sub("line 4\nline 5\n", "line four\nline five\n"), message: "c2")
      push(wt, "feature:refs/pull/7/head")

      routes = Quartermaster::BranchDiff.new(tmux: FakeTmux.new, runner: GitPassThroughRunner.new)
                                        .call(item, scope: "pr")["reviewRoutes"]

      assert_equal [moving["id"], stale["id"]].sort, routes.keys.sort, "only this PR's drafts"
      assert_equal %w[head outdated], [routes[moving["id"]]["route"], routes[stale["id"]]["route"]]
      assert_equal [6, sha_of(wt, "HEAD")], store.find(moving["id"]).values_at("line", "commit")
      assert_equal 5, store.find(other["id"])["line"]
    end
  end
end

class PrPostPageTest < Minitest::Test
  include QmTestHelpers

  def test_the_page_confirms_before_posting_and_shows_outdated_drafts_as_cards
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new),
                       { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" })

    ['<script src="/assets/js/review.js"></script>', 'act("review-preview", { slug, args: { repo, number, ids } })',
     'act("review-post", { slug, args: { repo, number, ids } })', "→ pending review on ${esc(p.pr)}</h2>",
     'el("button", "primary gh", "Place on a line")', '"Comment on the file"', '"Comment on the old commit"',
     "renderOutdatedCards(box, f);", "if (placeDraftOnRow(tr)) return;", "reviewPostFinished(r);",
     'el("span", "dt-tag outdated", "outdated")', "entry.appendChild(outdatedCard(d, reviewRoute(d), true));",
     ".d-outdated {"].each { |seam| assert_includes html, seam }
  end
end
