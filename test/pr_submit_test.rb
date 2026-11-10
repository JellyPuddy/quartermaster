# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_submit_test.rb`).
require_relative "test_helper"
require_relative "pr_post_test"

# Submitting the user's review with a verdict (submit plan D1, D3-D7): the
# drafts go into the pending review first, then submitPullRequestReview.
class PrSubmitTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers
  include PrPostHelpers

  def submit(repo, gh, event, body = "", entries: drafts.entries)
    review(repo, gh).submit(entries, drafts, event: event, body: body)
  end

  def names(gh) = gh.graphql.map { |c| c[:name] }

  def test_the_drafts_are_posted_then_the_new_pending_review_is_submitted
    with_pr do |repo, c1, base, gh|
      draft(base, c1)

      result = submit(repo, gh, "APPROVE")

      assert_equal %w[query addPullRequestReview addPullRequestReviewThread submitPullRequestReview], names(gh)
      assert_equal({ "review" => "PRR_new", "event" => "APPROVE", "body" => "" }, gh.graphql.last[:vars])
      assert_equal ["APPROVE", 1, 1, []], result.values_at("submitted", "comments", "posted", "failed")
      assert_empty drafts.entries
    end
  end

  def test_a_pending_review_started_on_github_is_the_one_submitted_drafts_or_not
    with_pr do |repo, _c1, _base, gh|
      gh.pending = "PRR_mine"

      result = submit(repo, gh, "COMMENT")

      assert_equal %w[query submitPullRequestReview], names(gh)
      assert_equal({ "review" => "PRR_mine", "event" => "COMMENT", "body" => "" }, gh.graphql.last[:vars])
      assert_equal ["COMMENT", 2], result.values_at("submitted", "comments"), "its 2 pending comments go with it"
    end
  end

  def test_with_nothing_pending_a_plain_approve_makes_a_review_on_the_head_and_submits_it
    with_pr do |repo, c1, _base, gh|
      result = submit(repo, gh, "approve", "Ship it")

      assert_equal %w[query addPullRequestReview submitPullRequestReview], names(gh)
      assert_equal({ "pr" => "PR_1", "commit" => c1 }, gh.graphql[1][:vars])
      assert_equal({ "review" => "PRR_new", "event" => "APPROVE", "body" => "Ship it" }, gh.graphql.last[:vars])
      assert_equal ["APPROVE", 0], result.values_at("submitted", "comments")
    end
  end

  def test_a_draft_that_fails_aborts_before_anything_is_submitted
    with_pr do |repo, c1, base, gh|
      gh.thread = ->(_vars) {}
      kept = draft(base, c1)

      result = submit(repo, gh, "REQUEST_CHANGES", "Please fix")

      refute_includes names(gh), "submitPullRequestReview"
      assert_nil result["submitted"]
      assert_match(/no thread came back/, result["failed"].first)
      assert drafts.find(kept["id"])["failed"]
    end
  end

  def test_an_outdated_draft_stays_and_does_not_block_the_submit
    with_pr do |repo, c1, base, gh|
      kept = draft(base, c1)
      push_head(LINES.sub("line 5\n", "line FIVE\n"))

      result = submit(repo, gh, "APPROVE")

      assert_equal ["APPROVE", 1, 0], result.values_at("submitted", "outdated", "comments")
      assert_equal [kept["id"]], drafts.entries.map { |entry| entry["id"] }
    end
  end

  def test_on_their_own_pr_only_a_comment_is_taken
    with_pr do |repo, _c1, _base, gh|
      gh.own = true

      %w[APPROVE REQUEST_CHANGES].each do |event|
        error = assert_raises(ArgumentError) { submit(repo, gh, event, "body") }
        assert_match(/your own pull request — only a comment/, error.message)
      end
      assert_equal ["query"], names(gh).uniq, "refused before anything was made or posted"
      assert_equal "COMMENT", submit(repo, gh, "COMMENT", "notes to self")["submitted"]
    end
  end

  def test_the_body_rules
    with_pr do |repo, c1, base, gh|
      assert_match(/needs a summary/, assert_raises(ArgumentError) { submit(repo, gh, "REQUEST_CHANGES", "  ") }.message)
      assert_match(/needs a summary when it carries no comments/,
                   assert_raises(ArgumentError) { submit(repo, gh, "COMMENT") }.message)
      assert_equal "'MERGE' is not a verdict: approve, comment or request-changes",
                   assert_raises(ArgumentError) { submit(repo, gh, "MERGE", "x") }.message
      assert_equal %w[APPROVE COMMENT REQUEST_CHANGES], Quartermaster::PendingReview::EVENTS
      draft(base, c1)
      push_head(LINES.sub("line 5\n", "line FIVE\n"))
      assert_raises(ArgumentError, "an outdated draft is no comment") { submit(repo, gh, "COMMENT") }
      refute_includes names(gh), "submitPullRequestReview"
    end
  end

  def test_a_comment_with_line_comments_may_go_without_a_summary
    with_pr do |repo, c1, base, gh|
      draft(base, c1)

      assert_equal "COMMENT", submit(repo, gh, "COMMENT")["submitted"]
    end
  end

  # The GUI's side: review-submit as the item's job, preview's additions.
  def finished_job(gui)
    finished = nil
    50.times { break if (finished = gui.jobs.take_finished.first); sleep 0.1 }
    finished
  end

  PR = { "repo" => "acme/widgets", "number" => 7 }.freeze

  def test_review_submit_checks_what_it_can_before_the_job
    with_pr do |_repo, _c1, _base, _gh|
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      assert_match(/not a verdict/, act(gui, "review-submit", PR.merge("event" => "LGTM"))["error"])
      assert_match(/needs a summary/, act(gui, "review-submit", PR.merge("event" => "REQUEST_CHANGES", "body" => ""))["error"])
      assert_match(/not a PR number/, act(gui, "review-submit", PR.merge("number" => "x", "event" => "APPROVE"))["error"])
      refute_includes Quartermaster::GuiActions::UNLOCKED, "review-submit"
    end
  end

  def test_review_submit_toasts_the_verdict_and_clears_the_drafts_and_the_summary
    with_pr do |_repo, c1, base, gh|
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      draft(base, c1)
      drafts.put_review_summary(PR.merge("verdict" => "approve", "author" => "claude", "comment" => "LGTM"))

      assert act(gui, "review-submit", PR.merge("event" => "APPROVE", "body" => "LGTM"))["background"]
      finished = finished_job(gui)

      assert_equal [true, "feat", "Approved widgets#7 · 1 comment", true],
                   finished.values_at("ok", "key", "message", "review")
      assert_empty drafts.entries
      assert_equal "submitPullRequestReview", gh.graphql.last[:name]
      assert_equal "in_progress", Quartermaster::WorkItem.find("feat").state, "a normal item gets nothing"
    end
  end

  def test_review_submit_records_the_verdict_on_the_prs_review_item_and_resolves_it
    with_pr do |_repo, _c1, _base, gh|
      gh.pending = "PRR_mine"
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      item = Quartermaster::WorkItem.create("Review widgets#7: Feat", project: "Qm")
      item.describe("Review of pull request https://github.com/acme/widgets/pull/7 by @ann: `feature` → `main`.")

      act(gui, "review-submit", PR.merge("event" => "REQUEST_CHANGES", "body" => "Needs tests"))
      finished = finished_job(gui)

      assert_equal "Requested changes on widgets#7 · 2 comments", finished["message"]
      reviewed = Quartermaster::WorkItem.find(item.slug)
      assert_equal "resolved", reviewed.state
      assert_equal "Submitted review: Requested changes on widgets#7 (2 comments)", reviewed.notes.last.text
      assert_equal "history", reviewed.notes.last.kind
    end
  end

  def test_review_submit_that_aborts_says_nothing_was_submitted
    with_pr do |_repo, c1, base, gh|
      gh.thread = ->(_vars) {}
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      draft(base, c1)
      drafts.put_review_summary(PR.merge("comment" => "Overall fine"))

      act(gui, "review-submit", PR.merge("event" => "COMMENT", "body" => "Overall fine"))
      finished = finished_job(gui)

      assert_equal false, finished["ok"]
      assert_match(/Nothing submitted on widgets#7: 1 failed and stays in the tray: a.txt:5: .*no thread came back/, finished["error"])
      assert_equal %w[github-comment review-summary], drafts.entries.map { |entry| entry["kind"] }.sort
    end
  end

  def test_the_submit_forms_preview_works_without_drafts_and_knows_the_author_and_summary
    with_pr do |_repo, _c1, _base, gh|
      gh.own = true
      gui = Quartermaster::Gui.new(port: 4567, runner: gh, tmux: FakeTmux.new)
      summary = drafts.put_review_summary(PR.merge("verdict" => "comment", "author" => "claude", "comment" => "Fine"))

      assert_match(/no review drafts/, act(gui, "review-preview", PR)["error"], "Post as pending review still needs drafts")
      preview = act(gui, "review-preview", PR.merge("submit" => true))["preview"]

      assert_equal [0, true, nil], preview.values_at("count", "viewerIsAuthor", "pending")
      assert_equal summary, preview["summary"]
    end
  end
end

# The verdict form and the tray's summary entry (submit plan D2, D5, D6, D9): no JS
# harness, so these pin the seams; the form's behavior is checked by hand.
class PrSubmitPageTest < Minitest::Test
  include QmTestHelpers

  def test_the_page_offers_the_verdict_form_and_shows_the_summary_atop_its_pr
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new),
                       { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" })

    assert_operator html.index('<script src="/assets/js/review.js">'), :<, html.index('<script src="/assets/js/review-submit.js">')
    assert_operator html.index('<script src="/assets/js/review-submit.js">'), :<, html.index('<script src="/assets/js/events.js">')
    ['if (d && d.scope === "pr" && d.pr) how.appendChild(submitReviewButton(d.pr.repo, d.pr.number));',
     'btns.appendChild(submitReviewButton(d.repo, d.number, posted.map(x => x.id)));',
     'act("review-preview", { slug, args: { repo, number, ids, submit: true } })',
     'act("review-submit", { slug, args: { repo, number, ids, event, body: body.value } })',
     'const off = p.viewerIsAuthor && event !== "COMMENT";', 'if (event === "REQUEST_CHANGES") return "Say what to change in the summary";',
     'if (event === "COMMENT" && !comments) return', 'body.value = summary ? summary.comment || "" : "";',
     '`🤖 Claude suggests: ${esc(verdictLabel(summary.verdict))}`', ': isReviewSummary(d) ? summaryTrayEntry(d)',
     'const reviewRank = d => (isReviewSummary(d) ? 0 : isThreadReply(d) ? 2 : 1);', 'Suggested verdict: ${verdictLabel(d.verdict)}'].each { |seam| assert_includes html, seam }
    assert_includes html, '<input type="radio" name="rv-verdict" value="${event}"${off ? " disabled" : ""}>',
                    "the radios carry no checked: a verdict is never pre-selected"
  end
end
