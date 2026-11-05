# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/diff_pane_test.rb`).
require_relative "test_helper"

class UnifiedDiffTest < Minitest::Test
  def test_numbers_every_line_and_counts_the_stats
    text = <<~DIFF
      diff --git a/lib/a.rb b/lib/a.rb
      index 1..2 100644
      --- a/lib/a.rb
      +++ b/lib/a.rb
      @@ -1,3 +1,3 @@ def x
       one
      --- a line that starts with dashes
      +++ a line that starts with pluses
       three
      \\ No newline at end of file
    DIFF
    file = Quartermaster::UnifiedDiff.parse(text).first

    assert_equal ["lib/a.rb", "modified", 1, 1], file.values_at("path", "status", "additions", "deletions")
    lines = file["hunks"].first["lines"]
    assert_equal [[" ", 1, 1, "one"], ["-", 2, nil, "-- a line that starts with dashes"],
                  ["+", nil, 2, "++ a line that starts with pluses"], [" ", 3, 3, "three"]],
                 lines.map { |l| l.values_at("t", "o", "n", "s") }
    assert_equal "@@ -1,3 +1,3 @@ def x", file["hunks"].first["header"]
  end

  def test_reads_added_deleted_renamed_and_binary_files
    text = <<~DIFF
      diff --git a/new.txt b/new.txt
      new file mode 100644
      --- /dev/null
      +++ b/new.txt
      @@ -0,0 +1 @@
      +hi
      diff --git a/gone.txt b/gone.txt
      deleted file mode 100644
      --- a/gone.txt
      +++ /dev/null
      @@ -1 +0,0 @@
      -bye
      diff --git a/old name.txt b/new name.txt
      similarity index 100%
      rename from old name.txt
      rename to new name.txt
      diff --git a/logo.png b/logo.png
      Binary files a/logo.png and b/logo.png differ
    DIFF
    files = Quartermaster::UnifiedDiff.parse(text)

    assert_equal [["new.txt", "added", 1, 0], ["gone.txt", "deleted", 0, 1], ["new name.txt", "renamed", 0, 0],
                  ["logo.png", "modified", 0, 0]],
                 files.map { |f| f.values_at("path", "status", "additions", "deletions") }
    assert_equal "old name.txt", files[2]["oldPath"]
    assert files[3]["binary"]
  end

  def test_past_the_line_budget_files_keep_their_stats_but_lose_their_lines
    text = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,3 @@\n+1\n+2\n+3\n"
    parser = Quartermaster::UnifiedDiff.new(2)
    file = parser.parse(text).first

    assert_equal 3, file["additions"]
    assert_equal 2, file["hunks"].first["lines"].size
    assert file["truncated"]
    assert parser.truncated
  end
end

class BranchDiffTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def with_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      commit(repo, "base.txt", "base\n")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)
      yield repo
    end
  end

  def commit(path, file, content)
    File.write(File.join(path, file), content)
    system("git", "-C", path, "add", file)
    system("git", "-C", path, *GIT_ID, "commit", "-q", "-m", "change #{file}")
  end

  def branch_diff(item, tmux: FakeTmux.new, **options)
    Quartermaster::BranchDiff.new(tmux: tmux).call(item, **options)
  end

  def paths(result) = result["files"].map { |f| f["path"] }

  def test_shows_the_branch_against_its_trunk_merge_base_with_uncommitted_and_untracked_work
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "committed.txt", "one\n")
      commit(repo, "trunk-only.txt", "later on main\n")
      File.write(File.join(wt, "base.txt"), "base\nedited\n")
      File.write(File.join(wt, "untracked.txt"), "new\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item)

      assert_equal ["feature", wt], result.values_at("branch", "path")
      assert_equal %w[main trunk], result["base"].values_at("ref", "kind")
      assert_equal %w[base.txt committed.txt untracked.txt], paths(result).sort
      untracked = result["files"].find { |f| f["path"] == "untracked.txt" }
      assert_equal ["added", 1], untracked.values_at("status", "additions")
      assert_equal [["+", nil, 2, "edited"]],
                   result["files"].find { |f| f["path"] == "base.txt" }["hunks"].first["lines"]
                                  .select { |l| l["t"] == "+" }.map { |l| l.values_at("t", "o", "n", "s") }
    end
  end

  def test_uncommitted_scope_leaves_out_what_the_branch_committed
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "committed.txt", "one\n")
      File.write(File.join(wt, "base.txt"), "changed\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item, scope: "uncommitted")

      assert_equal "uncommitted", result["scope"]
      assert_equal ["base.txt"], paths(result)
      assert_raises(ArgumentError) { branch_diff(item, scope: "everything") }
    end
  end

  def sha_of(path, rev) = `git -C #{path} rev-parse #{rev}`.strip

  def with_commit_cap(cap)
    original = Quartermaster::BranchDiff::MAX_COMMITS
    Quartermaster::BranchDiff.send(:remove_const, :MAX_COMMITS)
    Quartermaster::BranchDiff.const_set(:MAX_COMMITS, cap)
    yield
  ensure
    Quartermaster::BranchDiff.send(:remove_const, :MAX_COMMITS)
    Quartermaster::BranchDiff.const_set(:MAX_COMMITS, original)
  end

  def test_commits_scope_is_committed_work_only_with_the_branchs_commits_oldest_first
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "one.txt", "1\n")
      commit(wt, "two.txt", "2\n")
      commit(repo, "trunk-only.txt", "later on main\n")
      File.write(File.join(wt, "base.txt"), "edited\n")
      File.write(File.join(wt, "untracked.txt"), "new\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item, scope: "commits")

      assert_equal ["commits", "main"], [result["scope"], result["base"]["ref"]]
      assert_equal %w[one.txt two.txt], paths(result).sort
      assert_equal ["change one.txt", "change two.txt"], result["commits"].map { |c| c["subject"] }
      assert_equal [sha_of(wt, "HEAD~1"), sha_of(wt, "HEAD")], result["commits"].map { |c| c["sha"] }
      assert_equal [2, nil], result.values_at("commitCount", "range")
      assert_match(/\A\d{4}-\d\d-\d\dT/, result["commits"].first["time"])
      assert_equal [[1, 0], [1, 0]], result["commits"].map { |c| c.values_at("add", "del") }
      assert_nil branch_diff(item)["commits"]
    end
  end

  def test_every_scope_names_its_old_side_as_a_full_sha
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "one.txt", "1\n")
      commit(repo, "trunk-only.txt", "later on main\n")
      File.write(File.join(wt, "base.txt"), "edited\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      fork = sha_of(wt, "HEAD~1")

      assert_equal fork, branch_diff(item)["oldRev"], "branch: the base"
      assert_equal fork, branch_diff(item, scope: "commits")["oldRev"], "commits: the base"
      assert_equal sha_of(wt, "HEAD"), branch_diff(item, scope: "uncommitted")["oldRev"], "uncommitted: HEAD"
    end
  end

  def file_at(slug, rev, path)
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    query = URI.encode_www_form("rev" => rev, "path" => path)
    JSON.parse(gui.respond("GET", "/api/diff-file/#{slug}?#{query}", ok_host, "")[2])
  end

  def test_the_diff_file_route_serves_a_file_at_a_revision_as_lines
    with_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "dir"))
      commit(repo, "dir/notes.txt", "")
      commit(repo, "dir/notes.txt", "first\nsécond\n\nlast")
      old = sha_of(repo, "HEAD")
      commit(repo, "dir/notes.txt", "rewritten\n")
      File.binwrite(File.join(repo, "bad.txt"), "ok\n\xff\xfe\n".b)
      system("git", "-C", repo, "add", "bad.txt")
      system("git", "-C", repo, *GIT_ID, "commit", "-q", "-m", "bad bytes")
      Quartermaster::WorkItem.create("Feat", project: "Qm")

      reply = file_at("feat", old, "dir/notes.txt")
      short = file_at("feat", old[0, 8], "dir/notes.txt")
      tree = file_at("feat", sha_of(repo, "#{old}^{tree}"), "dir/notes.txt")

      assert_equal({ "ok" => true, "lines" => ["first", "sécond", "", "last"], "truncated" => false }, reply)
      assert_equal reply, short, "an abbreviated sha works too"
      assert_equal reply, tree, "a tree sha (a prompt snapshot) works like a commit"
      assert_equal ["rewritten"], file_at("feat", sha_of(repo, "HEAD~1"), "dir/notes.txt")["lines"]
      assert_equal ["ok", "??"], file_at("feat", sha_of(repo, "HEAD"), "bad.txt")["lines"], "invalid bytes scrubbed"
      assert_equal [], file_at("feat", sha_of(repo, "HEAD~3"), "dir/notes.txt")["lines"], "an empty file has no lines"
      commit(repo, "crlf.txt", "one\r\ntwo\r\n")
      assert_equal %w[one two], file_at("feat", sha_of(repo, "HEAD"), "crlf.txt")["lines"],
                   "line ends dropped as the diff parser drops them"
    end
  end

  def test_the_diff_file_route_refuses_anything_but_a_sha_and_a_path_that_exists
    with_repo do |repo|
      Quartermaster::WorkItem.create("Feat", project: "Qm")
      head = sha_of(repo, "HEAD")

      ["HEAD", "main", "--output=x", "#{head[0, 7]}~1", "abc", ""].each do |bad|
        reply = file_at("feat", bad, "base.txt")
        assert_equal false, reply["ok"], bad
        assert_match(/not a sha/, reply["error"])
      end
      assert_match(/no path/, file_at("feat", head, "")["error"])
      missing = file_at("feat", head, "nope.txt")
      assert_equal false, missing["ok"]
      assert_match(/not a file/, missing["error"])
      assert_equal false, file_at("feat", "0" * 40, "base.txt")["ok"], "an unknown object"
      assert_equal false, file_at("feat", head, ".")["ok"], "a tree is not a file"
      assert_equal false, file_at("ghost", head, "base.txt")["ok"], "an unknown item"
    end
  end

  def test_a_file_past_the_caps_comes_back_cut_at_a_line_and_flagged
    with_repo do |repo|
      commit(repo, "long.txt", (1..50).map { |i| "line #{i}\n" }.join)
      head = sha_of(repo, "HEAD")
      reader = Quartermaster::FileAtRevision.new(repo)

      with_const(Quartermaster::FileAtRevision, :MAX_LINES, 10) do
        assert_equal [(1..10).map { |i| "line #{i}" }, true], reader.call(head, "long.txt").values_at("lines", "truncated")
      end
      with_const(Quartermaster::FileAtRevision, :MAX_BYTES, 20) do
        assert_equal [["line 1", "line 2"], true], reader.call(head, "long.txt").values_at("lines", "truncated"),
                     "cut at the last whole line under the byte cap"
      end
      assert_equal [50, false], reader.call(head, "long.txt").then { |r| [r["lines"].size, r["truncated"]] }
    end
  end

  def with_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end

  def test_the_commit_list_keeps_the_newest_commits_past_the_cap
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      3.times { |i| commit(wt, "f#{i}.txt", "#{i}\n") }
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = with_commit_cap(2) { branch_diff(item, scope: "commits") }

      assert_equal ["change f1.txt", "change f2.txt"], result["commits"].map { |c| c["subject"] }
      assert_equal 3, result["commitCount"]
    end
  end

  def test_a_selected_commit_or_run_of_commits_diffs_only_that
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      %w[a b c].each { |f| commit(wt, "#{f}.txt", "#{f}\n") }
      File.write(File.join(wt, "untracked.txt"), "new\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      a, b, c = %w[HEAD~2 HEAD~1 HEAD].map { |rev| sha_of(wt, rev) }

      single = branch_diff(item, scope: "commits", from: b[0, 7], to: b[0, 7])
      alone = branch_diff(item, scope: "commits", to: c)
      run = branch_diff(item, scope: "commits", from: a, to: b[0, 9])

      assert_equal [["b.txt"], b, b, b[0, 7]], [paths(single), *single["range"].values_at("from", "to", "label")]
      assert_equal ["c.txt"], paths(alone)
      assert_equal %w[a.txt b.txt], paths(run).sort
      assert_equal "#{a[0, 7]}..#{b[0, 7]}", run["range"]["label"]
      assert_equal 3, run["commits"].size
      assert_equal [a, sha_of(wt, "HEAD~3")], [single["oldRev"], run["oldRev"]], "a run's old side is its first commit's parent"
    end
  end

  def test_a_selection_carries_its_commits_full_messages_oldest_first
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "a.txt", "a\n")
      File.write(File.join(wt, "b.txt"), "b\n")
      system("git", "-C", wt, "add", "b.txt")
      system("git", "-C", wt, *GIT_ID, "commit", "-q", "-m", "Add b", "-m", "Why b:\n  indented detail\n\nlast paragraph")
      commit(wt, "c.txt", "c\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      a, b, c = %w[HEAD~2 HEAD~1 HEAD].map { |rev| sha_of(wt, rev) }

      single = branch_diff(item, scope: "commits", from: b[0, 7])
      run = branch_diff(item, scope: "commits", from: a, to: c)

      assert_equal 1, single["messages"].size
      message = single["messages"].first
      assert_equal [b, b[0, 7]], [message["sha"], message["short"][0, 7]]
      assert_equal "Add b\n\nWhy b:\n  indented detail\n\nlast paragraph", message["body"]
      assert_match(/\A\d{4}-\d\d-\d\dT/, message["date"])
      refute_empty message["author"]
      assert_equal [a, b, c], run["messages"].map { |m| m["sha"] }
      assert_equal ["change a.txt", "Add b", "change c.txt"], run["messages"].map { |m| m["body"].lines.first.chomp }
      assert_equal [], branch_diff(item, scope: "commits")["messages"], "no selection, no messages"
      page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
      ["function renderDiffMessages(", "(d.messages || []).length", "box.open = commitMessagesOpen",
       '"pre", "d-msg-body"', ".d-msg-body {"].each { |seam| assert_includes page, seam }
    end
  end

  def test_a_single_commit_offers_the_next_commit_after_its_last_file
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    ["function renderDiffNextCommit(", "sel[0] !== sel[1] || sel[1] + 1 >= d.commits.length",
     "selectDiffCommits(c.sha, c.sha, c.sha);", '$("#diff-body").scrollTop = 0;',
     "Next commit →", ".diff-next-commit {"].each { |seam| assert_includes page, seam }
    assert_equal 2, page.scan("const next = renderDiffNextCommit(d);").size, "after the files, and under an empty commit"
  end

  def page_function(page, name)
    page[/^(?:async )?function #{name}\(.*?^}$/m] or flunk("no function #{name} on the page")
  end

  def test_a_load_keeps_the_old_diff_and_updates_only_the_bar
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    loading = page_function(page, "showDiffLoading")

    assert_includes page, "if (diffView.loading) showDiffLoading();"
    assert_includes loading, "renderDiffBar();"
    assert_includes loading, "!diffView.data || diffView.rendered !== diffView.data", "nothing shown or an error: the body says loading"
    assert_includes page, 'body.classList.toggle("d-stale", diffView.loading && !!diffView.data);'
    assert_includes page, ".diff-body.d-stale {"
  end

  def test_an_item_with_chains_gets_the_stack_strip_instead_of_the_branch_select
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    bar = page_function(page, "renderDiffBar")
    strip = page_function(page, "renderDiffStrip")
    menu = page_function(page, "diffSwitcherMenu")

    assert_includes bar, "if (itemChains(stacked).length) top.appendChild(renderDiffStrip(d, stacked));\n  else if (d && d.branches.length) {"
    assert_includes strip, "if (chains.length > 1 || extras.length) strip.appendChild(diffStripSwitcher(d, it, found, extras));",
                    "a switcher only when there is more than the one chain to pick from"
    assert_includes strip, "const extras = d ? d.branches.filter(b => !b.branch || !known.has(b.branch)) : [];",
                    "the chat's detached folder and other branches the old select offered stay reachable"
    assert_includes strip, "const folded = chain.layers.map((l, i) => l.merged && i !== at);", "merged layers fold, never the selected one"
    assert_includes strip, "chip.onclick = () => restackStack(it, chainTop(chain));", "the restack chip calls the restack action"
    assert_includes menu, "setSelectedBranch(it.slug, branch);", "a pick is the item's one selection, with its checkout fallback"
    assert_includes page_function(page, "diffStripCrumb"), "if (!isSel) setSelectedBranch(it.slug, l.branch);"
    assert_includes page, '<script src="/assets/js/diff-stack.js"></script>'
    assert_includes page, ".diff-strip { display: flex; align-items: center; flex-wrap: wrap;", "the strip wraps instead of widening the pane"
  end

  def test_a_stack_span_is_part_of_the_diff_key_and_params_under_branch_and_commits_only
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)

    assert_includes page_function(page, "diffKey"), '|${diffSpanBase(c) || ""}`', "a span is cached apart from its upper layer alone"
    assert_includes page_function(page, "diffParams"), 'if (diffSpanBase(choice)) params.set("base", diffSpanBase(choice));'
    assert_includes page, 'const diffSpanBase = choice => (choice.scope === "commits" || choice.scope === "branch") && choice.base || null;'
    assert_includes page_function(page, "diffCommitChoice"), "{ scope, rebase: choice.rebase, base: choice.base }",
                    "Show all within a span keeps the span"
    pick = page_function(page, "pickDiffLayer")
    assert_includes pick, "const base = low === 0 ? d.layerTrunk : d.layers[low - 1].branch;", "the lower layer's parent, the trunk for the bottom"
    assert_includes pick, 'diffChoice[slug] = { scope: "commits", base, rebase: choice.rebase };', "GitHub can't show a span: always Commits"
    assert_includes pick, "setSelectedBranch(slug, branch);", "a plain header click selects its layer"
  end

  def test_the_commit_list_is_layered_for_a_stacked_branch_with_stale_commits_dimmed
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    list = page_function(page, "renderLayeredCommits")

    assert_includes page, "if (diffHasCommitList(d.scope)) body.appendChild(stacked ? renderLayeredCommits(d, stacked) : renderDiffCommits(d));",
                    "a loose branch keeps the plain list"
    assert_includes list, "d.layers.map((l, i) => i).reverse().forEach(i => {", "top layer first"
    assert_includes list, "const folds = !diffLayersOpen.has(key) && rows.length > DIFF_LAYER_FOLD;"
    assert_includes list, "rows.filter((r, n) => n < DIFF_LAYER_SHOWN || inSel(r))", "a folded layer keeps its selected commits in view"
    assert_includes page, "const DIFF_LAYER_FOLD = 10;"
    assert_includes page, "const DIFF_LAYER_SHOWN = 6;"
    commit = page_function(page, "diffLayerCommit")
    assert_includes commit, "if (r.k !== null) { pickDiffCommit(d, r.k, e.shiftKey); return; }", "the loaded diff's commits pick as before"
    assert_includes commit, '(also ? " stale" : "")'
    assert_includes commit, "also in ${esc(diffLayerName(d, also))}"
    assert_includes page, ".d-layer-commit.stale .d-sha, .d-layer-commit.stale .d-subject"
  end

  def test_file_headers_get_number_only_layer_circles_named_by_branch
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)

    assert_includes page_function(page, "renderDiffFile"), '<span class="d-path">${name}</span>${diffFileLayerCircles(f)}'
    circles = page_function(page, "diffFileLayerCircles")
    assert_includes circles, "const at = d && d.fileLayers && d.layers && d.fileLayers[f.path];"
    assert_includes circles, 'title="${esc(layer.branch)}">${circled(i + 1)}</span>'
  end

  def test_a_branch_without_a_checkout_is_labelled_and_offers_only_the_scopes_that_need_none
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    bar = page_function(page, "renderDiffBar")

    assert_includes bar, '(b.chat ? " · chat" : b.checkout === false ? " · not checked out" : "")'
    assert_includes page, 'const diffNeedsCheckout = scope => scope === "uncommitted" || scope === "prompt";'
    assert_includes bar, "if (d && d.checkout === false && diffNeedsCheckout(k)) {\n      b.disabled = true;"
    assert_includes bar, "b.title = `${d.branch} is not checked out anywhere — needs a checkout`;"
    assert_includes bar, "pick.onchange = () => setSelectedBranch(chatSlug, pick.value || null);"
    select = page_function(page, "setSelectedBranch")
    assert_includes select, 'diffNeedsCheckout(choice.scope) && !branchHasCheckout(slug, branch) ? "branch" : choice.scope',
                    "picking such a branch under Uncommitted or Since prompt falls back to Branch"
    assert_includes page_function(page, "branchHasCheckout"), "if (entry.branch !== undefined) return entry.checkout !== false;"
    assert_includes bar, 'd.scope === "branch" && d.checkout !== false && diffHasUncommittedLines(d)', "no uncommitted legend"
    assert_includes bar, "info.title = d.checkout === false ?", "the bar's tooltip names the ref, not the root's folder"
    assert_includes page, ".diff-scope button:disabled {"
  end

  def test_selected_commits_are_kept_and_the_next_one_prefetched_until_a_reload_or_turn_end
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    load = page_function(page, "loadDiff")
    prefetch = page_function(page, "prefetchNextDiff")

    assert_includes load, "if (refetch || diffView.slug !== slug) diffCache.clear();", "↻, a turn's end and another chat drop what was kept"
    assert_includes page, "if (diffOpen) { diffView.key = null; diffCache.clear(); diffContextFiles.clear(); }", "so does opening the pane"
    assert_includes load, "else if (key === diffView.key) diffCache.delete(key);", "a reload of the shown diff (draft placed, review posted) asks the server"
    assert_includes load, "const kept = diffCacheGet(key);"
    assert_includes load, "if (diffKeepable(choice)) diffCachePut(key, request);"
    assert_includes page, "const diffKeepable = choice => !!choice.from && diffHasCommitList(choice.scope);"
    assert_includes page, "while (diffCache.size > DIFF_CACHE_SIZE)"
    assert_includes page, "if (Date.now() - kept.at > DIFF_CACHE_MS) return null;"
    assert_includes load, "if (res.ok) prefetchNextDiff();"
    assert_includes prefetch, "const next = diffNextCommit(diffView.data);"
    assert_includes prefetch, "diffCachePut(key, fetchDiff(slug, diffParams(slug, choice)))"
    refute_match(/fresh|loadPrThreads/, prefetch, "a prefetch never refetches the PR or loads its threads")
    refute_includes page_function(page, "diffParams"), "fresh", "fresh=1 is loadDiff's alone"
    assert_includes page, "const c = diffNextCommit(d);", "the button and the prefetch agree on what is next"
  end

  def test_highlighting_is_kept_by_file_digest
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    lit = page_function(page, "diffFileHighlights")

    assert_includes page, "diffHighlights.set(f, diffFileHighlights(f))"
    assert_includes lit, "diffHighlightsByDigest.get(f.digest)"
    assert_includes lit, "if (f.digest && window.hljs)", "no verdict kept before highlight.js loads"
    assert_includes lit, "while (diffHighlightsByDigest.size > DIFF_HIGHLIGHT_FILES)"
  end

  def test_the_page_expands_context_from_the_old_file_without_touching_the_hunks
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)
    context = page_function(page, "diffContextFor")
    gap = page_function(page, "renderDiffGap")
    expander = page_function(page, "renderDiffExpander")
    line = page_function(page, "renderDiffExpandedLine")
    fetch = page_function(page, "fetchDiffContextFile")

    assert_includes context, 'f.status === "added" || f.status === "deleted"', "added and deleted files show whole already"
    assert_includes context, "const oldPath = f.oldPath || f.path;", "a renamed file's old side is its old path"
    assert_includes context, "key: `${rev}|${oldPath}|${f.path}`"
    assert_includes page, "if (context) renderDiffGap(tbody, f, context, context.gaps[i]);", "fillRows re-applies what is expanded"
    assert_includes page, "if (!f.truncated) gaps.push(", "no expander after a hunk the line limit cut"
    assert_includes gap, "Math.min(gap.to, ctx.file.lines.length)", "the trailing expander vanishes once the file is exhausted"
    assert_includes gap, "k !== Infinity", "the rest of a file not fetched yet is one expander, not an endless loop"
    assert_includes expander, "if (size <= DIFF_EXPAND_STEP)"
    assert_includes expander, "e.stopPropagation();", "an expand never folds the file"
    assert_includes page, "const DIFF_EXPAND_STEP = 20;"
    assert_includes line, 'tr.classList.add("d-expanded");'
    assert_includes line, "if (diffPrScope()) line.gh = false;", "GitHub takes no comment on an expanded line"
    assert_includes line, "renderDiffCommentRow(address)", "a draft on an expanded line shows with it"
    assert_includes fetch, "/api/diff-file/${encodeURIComponent(diffView.slug)}?${new URLSearchParams({ rev, path })}"
    assert_includes fetch, "while (diffContextFiles.size > DIFF_CONTEXT_FILES)"
    assert_includes page_function(page, "loadDiff"), "if (fresh || diffView.slug !== slug) diffContextFiles.clear();"
    assert_includes page_function(page, "diffContextHighlight"), "splitHighlightedLines(hljs.highlight(file.lines.join(\"\\n\")"
    assert_includes page, "if (line.lit != null) return line.lit;"
    refute_match(/f\.hunks\.(push|splice|unshift)|h\.lines\.(push|splice|unshift)/, page, "expanding never mutates the hunks")
    assert_includes page_function(page, "diffRangeAddress"), 'r.classList.contains("d-expand")', "a range can't span an expander"
    refute_includes page_function(page, "refillDiffFile"), "if (!box.open) return;", "a file folded while its context loads still refills: an open-rendered one never refills on reopen"
    [".diff-table tr.d-expand td {", ".d-expand-btn {", ".diff-table tr.d-expanded {"].each { |seam| assert_includes page, seam }
  end

  def test_refuses_shas_that_are_malformed_outside_the_branch_or_out_of_order
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      %w[a b].each { |f| commit(wt, "#{f}.txt", "#{f}\n") }
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      trunk = sha_of(repo, "main")

      ["HEAD", "main", "abc", "#{sha_of(wt, "HEAD")[0, 7]}~1", "--output=x", trunk, "deadbeef"].each do |bad|
        assert_raises(ArgumentError, bad) { branch_diff(item, scope: "commits", from: bad, to: sha_of(wt, "HEAD")) }
      end
      error = assert_raises(ArgumentError) { branch_diff(item, scope: "commits", from: sha_of(wt, "HEAD"), to: sha_of(wt, "HEAD~1")) }
      assert_match(/does not come before/, error.message)
    end
  end

  def test_a_root_commit_in_the_branch_diffs_against_the_empty_tree
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      system("git", "-C", wt, "checkout", "-q", "--orphan", "other")
      system("git", "-C", wt, "rm", "-rq", "--cached", ".")
      FileUtils.rm_f(File.join(wt, "base.txt"))
      commit(wt, "root.txt", "root\n")
      root = sha_of(wt, "HEAD")
      system("git", "-C", wt, "checkout", "-q", "feature")
      system("git", "-C", wt, *GIT_ID, "merge", "-q", "--allow-unrelated-histories", "-m", "join", "other")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item, scope: "commits", from: root, to: root)

      assert_equal ["root.txt"], paths(result)
      assert_equal "added", result["files"].first["status"]
    end
  end

  def test_a_stacked_branch_diffs_against_its_parent
    with_repo do |repo|
      lower = add_worktree(repo, "lower", "wt-lower")
      commit(lower, "lower.txt", "1\n")
      system("git", "-C", repo, "branch", "upper", "lower")
      upper = File.join(File.dirname(repo), "wt-upper")
      system("git", "-C", repo, "worktree", "add", "-q", upper, "upper")
      commit(upper, "upper.txt", "2\n")
      write_stack(repo, %w[lower upper])
      item = Quartermaster::WorkItem.create("Stack", project: "Qm", branch: "upper")

      result = branch_diff(item, branch: "upper")
      bottom = branch_diff(item, branch: "lower")

      assert_equal %w[lower stack], result["base"].values_at("ref", "kind")
      assert_equal ["upper.txt"], paths(result)
      assert_equal %w[main trunk], bottom["base"].values_at("ref", "kind")
      assert_equal ["lower.txt"], paths(bottom)
    end
  end

  # a → b → c, one file each; c checked out, a and b refs only.
  def with_three_layer_stack
    with_repo do |repo|
      system("git", "-C", repo, "branch", "a")
      wt = add_worktree(repo, "c", "wt-c")
      system("git", "-C", wt, "checkout", "-q", "a")
      commit(wt, "a.txt", "a\n")
      system("git", "-C", wt, "checkout", "-q", "-b", "b")
      commit(wt, "b.txt", "b\n")
      system("git", "-C", wt, "checkout", "-q", "c")
      system("git", "-C", wt, "reset", "-q", "--hard", "b")
      commit(wt, "c.txt", "c\n")
      write_stack(repo, %w[a b c])
      item = Quartermaster::WorkItem.create("Stack", project: "Qm", branch: "c")
      yield repo, wt, item
    end
  end

  def test_a_base_below_in_the_stack_diffs_the_span_and_anything_else_is_ignored
    with_three_layer_stack do |_repo, wt, item|
      span = branch_diff(item, branch: "c", base: "a")
      from_trunk = branch_diff(item, branch: "c", scope: "commits", base: "main")
      commits = branch_diff(item, branch: "c", scope: "commits", base: "a")

      assert_equal ["a", "stack-span", "a", sha_of(wt, "a")], span["base"].values_at("ref", "kind", "branch", "sha")
      assert_equal %w[b.txt c.txt], paths(span).sort
      assert_equal %w[a.txt b.txt c.txt], paths(from_trunk).sort
      assert_equal %w[main stack-span], from_trunk["base"].values_at("ref", "kind")
      assert_equal ["change b.txt", "change c.txt"], commits["commits"].map { |c| c["subject"] }
      %w[c unrelated origin/a].each do |ignored|
        result = branch_diff(item, branch: "c", base: ignored)
        assert_equal %w[b stack], result["base"].values_at("ref", "kind"), ignored
        assert_equal ["c.txt"], paths(result)
      end
      assert_equal %w[main trunk], branch_diff(item, branch: "a", base: "b")["base"].values_at("ref", "kind")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      route = JSON.parse(gui.respond("GET", "/api/diff/#{item.slug}?branch=c&base=a", ok_host, "")[2])
      assert_equal %w[a stack-span], route["base"].values_at("ref", "kind")
    end
  end

  def test_a_stacked_branch_carries_every_layer_with_stale_commits_and_file_layers
    with_three_layer_stack do |repo, wt, item|
      # b amended (same patch, new sha) and c not restacked; a squash-merged.
      system("git", "-C", wt, "checkout", "-q", "b")
      system("git", "-C", wt, *GIT_ID, "commit", "-q", "--amend", "-m", "b, reworded")
      system("git", "-C", wt, "checkout", "-q", "c")
      system("git", "-C", repo, "merge", "-q", "--squash", "a", out: File::NULL)
      system("git", "-C", repo, *GIT_ID, "commit", "-q", "-m", "a (squashed)")
      stale_b = sha_of(wt, "c~1")

      result = branch_diff(item, branch: "c", scope: "commits")

      assert_equal "main", result["layerTrunk"]
      assert_equal [["a", 1, 1, 0], ["b", 1, 1, 0], ["c", 2, 2, 0]],
                   result["layers"].map { |l| l.values_at("branch", "n", "add", "del") }
      assert_equal [["change a.txt", "main"]], result["layers"][0]["commits"].map { |c| c.values_at("subject", "alsoIn") }
      assert_equal [["b, reworded", nil]], result["layers"][1]["commits"].map { |c| c.values_at("subject", "alsoIn") }
      assert_equal [[sha_of(wt, "c"), "change c.txt", nil], [stale_b, "change b.txt", "b"]],
                   result["layers"][2]["commits"].map { |c| c.values_at("sha", "subject", "alsoIn") }
      assert_equal({ "a.txt" => [0], "b.txt" => [1, 2], "c.txt" => [2] }, result["fileLayers"])
      assert_equal %w[b.txt c.txt], paths(result).sort, "only the selected layer's diff is built"
      refute branch_diff(item, branch: "c", scope: "uncommitted").key?("layers")
    end
  end

  def test_layers_are_cached_on_the_tip_shas
    with_three_layer_stack do |repo, wt, _item|
      calls = []
      git = lambda do |path, *args|
        calls << args.first
        out, _err, status = Open3.capture3("git", "-C", path, *args)
        status.success? ? out : nil
      end
      layers = Quartermaster::StackLayers.new(repo, git: git)

      first = layers.call("b")
      spawned = calls.size
      again = layers.call("b")

      assert_operator spawned, :>, 0
      assert_equal spawned, calls.size, "unchanged refs spawn no layer git"
      assert_equal first, again
      commit(wt, "c2.txt", "more\n")
      assert_equal 2, layers.call("a")["layers"][2]["n"]
      assert_operator calls.size, :>, spawned
      assert_nil layers.call("not-stacked")
    end
  end

  def test_defaults_to_the_chats_checkout_and_offers_the_linked_branches_with_worktrees
    with_repo do |repo|
      one = add_worktree(repo, "one", "wt-one")
      two = add_worktree(repo, "two", "wt-two")
      item = Quartermaster::WorkItem.create("Pick", project: "Qm", branch: "one")
      item.link_branch("two")
      item.link_branch("no-worktree")
      tmux = FakeTmux.new([item.slug])
      FileUtils.mkdir_p(File.join(one, "sub"))
      tmux.pane_paths[item.slug] = File.join(one, "sub")

      result = branch_diff(item, tmux: tmux)
      picked = branch_diff(item, tmux: tmux, branch: "two")

      assert_equal ["one", one], result.values_at("branch", "path")
      assert_equal [["one", one, true], ["two", two, false]],
                   result["branches"].map { |b| b.values_at("branch", "path", "chat") }
      assert_equal ["two", two], picked.values_at("branch", "path")
      assert_raises(ArgumentError) { branch_diff(item, tmux: tmux, branch: "no-worktree") }
    end
  end

  def test_defaults_to_the_newest_linked_issue_branch_over_the_chats_checkout
    with_repo do |repo|
      chat = add_worktree(repo, "chat-branch", "wt-chat")
      older = add_worktree(repo, "issue/1-older", "wt-older")
      add_worktree(repo, "issue/2-newer", "wt-newer")
      item = Quartermaster::WorkItem.create("Issues", project: "Qm", branch: "chat-branch")
      item.link_branch("issue/2-newer")
      item.link_branch("issue/1-older")
      item.link_branch("issue/3-no-worktree")
      tmux = FakeTmux.new([item.slug])
      tmux.pane_paths[item.slug] = chat

      result = branch_diff(item, tmux: tmux)

      assert_equal ["issue/1-older", older], result.values_at("branch", "path")
      assert_equal "chat-branch", result["branches"].first["branch"]
    end
  end

  # A branch with commits of its own that no worktree has checked out.
  def branch_without_worktree(repo, branch, file)
    system("git", "-C", repo, "checkout", "-q", "-b", branch)
    commit(repo, file, "on #{branch}\n")
    system("git", "-C", repo, "checkout", "-q", "main")
  end

  def test_a_linked_branch_without_a_worktree_diffs_from_its_ref_never_the_roots_working_tree
    with_repo do |repo|
      branch_without_worktree(repo, "feature", "feature.txt")
      commit(repo, "trunk-only.txt", "later on main\n")
      File.write(File.join(repo, "base.txt"), "base\ndirty in the root\n")
      File.write(File.join(repo, "untracked.txt"), "root only\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      tip = sha_of(repo, "feature")

      branch = branch_diff(item, branch: "feature")
      commits = branch_diff(item, branch: "feature", scope: "commits")

      assert_equal ["feature", repo, false], branch.values_at("branch", "path", "checkout")
      offered = branch["branches"].find { |b| b["branch"] == "feature" }
      assert_equal [repo, false, false, "feature"], offered.values_at("path", "chat", "checkout", "ref")
      assert_equal [true], branch["branches"].reject { |b| b["branch"] == "feature" }.map { |b| b["checkout"] }
      assert_equal %w[main trunk], branch["base"].values_at("ref", "kind")
      assert_equal ["feature.txt"], paths(branch)
      assert_equal sha_of(repo, "main~1"), branch["oldRev"]
      assert_nil branch["commits"]
      refute file_in(branch, "feature.txt")["hunks"].first["lines"].any? { |l| l["uncommitted"] }
      assert_equal [["feature.txt"], [tip], sha_of(repo, "main~1")],
                   [paths(commits), commits["commits"].map { |c| c["sha"] }, commits["oldRev"]]
      picked = branch_diff(item, branch: "feature", scope: "commits", from: tip[0, 7])
      assert_equal [tip, ["feature.txt"]], [picked["range"]["to"], paths(picked)]
      assert_equal "main", `git -C #{repo} symbolic-ref --short HEAD`.strip
      assert_equal "base\ndirty in the root\n", File.read(File.join(repo, "base.txt"))
    end
  end

  def test_uncommitted_and_since_prompt_are_refused_for_a_branch_without_a_checkout
    with_repo do |repo|
      branch_without_worktree(repo, "feature", "feature.txt")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      refused = assert_raises(ArgumentError) { branch_diff(item, branch: "feature", scope: "uncommitted") }
      prompt = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=prompt&branch=feature", ok_host, "")[2])
      route = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=uncommitted&branch=feature", ok_host, "")[2])

      message = "feature is not checked out anywhere: Uncommitted and Since prompt need a checkout"
      assert_equal message, refused.message
      assert_equal [false, message], prompt.values_at("ok", "error")
      assert_equal [false, message], route.values_at("ok", "error")
    end
  end

  def test_a_branch_only_on_origin_diffs_from_its_remote_ref
    with_repo do |repo|
      branch_without_worktree(repo, "pushed", "pushed.txt")
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/pushed", "pushed")
      system("git", "-C", repo, "branch", "-q", "-D", "pushed")
      item = Quartermaster::WorkItem.create("Pushed", project: "Qm", branch: "pushed")

      result = branch_diff(item, branch: "pushed", scope: "commits")

      assert_equal [false, "origin/pushed"], result["branches"].find { |b| b["branch"] == "pushed" }.values_at("checkout", "ref")
      assert_equal [["pushed.txt"], 1], [paths(result), result["commitCount"]]
    end
  end

  def test_a_tag_named_like_a_branch_without_a_worktree_does_not_shadow_it
    with_repo do |repo|
      branch_without_worktree(repo, "feature", "feature.txt")
      system("git", "-C", repo, "tag", "feature", "main")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item, branch: "feature", scope: "commits")

      assert_equal [["feature.txt"], [sha_of(repo, "refs/heads/feature")]], [paths(result), result["commits"].map { |c| c["sha"] }]
    end
  end

  def test_the_default_pick_prefers_a_checkout_and_falls_back_to_a_branch_without_one
    with_repo do |repo|
      wt = add_worktree(repo, "checked-out", "wt-checked-out")
      branch_without_worktree(repo, "issue/9-ref-only", "ref.txt")
      item = Quartermaster::WorkItem.create("Pick", project: "Qm", branch: "checked-out")
      item.link_branch("issue/9-ref-only")
      outside = FakeTmux.new([item.slug])
      outside.pane_paths[item.slug] = File.dirname(repo)

      result = branch_diff(item, tmux: outside)
      only_ref = Quartermaster::WorkItem.create("Ref only", project: "Qm", branch: "issue/9-ref-only")
      outside_too = FakeTmux.new([only_ref.slug])
      outside_too.pane_paths[only_ref.slug] = File.dirname(repo)
      fallback = branch_diff(only_ref, tmux: outside_too)

      assert_equal ["checked-out", wt, true], result.values_at("branch", "path", "checkout")
      assert_equal [["checked-out", true], ["issue/9-ref-only", false]],
                   result["branches"].map { |b| b.values_at("branch", "checkout") }
      assert_equal ["issue/9-ref-only", repo, false, ["ref.txt"]],
                   fallback.values_at("branch", "path", "checkout") + [paths(fallback)]
    end
  end

  def file_in(result, path) =result["files"].find { |f| f["path"] == path }

  # [sign, number, text] of each line marked uncommitted.
  def uncommitted_lines(file)
    file["hunks"].flat_map { |h| h["lines"] }.select { |l| l["uncommitted"] }
                 .map { |l| [l["t"], l["t"] == "-" ? l["o"] : l["n"], l["s"]] }
  end

  def test_the_branch_scope_marks_which_lines_and_files_are_not_committed_yet
    with_repo do |repo|
      letters = ("a".."l").to_a
      commit(repo, "mixed.txt", letters.map { "#{_1}\n" }.join)
      wt = add_worktree(repo, "feature", "wt-feature")
      # Committed: two lines on top (shifting what follows by one, net) and b removed.
      commit(wt, "mixed.txt", (%w[x1 x2] + letters - ["b"]).map { "#{_1}\n" }.join)
      commit(wt, "committed.txt", "one\n")
      # Uncommitted: k removed (base line 11, HEAD line 12) and y added at the end.
      File.write(File.join(wt, "mixed.txt"), (%w[x1 x2] + letters - %w[b k] + ["y"]).map { "#{_1}\n" }.join)
      File.write(File.join(wt, "base.txt"), "base\nedited\n")
      File.write(File.join(wt, "untracked.txt"), "new\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      result = branch_diff(item)

      mixed = file_in(result, "mixed.txt")
      assert_equal "mixed", mixed["commitStatus"]
      assert_equal [["-", 11, "k"], ["+", 13, "y"]], uncommitted_lines(mixed)
      changed = mixed["hunks"].flat_map { |h| h["lines"] }.reject { |l| l["t"] == " " }.map { |l| [l["t"], l["s"]] }
      assert_equal [["+", "x1"], ["+", "x2"], ["-", "b"], ["-", "k"], ["+", "y"]], changed
      refute mixed["hunks"].flat_map { |h| h["lines"] }.any? { |l| l["t"] == " " && l.key?("uncommitted") }
      assert_equal ["committed", []], file_in(result, "committed.txt").then { [_1["commitStatus"], uncommitted_lines(_1)] }
      assert_equal ["uncommitted", [["+", 2, "edited"]]], file_in(result, "base.txt").then { [_1["commitStatus"], uncommitted_lines(_1)] }
      assert_equal ["uncommitted", [["+", 1, "new"]]], file_in(result, "untracked.txt").then { [_1["commitStatus"], uncommitted_lines(_1)] }
      refute file_in(branch_diff(item, scope: "uncommitted"), "base.txt").key?("commitStatus")
      refute file_in(branch_diff(item, scope: "commits"), "mixed.txt").key?("commitStatus")
    end
  end

  def test_a_removed_line_follows_a_committed_rename_and_shift
    with_repo do |repo|
      lines = (1..12).map { "line #{_1}\n" }
      commit(repo, "old.txt", lines.join)
      wt = add_worktree(repo, "feature", "wt-feature")
      system("git", "-C", wt, "mv", "old.txt", "new.txt")
      File.write(File.join(wt, "new.txt"), (["top\n"] + lines).join)
      system("git", "-C", wt, "add", "new.txt")
      system("git", "-C", wt, *GIT_ID, "commit", "-q", "-m", "rename")
      # Base line 10 is HEAD line 11 of new.txt; only the working tree drops it.
      File.write(File.join(wt, "new.txt"), (["top\n"] + lines - ["line 10\n"]).join)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      file = file_in(branch_diff(item), "new.txt")

      assert_equal %w[renamed old.txt mixed], file.values_at("status", "oldPath", "commitStatus")
      assert_equal [["-", 10, "line 10"]], uncommitted_lines(file)
    end
  end

  def test_files_past_the_line_cap_get_no_line_marks_but_keep_a_file_status
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      File.write(File.join(wt, "base.txt"), "base\n#{(1..5).map { "n#{_1}\n" }.join}")
      original = Quartermaster::BranchDiff::MAX_LINES
      Quartermaster::BranchDiff.send(:remove_const, :MAX_LINES)
      Quartermaster::BranchDiff.const_set(:MAX_LINES, 3)
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      file = file_in(branch_diff(item), "base.txt")

      assert_equal [true, "uncommitted", []], [file["truncated"], file["commitStatus"], uncommitted_lines(file)]
    ensure
      Quartermaster::BranchDiff.send(:remove_const, :MAX_LINES)
      Quartermaster::BranchDiff.const_set(:MAX_LINES, original)
    end
  end

  def test_the_route_serves_the_diff_and_reports_failures
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      File.write(File.join(wt, "base.txt"), "changed\n")
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      reply = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=uncommitted", ok_host, "")[2])
      missing = JSON.parse(gui.respond("GET", "/api/diff/nope", ok_host, "")[2])
      bad_branch = JSON.parse(gui.respond("GET", "/api/diff/feat?branch=other", ok_host, "")[2])

      assert_equal [true, "feature", ["base.txt"]], [reply["ok"], reply["branch"], paths(reply)]
      assert_equal false, missing["ok"]
      assert_match(/not a linked branch/, bad_branch["error"])
      page = served_page(gui, ok_host)
      ["/api/diff/", 'id="diff-pane"', "function diffLineCode(", "function renderDiffLine("].each { |seam| assert_includes page, seam }
      ['id="diff-tray"', 'act("drafts-send"', 'draftAction("draft-put"'].each { |seam| assert_includes page, seam }
      ['"Branch"', "function renderDiffCommits(", 'params.set("from"', "address.range = range.label"].each do |seam|
        assert_includes page, seam
      end
      ['line.uncommitted ? " unc" : ""', 'd.scope === "branch" && d.checkout !== false && diffHasUncommittedLines(d)', "partly uncommitted",
       ".diff-table tr.unc td.d-num:first-child"].each { |seam| assert_includes page, seam }
    end
  end

  def test_the_route_takes_a_commit_range_and_reports_a_refused_one
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      %w[a b].each { |f| commit(wt, "#{f}.txt", "#{f}\n") }
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      first = sha_of(wt, "HEAD~1")

      reply = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=commits&from=#{first[0, 7]}&to=#{first[0, 7]}", ok_host, "")[2])
      refused = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=commits&from=main&to=main", ok_host, "")[2])

      assert_equal [true, ["a.txt"], first], [reply["ok"], paths(reply), reply["range"]["to"]]
      assert_equal [false, '"main" is not a commit sha'], refused.values_at("ok", "error")
    end
  end

  def test_a_viewed_mark_holds_while_the_files_diff_is_unchanged_in_any_scope
    with_repo do |repo|
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "done.txt", "one\n")
      File.write(File.join(wt, "base.txt"), "base\nedited\n")
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      diff = ->(query = "") { JSON.parse(gui.respond("GET", "/api/diff/feat?#{query}", ok_host, "")[2])["files"].to_h { |f| [f["path"], f] } }
      mark = lambda do |file, viewed = true|
        gui.actions.dispatch("cmd" => "diff-viewed", "slug" => "feat",
                             "args" => { "path" => file["path"], "digest" => file["digest"], "viewed" => viewed })
      end

      files = diff.call
      assert_equal [false, false], files.values_at("base.txt", "done.txt").map { |f| f["viewed"] }
      assert_equal({ "ok" => true, "viewed" => true }, mark.call(files["done.txt"]))
      mark.call(files["base.txt"])

      assert_equal [true, true], diff.call.values_at("base.txt", "done.txt").map { |f| f["viewed"] }
      assert_equal true, diff.call("scope=commits")["done.txt"]["viewed"], "the same diff in another scope"
      File.write(File.join(wt, "base.txt"), "base\nedited again\n")
      assert_equal [false, true], diff.call.values_at("base.txt", "done.txt").map { |f| f["viewed"] }

      assert_equal({ "ok" => true, "viewed" => false }, mark.call(diff.call["done.txt"], false))
      assert_equal false, diff.call["done.txt"]["viewed"]
      mark.call(diff.call["done.txt"])
      gui.actions.dispatch("cmd" => "state", "slug" => "feat", "args" => { "state" => "resolved" })
      refute File.exist?(Quartermaster::ViewedMarks.new("feat").path), "resolving drops the marks"
      mark.call(diff.call["done.txt"])
      Quartermaster::WorkItem.find("feat").update_state("resolved")
      refute File.exist?(Quartermaster::ViewedMarks.new("feat").path), "so does resolving outside the GUI (qm choose-state)"
    end
  end

  def test_the_page_lists_files_and_marks_them_viewed
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    page = served_page(gui, ok_host)

    ['id="diff-nav"', "function renderDiffNav(", "function renderDiffJump(", "function setDiffViewed(", "const diffViewedCount = files =>",
     'act("diff-viewed"', ".diff-max .diff-nav { display: block; }",
     "f.viewed ? \" viewed\" : \"\"", "box.open = !f.viewed && lines <= DIFF_FOLD_LINES",
     "const folds = diffView.rendered === d", "box.open = folds.get(f.path);"].each do |seam|
      assert_includes page, seam
    end
  end

  def test_the_page_shows_the_diff_or_only_its_old_or_new_side_without_rebuilding_rows
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    page = served_page(gui, ok_host)

    ['["diff", "Diff",', '["old", "Old",', '["new", "New",', 'sessionStorage.getItem("qm-diff-view")',
     'sessionStorage.setItem("qm-diff-view", mode)', "how.appendChild(renderDiffViewModes());",
     'body.classList.toggle("d-only-old", diffViewMode === "old");',
     'body.classList.toggle("d-only-new", diffViewMode === "new");',
     "    markDiffRowSides(tbody);\n", 'tr.classList.contains("d-hunk") || tr.classList.contains("d-expand")) side = "";', 'tr.dataset.kind === "del" ? "old" : tr.dataset.kind === "add" ? "new" : ""',
     '.diff-body.d-only-new .diff-table tr.d-line.del, .diff-body.d-only-new .diff-table tr[data-side="old"]',
     '.diff-body.d-only-old .diff-table tr.d-line.add, .diff-body.d-only-old .diff-table tr[data-side="new"]',
     ".diff-body.d-only-new .diff-table td.d-num:first-child", ".diff-body.d-only-old .diff-table td.d-num:nth-child(2)",
     "box-shadow: inset -3px 0 0 var(--good);", "box-shadow: inset -3px 0 0 var(--crit);",
     "if (row) showDiffRow(row);\n  flashDiffTarget(box, \"center\");"].each do |seam|
      assert_includes page, seam
    end
    refute_match(/function setDiffViewMode\([^)]*\) \{[^}]*loadDiff/, page, "a switch never refetches")
  end

  def test_the_page_highlights_diff_code_with_a_pinned_highlight_js_and_falls_back_to_plain_text
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    page = served_page(gui, ok_host)

    assert_match(%r{<script src="https://cdn\.jsdelivr\.net/npm/@highlightjs/cdn-assets@\d+\.\d+\.\d+/highlight\.min\.js"\s+integrity="sha384-}, page)
    ["if (!window.hljs) return null;", "return html == null ? esc(line.s) : html;", ".d-code .hljs-keyword", "--syn-kw"].each do |seam|
      assert_includes page, seam
    end
  end
end

class DiffCommentsTest < Minitest::Test
  def test_one_message_with_path_line_quote_and_comment_per_entry
    text = Quartermaster::DiffComments.message(
      [{ "path" => "lib/a.rb", "line" => 12, "side" => "new", "code" => "  x = 1\n", "comment" => "Why 1?\nNot 2?" },
       { "path" => "lib/b.rb", "line" => "3", "side" => "old", "code" => "gone()", "comment" => "keep this" },
       { "path" => "lib/c.rb", "line" => 1, "comment" => "   " }],
      branch: "feature", base: "main"
    )

    assert_equal <<~MSG.chomp, text
      Review comments on the diff of feature (vs main) — 2 comments:

      lib/a.rb:12
      >   x = 1
      Why 1?
      Not 2?

      lib/b.rb:3 (removed line)
      > gone()
      keep this
    MSG
    assert_raises(ArgumentError) { Quartermaster::DiffComments.message([{ "path" => "a", "comment" => "" }]) }
  end

  def test_a_comment_on_selected_commits_names_them
    text = Quartermaster::DiffComments.message(
      [{ "path" => "a.rb", "line" => 4, "side" => "new", "comment" => "one", "range" => "abc1234" },
       { "path" => "b.rb", "line" => 2, "side" => "old", "comment" => "two", "range" => "abc1234..def5678" },
       { "path" => "c.rb", "line" => 1, "side" => "new", "comment" => "three", "range" => "not a range" }],
      branch: "feature", base: "main"
    )

    assert_includes text, "a.rb:4 (on commit abc1234)\none"
    assert_includes text, "b.rb:2 (removed line, on commits abc1234..def5678)\ntwo"
    assert_includes text, "c.rb:1\nthree"
  end
end

# The comments go into the chat's terminal as one bracketed paste, then one
# Enter; a program that asked for bracketed paste sees exactly that.
class DiffCommentsPasteTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  # Bracketed-paste mode on, raw tty, then every byte that arrives into a file.
  READER = 'printf "\033[?2004h"; stty raw -echo; echo ready; exec cat > "$0"'
  PASTE_END = "\e[201~\r"

  def setup
    super
    skip "tmux not installed" unless system("command -v tmux >/dev/null")
    @tmux = Quartermaster::Tmux.new(socket: "qm-test-paste-#{Process.pid}")
    @out = File.join(Quartermaster::ROOT, "pasted-#{name}")
  end

  def teardown
    @tmux&.kill_server
  end

  def screen(name) = Open3.capture2("tmux", "-L", @tmux.socket, "capture-pane", "-p", "-t", "=#{name}:")[0]
  def wait_for(timeout = 5) = Timeout.timeout(timeout) { sleep 0.05 until yield }
  def received = File.exist?(@out) ? File.binread(@out) : ""

  def open_reader(name)
    FileUtils.mkdir_p(File.dirname(@out))
    @tmux.open(name, cwd: Dir.home, argv: ["sh", "-c", READER, @out])
    wait_for { screen(name).include?("ready") }
  end

  def test_paste_arrives_whole_inside_bracketed_paste_markers
    open_reader("paste")
    assert @tmux.paste("paste", "one\ntwo")
    assert @tmux.send_enter("paste")

    wait_for { received.end_with?(PASTE_END) }
    assert_equal "\e[200~one\rtwo#{PASTE_END}", received
    refute @tmux.paste("a:b", "x"), "odd names are refused"
  end
end

class ViewedMarksTest < Minitest::Test
  include QmTestHelpers

  def file(path, text) = Quartermaster::UnifiedDiff.parse("diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-old\n+#{text}\n").first

  def test_a_mark_matches_only_the_diff_it_was_made_on
    marks = Quartermaster::ViewedMarks.new("item")
    a = file("a.rb", "one")
    marks.set("a.rb", Quartermaster::ViewedMarks.digest(a), true)

    assert_equal [true, false], marks.apply([file("a.rb", "one"), file("a.rb", "two")]).map { |f| f["viewed"] }
    unmarked = file("a.rb", "one").merge("hunks" => file("a.rb", "one")["hunks"].each { |h| h["lines"].each { |l| l["uncommitted"] = true } })
    assert_equal Quartermaster::ViewedMarks.digest(a), Quartermaster::ViewedMarks.digest(unmarked), "commit state is not part of the diff"
  end

  def test_keeps_a_few_digests_per_path_and_drops_the_file_when_empty
    marks = Quartermaster::ViewedMarks.new("item")
    digests = (1..8).map { |n| Quartermaster::ViewedMarks.digest(file("a.rb", n.to_s)) }
    digests.each { |d| marks.set("a.rb", d, true) }

    assert_equal digests.last(Quartermaster::ViewedMarks::KEEP_PER_PATH), marks.marks["a.rb"]
    digests.each { |d| marks.set("a.rb", d, false) }
    refute File.exist?(marks.path)
  end

  def test_refuses_a_malformed_digest_path_or_slug
    marks = Quartermaster::ViewedMarks.new("item")

    assert_raises(ArgumentError) { marks.set("a.rb", "../etc", true) }
    assert_raises(ArgumentError) { marks.set("", "0" * 20, true) }
    assert_raises(ArgumentError) { Quartermaster::ViewedMarks.new("../x") }
  end
end
