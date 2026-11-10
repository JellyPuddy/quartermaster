# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/chat_review_drafts_test.rb`).
require_relative "test_helper"

# `qm draft add` / `qm draft list` (PR review plan D14): a chat's findings as
# 🤖 GitHub drafts on the item's PR, held to the diff pane's anchor check.
class ChatReviewDraftsTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers
  include ChatAttentionHelpers

  LINES = ANCHOR_LINES
  URL = "https://github.com/acme/widgets/pull/7"

  def setup
    super
    @port = ENV["QM_GUI_PORT"]
  end

  def teardown
    @port ? ENV["QM_GUI_PORT"] = @port : ENV.delete("QM_GUI_PORT")
  end

  # main: a.txt of 20 lines. The PR's c1 changes line 5, its c2 line 12, so
  # base..head shows lines 2-15 and base..c1 only 2-8.
  def with_pr
    with_pr_repo do |repo|
      commit(repo, "a.txt", LINES)
      push(repo, "main")
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "a.txt", LINES.sub("line 5\n", "line five\n"), message: "c1")
      c1 = sha_of(wt, "HEAD")
      commit(wt, "a.txt", LINES.sub("line 5\n", "line five\n").sub("line 12\n", "line twelve\n"), message: "c2")
      push(wt, "feature:refs/pull/7/head")
      cache_prs(pr_entry)
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      yield repo, c1, sha_of(wt, "HEAD"), sha_of(repo, "main")
    end
  end

  def qm(*argv, runner: GitPassThroughRunner.new, stdin: nil)
    exited = nil
    $stdin = StringIO.new(stdin) if stdin
    out, err = capture_io do
      Quartermaster::CLI.new(runner: runner, cwd: Dir.home).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  ensure
    $stdin = STDIN
  end

  def drafts = Quartermaster::Drafts.new("feat").entries

  def test_a_finding_on_a_line_the_pr_shows_is_a_claude_draft_at_the_pr_head
    with_pr do |_repo, _c1, head, base|
      out, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--body", "why five?")

      assert_nil exited, err
      entry = drafts.first
      assert_equal({ "kind" => "github-comment", "path" => "a.txt", "side" => "new", "line" => 5, "code" => "line five",
                     "repo" => "acme/widgets", "number" => 7, "base" => base, "commit" => head, "subject" => "line",
                     "author" => "claude", "comment" => "why five?" },
                   entry.except("id", "rev", "createdAt", "updatedAt"))
      assert_equal "🤖 review comment on widgets#7 a.txt:5 @#{head[0, 7]} drafted (#{entry["id"]})\n", out
    end
  end

  def test_a_line_github_cant_take_is_refused_with_the_file_comment_way_out
    with_pr do |_repo, _c1, head, _base|
      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "19", "--body", "hm")

      assert_equal 1, exited
      assert_includes err, "GitHub can't take a comment on a.txt:19 at widgets#7 @#{head[0, 7]}"
      assert_includes err, "Record it as a file comment with --file instead"
      assert_empty drafts

      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "19", "--file", "--body", "hm")
      assert_nil exited, err
      assert_equal %w[file line\ 19], drafts.first.values_at("subject", "code")
      _, err, = qm("draft", "add", "feat", "--path", "nope.txt", "--line", "1", "--file", "--body", "hm")
      assert_includes err, "nope.txt isn't in the diff of widgets#7"
    end
  end

  def test_a_range_carries_its_lines_and_must_stay_in_one_hunk
    with_pr do |_repo, _c1, _head, _base|
      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--start-line", "4", "--line", "6", "--body", "these")

      assert_nil exited, err
      assert_equal [4, "new", "line 4\nline 5\nline five\nline 6"], drafts.first.values_at("start_line", "start_side", "code")
      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--start-line", "1", "--line", "6", "--body", "x")
      assert_equal 1, exited
      assert_includes err, "a.txt:1"
    end
  end

  def test_a_commit_anchored_finding_is_numbered_up_to_that_commit_and_shown_under_its_run
    with_pr do |_repo, c1, head, _base|
      _, err, = qm("draft", "add", "feat", "--path", "a.txt", "--line", "12", "--commit", c1[0, 8], "--body", "x")
      assert_includes err, "GitHub can't take a comment on a.txt:12 at widgets#7 @#{c1[0, 7]}"

      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--commit", c1, "--body", "at c1")
      assert_nil exited, err
      entry = drafts.first
      assert_equal c1, entry["commit"]
      assert_match(/\A\h{7,}\z/, entry["range"])
      assert c1.start_with?(entry["range"]), "a run of one commit is labelled by its short sha, as the pane labels it"
      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "12", "--commit", head, "--body", "at head")
      assert_nil exited, err
      assert_nil drafts.last["range"], "the head is the whole PR's view"
      _, err, = qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--commit", "deadbeef", "--body", "x")
      assert_includes err, "deadbeef is not one of the pull request's commits"
    end
  end

  def test_claude_replaces_its_own_draft_but_never_the_users
    with_pr do |_repo, _c1, _head, _base|
      qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--body", "first")
      out, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--body-file", "-", stdin: "second\n")

      assert_nil exited, err
      assert_includes out, "replaced your earlier draft there"
      assert_equal ["second\n"], drafts.map { |d| d["comment"] }
      store = Quartermaster::Drafts.new("feat")
      assert_equal "user", store.edit(drafts.first["id"], "mine now")["author"], "the user's once they edit it"
      _, err, exited = qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--body", "third")
      assert_equal 1, exited
      assert_includes err, "a.txt:5 already holds the user's draft"
      assert_equal ["mine now"], drafts.map { |d| d["comment"] }
    end
  end

  def test_a_reply_to_a_review_thread_is_a_claude_reply_draft
    with_pr do |_repo, _c1, _head, _base|
      out, err, exited = qm("draft", "add", "feat", "--reply-to", "PRRT_kwDOabc", "--body", "agreed")

      assert_nil exited, err
      assert_equal({ "kind" => "thread-reply", "thread" => "PRRT_kwDOabc", "repo" => "acme/widgets", "number" => 7, "url" => URL,
                     "author" => "claude", "comment" => "agreed" }, drafts.first.except("id", "rev", "createdAt", "updatedAt"))
      assert_includes out, "🤖 reply on widgets#7 to thread PRRT_kwDOabc drafted"
      _, err, = qm("draft", "add", "feat", "--reply-to", "PRRT_kwDOabc", "--commit", "abc1234", "--body", "x")
      assert_includes err, "a reply goes to its thread"
      _, err, = qm("draft", "add", "feat", "--reply-to", "PRRT kw", "--body", "x")
      assert_includes err, "is not a review thread id"
    end
  end

  def test_review_drafts_never_go_to_the_chat
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    store = Quartermaster::Drafts.new("drafted")
    store.put_thread_reply("thread" => "PRRT_x", "repo" => "acme/widgets", "number" => 7, "author" => "claude", "comment" => "yes")

    reply = gui.actions.dispatch("cmd" => "drafts-send", "slug" => "drafted", "args" => {})
    assert_equal({ "ok" => false, "error" => "no drafts to send" }, reply)
    assert_equal 1, store.entries.size
  end

  def test_the_pr_comes_from_pr_or_the_review_item_or_an_error_says_how_to_name_it
    with_pr do |_repo, _c1, _head, _base|
      Quartermaster::WorkItem.create("Bare", project: "Qm")
      review = Quartermaster::WorkItem.create("Review widgets#7: Add widgets", project: "Qm",
                                              description: "Review of pull request #{URL} by @x: `feature` → `main`.")

      _, err, = qm("draft", "add", "bare", "--path", "a.txt", "--line", "5", "--body", "x")
      assert_includes err, "none of bare's branches has an open pull request — name it with --pr URL"
      _, err, exited = qm("draft", "add", "bare", "--pr", URL, "--path", "a.txt", "--line", "5", "--body", "x")
      assert_nil exited, err
      _, err, exited = qm("draft", "add", review.slug, "--path", "a.txt", "--line", "5", "--body", "x")
      assert_nil exited, err
      other = GitPassThroughRunner.new(%w[gh pr view] => [JSON.generate("number" => 3, "url" => "https://github.com/acme/other/pull/3",
                                                                       "headRefName" => "x", "baseRefName" => "main", "state" => "OPEN"), "", true])
      _, err, = qm("draft", "add", "bare", "--pr", "https://github.com/acme/other/pull/3", "--path", "a.txt", "--line", "5",
                   "--body", "x", runner: other)
      assert_includes err, "is not in bare's repo"
    end
  end

  def test_list_shows_the_items_drafts_and_whose_they_are
    with_pr do |_repo, _c1, head, _base|
      qm("draft", "add", "feat", "--path", "a.txt", "--line", "5", "--body", "why five?\nmore")
      Quartermaster::Drafts.new("feat").put_diff_comment(DRAFT_COMMENT)

      out, = qm("draft", "list", "feat")
      lines = out.lines
      assert_match(/\A\h{12}  review comment on widgets#7 a\.txt:5 @#{head[0, 7]}  🤖 claude: why five\?\n\z/, lines[0])
      assert_match(/chat comment on lib\/a\.rb:2  user: rename x/, lines[1])
      json, = qm("draft", "list", "feat", "--json")
      assert_equal 2, JSON.parse(json).size
    end
  end

  def test_a_summary_is_claudes_suggested_verdict_one_per_pr_never_overwriting_the_users
    with_pr do |_repo, _c1, _head, _base|
      out, err, exited = qm("draft", "add", "feat", "--summary", "--verdict", "request-changes", "--body", "Needs a test.")

      assert_nil exited, err
      entry = drafts.first
      assert_equal({ "kind" => "review-summary", "repo" => "acme/widgets", "number" => 7, "verdict" => "request-changes",
                     "author" => "claude", "comment" => "Needs a test." }, entry.except("id", "rev", "createdAt", "updatedAt"))
      assert_equal "🤖 review summary on widgets#7 (request changes) drafted (#{entry["id"]})\n", out

      out, err, exited = qm("draft", "add", "feat", "--summary", "--body-file", "-", stdin: "Fine after all.\n")
      assert_nil exited, err
      assert_includes out, "🤖 review summary on widgets#7 drafted"
      assert_includes out, "replaced your earlier draft there"
      assert_equal [[entry["id"], nil, "Fine after all.\n"]], drafts.map { |d| d.values_at("id", "verdict", "comment") }

      Quartermaster::Drafts.new("feat").edit(entry["id"], "My own words.")
      _, err, exited = qm("draft", "add", "feat", "--summary", "--verdict", "approve", "--body", "LGTM")
      assert_equal 1, exited
      assert_includes err, "widgets#7's review summary already holds the user's draft #{entry["id"]}"
      assert_equal [["My own words.", "user"]], drafts.map { |d| d.values_at("comment", "author") }
    end
  end

  def test_a_summary_takes_a_known_verdict_and_no_line_flags
    with_pr do |_repo, _c1, _head, _base|
      _, err, exited = qm("draft", "add", "feat", "--summary", "--verdict", "lgtm", "--body", "x")
      assert_equal 1, exited
      assert_includes err, "'lgtm' is not a verdict: approve, comment or request-changes"
      _, err, = qm("draft", "add", "feat", "--verdict", "approve", "--path", "a.txt", "--line", "5", "--body", "x")
      assert_includes err, "--verdict goes with --summary"
      [%w[--path a.txt], %w[--line 5], %w[--start-line 4], %w[--side old], %w[--commit abc1234], %w[--file],
       %w[--reply-to PRRT_kwDOabc]].each do |flag|
        _, err, = qm("draft", "add", "feat", "--summary", *flag, "--body", "x")
        assert_includes err, "a summary is on the whole PR — #{flag.first} doesn't apply"
      end
      _, err, = qm("draft", "add", "feat", "--summary", "--body", " ")
      assert_includes err, "the comment is empty"
      assert_empty drafts
    end
  end

  def test_a_summary_finds_its_pr_as_other_drafts_do_and_list_shows_it
    with_pr do |_repo, _c1, _head, _base|
      Quartermaster::WorkItem.create("Bare", project: "Qm")
      review = Quartermaster::WorkItem.create("Review widgets#7: Add widgets", project: "Qm",
                                              description: "Review of pull request #{URL} by @x: `feature` → `main`.")

      _, err, = qm("draft", "add", "bare", "--summary", "--body", "x")
      assert_includes err, "none of bare's branches has an open pull request — name it with --pr URL"
      _, err, exited = qm("draft", "add", "bare", "--pr", URL, "--summary", "--verdict", "comment", "--body", "x")
      assert_nil exited, err
      _, err, exited = qm("draft", "add", review.slug, "--summary", "--verdict", "approve", "--body", "Ship it\nreally")
      assert_nil exited, err

      out, = qm("draft", "list", review.slug)
      assert_match(/\A\h{12}  review summary on widgets#7 \(approve\)  🤖 claude: Ship it\n\z/, out)
    end
  end

  def test_kickoff_asks_for_the_verdict_as_a_summary_draft
    kickoff = Quartermaster::PrItems.new.review_kickoff("/code-review", { "url" => URL }, "review-widgets-7")
    assert_includes kickoff, "qm draft add review-widgets-7 --summary --verdict approve|comment|request-changes --body"
  end

  def test_help_lists_draft_add_and_explains_it
    out, = capture_io { Quartermaster::CLI.new.run(["help"]) }
    assert_includes out, "qm draft add SLUG"
    help, = qm("draft", "add", "--help")
    assert_includes help, "--reply-to THREAD_ID"
    assert_includes help, "use --file for a"
  end
end
