# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_scope_test.rb`).
require_relative "test_helper"

class PrScopeTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers

  def branch_diff(item, runner: GitPassThroughRunner.new, **options)
    Quartermaster::BranchDiff.new(tmux: FakeTmux.new, runner: runner).call(item, **options)
  end

  def paths(result) = result["files"].map { |f| f["path"] }

  # The feature branch has two commits on GitHub's pull/7/head, one of which
  # the local branch hasn't got; main moved on after the branch point.
  def with_pushed_pr
    with_pr_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "one.txt", "1\n")
      push(wt, "feature:refs/pull/7/head")
      commit(wt, "two.txt", "2\n")
      push(wt, "feature:refs/pull/7/head")
      system("git", "-C", wt, "reset", "-q", "--hard", "HEAD~1")
      File.write(File.join(wt, "uncommitted.txt"), "local only\n")
      commit(repo, "trunk-only.txt", "later on main\n")
      push(repo, "main")
      yield repo, wt
    end
  end

  def test_pr_scope_diffs_the_fetched_pr_head_against_its_merge_base_with_origin_base
    with_pushed_pr do |repo, wt|
      cache_prs(pr_entry)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item, scope: "pr")

      head = sha_of(repo, "refs/quartermaster/pr/7")
      assert_equal %w[one.txt two.txt], paths(result).sort, "the PR's head, not the local branch or its working tree"
      assert_equal ["change one.txt", "change two.txt"], result["commits"].map { |c| c["subject"] }
      assert_equal sha_of(wt, "main~1"), result["base"]["sha"], "the branch point, not origin/main's tip"
      assert_equal %w[origin/main pr], result["base"].values_at("ref", "kind")
      assert_equal({ "repo" => "acme/widgets", "number" => 7, "url" => "https://github.com/acme/widgets/pull/7",
                     "title" => "Add widgets", "headSha" => head, "baseSha" => result["base"]["sha"] }, result["pr"])
      assert_equal [head, nil, true], result.values_at("anchor", "range", "prAvailable")
      assert_equal result["base"]["sha"], result["oldRev"], "the old side is the merge-base"
    end
  end

  def test_a_selected_run_of_pr_commits_diffs_only_that_and_anchors_to_its_last_commit
    with_pushed_pr do |repo, _wt|
      cache_prs(pr_entry)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      first, second = %w[refs/quartermaster/pr/7~1 refs/quartermaster/pr/7].map do |rev|
        branch_diff(item, scope: "pr") && sha_of(repo, rev)
      end

      single = branch_diff(item, scope: "pr", from: first[0, 7])
      run = branch_diff(item, scope: "pr", from: first, to: second)

      assert_equal [["one.txt"], first], [paths(single), single["anchor"]]
      assert_equal [%w[one.txt two.txt], second], [paths(run).sort, run["anchor"]]
      parent = sha_of(repo, "#{first}~1")
      assert_equal [parent, parent], [single["oldRev"], run["oldRev"]], "a selected run's old side is its first commit's parent"
      assert_raises(ArgumentError) { branch_diff(item, scope: "pr", from: sha_of(repo, "main")) }
    end
  end

  def test_a_selection_of_pr_commits_carries_their_messages_from_the_fetched_pr
    with_pushed_pr do |repo, _wt|
      cache_prs(pr_entry)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      assert_equal [], branch_diff(item, scope: "pr")["messages"]
      first, second = %w[refs/quartermaster/pr/7~1 refs/quartermaster/pr/7].map { |rev| sha_of(repo, rev) }
      single = branch_diff(item, scope: "pr", from: second)
      run = branch_diff(item, scope: "pr", from: first, to: second)

      assert_equal [[second, "change two.txt"]], single["messages"].map { |m| [m["sha"], m["body"]] },
                   "a commit only the PR's head has, not the local branch"
      assert_equal ["change one.txt", "change two.txt"], run["messages"].map { |m| m["body"] }
    end
  end

  def test_other_scopes_say_whether_the_branch_has_a_pr_without_asking_github
    with_pushed_pr do |_repo, _wt|
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      runner = GitPassThroughRunner.new

      refute branch_diff(item, runner: runner)["prAvailable"]
      cache_prs(pr_entry)
      assert branch_diff(item, runner: runner, scope: "commits")["prAvailable"]
      assert_empty runner.argvs, "no gh and no fetch outside the PR scope"
    end
  end

  def test_a_branch_missing_from_the_cache_is_looked_up_with_gh
    with_pushed_pr do |_repo, _wt|
      cache_prs
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      view = { "number" => 7, "url" => "https://github.com/acme/widgets/pull/7", "title" => "Add widgets",
               "headRefName" => "feature", "baseRefName" => "main", "state" => "OPEN" }
      runner = GitPassThroughRunner.new(%w[gh pr view] => [JSON.generate(view), "", true])

      result = branch_diff(item, runner: runner, scope: "pr")

      assert_equal %w[one.txt two.txt], paths(result).sort
      assert_includes runner.argvs, ["gh", "pr", "view", "feature", "--repo", "acme/widgets", "--json",
                                     Quartermaster::PrRevisions::GH_FIELDS]
    end
  end

  def test_a_branch_without_an_open_pr_is_an_error_in_the_pr_scope
    with_pushed_pr do |_repo, _wt|
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      none = GitPassThroughRunner.new(%w[gh pr view] => ["", "no pull requests found for branch \"feature\"", false])
      merged = { "number" => 7, "url" => "u", "headRefName" => "feature", "baseRefName" => "main", "state" => "MERGED" }
      closed = GitPassThroughRunner.new(%w[gh pr view] => [JSON.generate(merged), "", true])

      error = assert_raises(ArgumentError) { branch_diff(item, runner: none, scope: "pr") }
      assert_match(/feature has no open pull request/, error.message)
      assert_raises(ArgumentError) { branch_diff(item, runner: closed, scope: "pr") }
    end
  end

  def test_a_review_item_opens_on_its_own_pr_without_a_worktree
    with_pushed_pr do |repo, _wt|
      cache_prs
      item = Quartermaster::WorkItem.create("Review widgets#7: Add widgets", project: "Qm",
                                            description: "Review of pull request https://github.com/acme/widgets/pull/7 by @x: `feature` → `main`.")
      view = { "number" => 7, "url" => "https://github.com/acme/widgets/pull/7", "title" => "Add widgets",
               "headRefName" => "feature", "baseRefName" => "main", "state" => "OPEN" }
      runner = GitPassThroughRunner.new(%w[gh pr view] => [JSON.generate(view), "", true])
      launcher = Object.new
      launcher.define_singleton_method(:start_cwd) { |_item| nil }

      result = Quartermaster::BranchDiff.new(tmux: FakeTmux.new, runner: runner, launcher: launcher).call(item)

      assert_equal ["pr", repo, nil], result.values_at("scope", "path", "branch")
      assert_equal %w[one.txt two.txt], paths(result).sort
      assert_equal 7, result["pr"]["number"]
    end
  end

  def test_a_pr_from_another_repo_is_refused
    with_pushed_pr do |_repo, _wt|
      cache_prs(pr_entry.merge("repo" => "other/thing", "url" => "https://github.com/other/thing/pull/7"))
      item = Quartermaster::WorkItem.create("Review thing#7: X", project: "Qm",
                                            description: "Review of pull request https://github.com/other/thing/pull/7 by @x.")

      error = assert_raises(ArgumentError) { branch_diff(item) }
      assert_match(/not in this project's repo/, error.message)
    end
  end

  def test_review_pr_reads_only_review_items
    items = Quartermaster::PrItems.new
    review = Quartermaster::WorkItem.create("Review widgets#7: X", project: "Qm",
                                            description: "Review of pull request https://github.com/acme/widgets/pull/7 by @x.")
    own = Quartermaster::WorkItem.create("widgets#7: X", project: "Qm",
                                         description: "Pull request https://github.com/acme/widgets/pull/7 by @x.")

    assert_equal({ "url" => "https://github.com/acme/widgets/pull/7", "repo" => "acme/widgets", "number" => 7 },
                 items.review_pr(review))
    assert_nil items.review_pr(own)
  end

  def test_the_gui_serves_the_pr_scope_and_the_page_has_a_pr_scope_button
    with_pushed_pr do |_repo, _wt|
      cache_prs(pr_entry)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
      gui = Quartermaster::Gui.new(port: 4567, runner: GitPassThroughRunner.new, tmux: FakeTmux.new)

      body = JSON.parse(gui.respond("GET", "/api/diff/#{item.slug}?scope=pr", host, "")[2])

      assert body["ok"], body["error"]
      assert_equal [7, body["pr"]["headSha"]], [body["pr"]["number"], body["anchor"]]
      page = served_page(gui, host)
      assert_includes page, '["pr", "PR"'
      assert_includes page, "d.prAvailable"
    end
  end

  # The PR scope in the GUI with a PR only gh knows of, and a clock tests move.
  def with_memo_gui
    with_pushed_pr do |repo, _wt|
      cache_prs
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      view = { "number" => 7, "url" => "https://github.com/acme/widgets/pull/7", "title" => "Add widgets",
               "headRefName" => "feature", "baseRefName" => "main", "state" => "OPEN" }
      runner = GitPassThroughRunner.new(%w[gh pr view] => [JSON.generate(view), "", true])
      now = [1000.0]
      memo = Quartermaster::PrMemo.new(clock: -> { now[0] })
      gui = Quartermaster::Gui.new(port: 4567, runner: runner, tmux: FakeTmux.new, pr_memo: memo)
      host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
      load = lambda do |query|
        before = runner.argvs.size
        body = JSON.parse(gui.respond("GET", "/api/diff/#{item.slug}?scope=pr&#{query}", host, "")[2])
        assert body["ok"], body["error"]
        asked = runner.argvs.drop(before)
        [body, asked.count { |a| a.first(3) == %w[gh pr view] }, asked.count { |a| a.include?("fetch") }]
      end
      yield load, now, repo
    end
  end

  def test_selecting_another_pr_commit_reuses_the_lookup_and_fetch_and_fresh_redoes_them
    with_memo_gui do |load, _now, _repo|
      body, gh, fetches = load.call("fresh=1")
      assert_equal [1, 1], [gh, fetches]
      first = body["commits"].first["sha"]

      body, gh, fetches = load.call("from=#{first}&to=#{first}")
      assert_equal [0, 0], [gh, fetches], "a commit switch asks neither gh nor git fetch"
      assert_equal first, body["range"]["to"]

      _, gh, fetches = load.call("fresh=1&from=#{first}&to=#{first}")
      assert_equal [1, 1], [gh, fetches], "fresh=1 bypasses the memo"
    end
  end

  def test_the_memo_expires_after_a_minute
    with_memo_gui do |load, now, _repo|
      load.call("fresh=1")
      now[0] += 59
      assert_equal [0, 0], load.call("")[1, 2]
      now[0] += 2
      assert_equal [1, 1], load.call("")[1, 2], "61 s after the fetch both are asked anew"
    end
  end

  def test_a_remembered_head_no_longer_in_the_pr_ref_is_fetched_again
    with_memo_gui do |load, _now, repo|
      load.call("fresh=1")
      system("git", "-C", repo, "update-ref", "-d", "refs/quartermaster/pr/7", exception: true)

      body, gh, fetches = load.call("")
      assert_equal [0, 1], [gh, fetches], "the lookup still holds; the head must be fetched"
      assert_equal body["pr"]["headSha"], sha_of(repo, "refs/quartermaster/pr/7")
    end
  end

  def test_a_remembered_fetch_whose_base_commit_is_not_here_is_fetched_again
    with_pushed_pr do |repo, _wt|
      runner = GitPassThroughRunner.new
      revisions = Quartermaster::PrRevisions.new(runner: runner, memo: Quartermaster::PrMemo.new)
      revs = revisions.fetch(repo, pr_entry)
      memo = revisions.instance_variable_get(:@memo)
      entries = memo.instance_variable_get(:@entries)
      entries.each_value { |e| e[:value] = e[:value].merge("baseSha" => "0" * 40) }

      assert_equal revs, revisions.fetch(repo, pr_entry)
      assert_equal 2, runner.argvs.count { |a| a.include?("fetch") }
    end
  end

  def test_a_slower_older_lookup_does_not_overwrite_a_fresh_one_remembered_meanwhile
    now = [0.0]
    memo = Quartermaster::PrMemo.new(clock: -> { now[0] })
    older = memo.fetch(:pr) do
      now[0] += 1
      memo.fetch(:pr, fresh: true) { "fresh head" }
      "older head"
    end

    assert_equal "older head", older
    assert_equal "fresh head", memo.fetch(:pr) { flunk "the fresh value is remembered" }
  end

  # Review posting and the CLI build PrRevisions without the GUI's memo.
  def test_without_a_memo_every_fetch_asks_origin
    with_pushed_pr do |repo, _wt|
      runner = GitPassThroughRunner.new
      revisions = Quartermaster::PrRevisions.new(runner: runner)
      2.times { revisions.fetch(repo, pr_entry) }
      assert_equal 2, runner.argvs.count { |a| a.include?("fetch") }
    end
  end

  def test_the_page_asks_for_a_fresh_pr_fetch_on_reload_turn_end_and_entering_the_pr_scope
    gui = Quartermaster::Gui.new(port: 4567, runner: FakeRunner.new, tmux: FakeTmux.new)
    page = served_page(gui, { "host" => "127.0.0.1:4567" })

    assert_includes page, "async function loadDiff(fresh = false, refetch = fresh)"
    assert_includes page, "reload.onclick = () => loadDiff(true);"
    assert_includes page, "loadDiff(false, turnEnded)"
    assert_includes page, 'diffView.key !== null && !diffView.loading && !!diffView.data && diffView.data.scope === "pr"'
    assert_includes page, 'if (mayBePr && (refetch || !inPrScope)) params.set("fresh", "1");'
  end
end

class ReviewAnchorsTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers

  LINES = ANCHOR_LINES

  # base: a.txt of 20 lines, c.txt without a final newline and gone.txt.
  # x changes a.txt's lines 5 and 15 (two hunks), c.txt's last line and
  # deletes gone.txt; y, on top, changes line 10.
  def with_commits
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      commit(repo, "a.txt", LINES)
      commit(repo, "c.txt", "a\nb")
      commit(repo, "gone.txt", "bye\n")
      base = sha_of(repo, "HEAD")
      system("git", "-C", repo, "checkout", "-q", "-b", "pr")
      commit(repo, "a.txt", LINES.sub("line 5\n", "line five\n").sub("line 15\n", "line fifteen\n"))
      commit(repo, "c.txt", "a\nc")
      system("git", "-C", repo, "rm", "-q", "gone.txt")
      system("git", "-C", repo, *GIT_ID, "commit", "-q", "-m", "x")
      x = sha_of(repo, "HEAD")
      commit(repo, "a.txt", File.read(File.join(repo, "a.txt")).sub("line 10\n", "line ten\n"))
      yield repo, base, x, sha_of(repo, "HEAD")
    end
  end

  def test_lines_are_the_base_to_commit_hunks_with_three_lines_of_context
    with_commits do |repo, base, x, _y|
      anchors = Quartermaster::ReviewAnchors.new(repo, base: "main", commit: x[0, 8])

      assert_equal [base, x], [anchors.base_sha, anchors.commit]
      assert_equal [*2..8, *12..18], anchors.lines("a.txt", "RIGHT")
      assert_equal [*2..8, *12..18], anchors.lines("a.txt", "LEFT")
      refute anchors.commentable?("a.txt", "RIGHT", 10)
      refute anchors.commentable?("a.txt", "right", 1)
      assert anchors.commentable?("a.txt", "right", 2)
      assert_equal ["line five", "line 5"], [anchors.text("a.txt", "RIGHT", 5), anchors.text("a.txt", "LEFT", 5)]
      assert_empty anchors.lines("missing.txt", "RIGHT")
      assert_nil anchors.file("missing.txt")
      assert_equal anchors.lines("a.txt", "LEFT"), anchors.lines("a.txt", "old"), "the diff pane's sides are GitHub's"
      assert_raises(ArgumentError) { anchors.lines("a.txt", "middle") }
    end
  end

  def test_positions_count_down_from_the_first_hunk_header_through_later_headers
    with_commits do |repo, _base, x, _y|
      anchors = Quartermaster::ReviewAnchors.new(repo, base: "main", commit: x)

      # @@ (0) · 2 3 4 (1-3) · -5 (4) · +5 (5) · 6 7 8 (6-8) · @@ (9) · 12 13 14 (10-12) · -15 (13) · +15 (14)
      assert_equal [1, 4, 5, 8], [anchors.position("a.txt", "RIGHT", 2), anchors.position("a.txt", "LEFT", 5),
                                  anchors.position("a.txt", "RIGHT", 5), anchors.position("a.txt", "RIGHT", 8)]
      assert_equal [10, 13, 14, 17], [anchors.position("a.txt", "RIGHT", 12), anchors.position("a.txt", "LEFT", 15),
                                      anchors.position("a.txt", "RIGHT", 15), anchors.position("a.txt", "RIGHT", 18)]
      assert_nil anchors.position("a.txt", "RIGHT", 10)
      # " a" (1) · -b (2) · \ No newline (3) · +c (4)
      assert_equal [1, 2, 4], [anchors.position("c.txt", "RIGHT", 1), anchors.position("c.txt", "LEFT", 2),
                               anchors.position("c.txt", "RIGHT", 2)]
      assert_equal [1, "bye"], [anchors.position("gone.txt", "LEFT", 1), anchors.text("gone.txt", "LEFT", 1)]
      assert_nil anchors.position("gone.txt", "RIGHT", 1)
    end
  end

  def test_a_later_commit_is_validated_against_the_base_not_its_parent
    with_commits do |repo, base, _x, y|
      anchors = Quartermaster::ReviewAnchors.new(repo, base: base, commit: y)

      assert anchors.commentable?("a.txt", "RIGHT", 5), "x's change is in base..y"
      assert anchors.commentable?("a.txt", "RIGHT", 10)
      assert_equal [*2..18], anchors.lines("a.txt", "RIGHT")
    end
  end

  def test_hunks_one_unchanged_line_apart_are_joined_as_on_github
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      commit(repo, "a.txt", LINES)
      commit(repo, "a.txt", LINES.sub("line 5\n", "line five\n").sub("line 13\n", "line thirteen\n"))

      anchors = Quartermaster::ReviewAnchors.new(repo, base: "HEAD~1", commit: "HEAD")

      assert_equal [*2..16], anchors.lines("a.txt", "RIGHT"), "line 9, between the two hunks, takes a comment"
      assert_equal 1, anchors.file("a.txt")["hunks"].size
      assert_equal 9, anchors.position("a.txt", "RIGHT", 9)
    end
  end

  def test_a_draft_is_anchorable_on_its_lines_with_their_text_and_says_why_not
    with_commits do |repo, base, x, y|
      anchors = Quartermaster::ReviewAnchors.new(repo, base: base, commit: y)
      draft = { "path" => "a.txt", "side" => "new", "repo" => "acme/widgets", "number" => 7 }

      assert anchors.anchorable?("a.txt", "new", 10, "line ten")
      refute anchors.anchorable?("a.txt", "new", 10, "line 10"), "the line moved on"
      refute anchors.anchorable?("a.txt", "RIGHT", 1, "line 1")
      assert anchors.anchorable?("a.txt", "old", 10, "line 10")
      refute anchors.anchorable?("a.txt", "old", 10, "line 10", view_base: x), "numbered by the selection, not the base"

      assert_nil anchors.refusal(draft.merge("line" => 5, "code" => "line five"))
      assert_match(/GitHub can't take a comment on a\.txt:1 at widgets#7 @#{y[0, 7]}/,
                   anchors.refusal(draft.merge("line" => 5, "start_line" => 1, "code" => "line 1\nline five")))
      assert_nil anchors.refusal(draft.merge("line" => 1, "code" => "line 1", "subject" => "file"))
      assert_match(/missing\.txt isn't in the diff/, anchors.refusal(draft.merge("path" => "missing.txt", "subject" => "file")))

      stored = draft.merge("base" => base, "commit" => y, "side" => "old", "line" => 10, "code" => "line 10")
      assert_nil Quartermaster::ReviewAnchors.refusal(repo, stored)
      assert_match(/removed line of the selected commits/, Quartermaster::ReviewAnchors.refusal(repo, stored.merge("range" => y[0, 7])))
      assert_match(/doesn't know its PR's base/, Quartermaster::ReviewAnchors.refusal(repo, stored.except("base")))
    end
  end

  def test_a_range_stays_inside_one_hunk_of_the_commits_diff
    with_commits do |repo, base, x, _y|
      anchors = Quartermaster::ReviewAnchors.new(repo, base: base, commit: x)
      range = { "path" => "a.txt", "side" => "new", "start_side" => "new", "repo" => "acme/widgets", "number" => 7 }

      assert_nil anchors.refusal(range.merge("start_line" => 3, "line" => 7, "code" => "line 3\nline 7"))
      assert_match(/a\.txt:5-15 spans two hunks of widgets#7/,
                   anchors.refusal(range.merge("start_line" => 5, "line" => 15, "code" => "line five\nline fifteen")))
    end
  end

  def test_an_unknown_commit_or_unrelated_base_is_refused
    with_commits do |repo, _base, _x, _y|
      assert_raises(ArgumentError) { Quartermaster::ReviewAnchors.new(repo, base: "main", commit: "deadbeef") }
      assert_raises(ArgumentError) { Quartermaster::ReviewAnchors.new(repo, base: "nope", commit: "HEAD") }
    end
  end
end
