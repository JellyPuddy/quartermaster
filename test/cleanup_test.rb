# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/cleanup_test.rb`).
require_relative "test_helper"

class CleanupTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  NOT_SERVING = { ["curl"] => ["", "", false], %w[pf status] => ["", "", false] }.freeze

  def with_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      @repo = make_repo(File.join(dir, "repo"))
      commit(@repo, "base.txt", "base")
      yield @repo
    end
  end

  def commit(path, file, content, message: "change #{file}")
    File.write(File.join(path, file), content)
    system("git", "-C", path, "add", file)
    system("git", "-C", path, *GIT_ID, "commit", "-q", "-m", message)
    git(path, "rev-parse", "HEAD")
  end

  def git(path, *args)
    out, = Open3.capture2("git", "-C", path, *args)
    out.strip
  end

  # A `claude --worktree`-style checkout under <repo>/.claude/worktrees/.
  def worktree(name, branch: name, base: "main")
    path = File.join(@repo, ".claude", "worktrees", name)
    system("git", "-C", @repo, "worktree", "add", "-q", "-b", branch, path, base)
    File.realpath(path)
  end

  def cleanup(runner: nil, merged: [], dbs: { ["app-test-db"] => ["app_test_x\napp_test_x2\n", "", true] })
    @runner = runner || GitPassThroughRunner.new(NOT_SERVING.merge(dbs))
    pr = Quartermaster::PrStatus.new(fetcher: ->(_item, branch) { merged.include?(branch) ? "MERGED" : "OPEN" })
    Quartermaster::Cleanup.new(project_map: Quartermaster::ProjectMap.new(roots: { "WebApp" => featured_project(@repo), "Other" => @repo }),
                               runner: @runner, session_log: Quartermaster::SessionLog.new, pr_status: pr)
  end

  def log_start(session_id, cwd, live: false)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => cwd,
                                         "pid" => live ? Process.pid : 999_999_999, "ts" => Time.now.iso8601)
  end

  def entry(plan, kind, key)
    plan.entries.find { |e| e.kind == kind && (e.path == key || e.branch == key) } ||
      flunk("no #{kind} entry #{key} in #{plan.entries.map(&:id)}")
  end

  def test_a_temp_branch_cherry_picked_into_the_item_branch_is_safe_and_goes
    with_repo do
      temp = worktree("worktree-scratch")
      sha = commit(temp, "fix.txt", "fix")
      system("git", "-C", @repo, "branch", "-q", "feature")
      feature = worktree("feature", branch: "feature-wt", base: "feature")
      system("git", "-C", feature, *GIT_ID, "cherry-pick", sha, out: File::NULL)
      system("git", "-C", @repo, "branch", "-q", "-f", "feature", "feature-wt")
      item = Quartermaster::WorkItem.create("Fix", project: "WebApp", branch: "feature")
      item.add_temp_branch("worktree-scratch")
      tool = cleanup

      plan = tool.plan_item(Quartermaster::WorkItem.find("fix"))

      wt = entry(plan, "worktree", temp)
      assert_equal "ok", wt.status, wt.reasons.inspect
      assert wt.ticked
      assert_equal %w[app_test_x app_test_x2], wt.db_names
      assert_equal "ok", wt.db_status
      branch = entry(plan, "branch", "worktree-scratch")
      assert_equal ["ok", true, wt.id], [branch.status, branch.ticked, branch.requires]
      refute plan.entries.any? { |e| e.path == File.realpath(@repo) }

      outcomes = tool.execute(plan, selected: plan.entries.select(&:ticked).map(&:id))

      assert outcomes.all?(&:removed?), outcomes.map(&:to_h).inspect
      refute File.directory?(temp)
      assert_empty git(@repo, "branch", "--list", "worktree-scratch")
      assert_includes @runner.argvs, ["app-test-db", "drop", temp]
      assert_includes @runner.argvs, ["git", "worktree", "remove", temp]
      assert_empty Quartermaster::WorkItem.find("fix").temp_branches
      refute_empty git(@repo, "branch", "--list", "feature"), "item branches stay"
    end
  end

  # Neither base holds the temp branch's whole change, so only per-commit
  # patch equivalence (git cherry) can show nothing would be lost.
  def test_temp_commits_picked_partly_into_the_item_branch_and_partly_into_main_are_safe
    with_repo do
      temp = worktree("worktree-split")
      first = commit(temp, "one.txt", "1")
      second = commit(temp, "two.txt", "2")
      system("git", "-C", @repo, "branch", "-q", "feature")
      feature = worktree("feature", branch: "feature-wt", base: "feature")
      system("git", "-C", feature, *GIT_ID, "cherry-pick", first, out: File::NULL)
      system("git", "-C", @repo, "branch", "-q", "-f", "feature", "feature-wt")
      system("git", "-C", @repo, *GIT_ID, "cherry-pick", second, out: File::NULL)
      Quartermaster::WorkItem.create("Split", project: "Other", branch: "feature").add_temp_branch("worktree-split")

      plan = cleanup.plan_item(Quartermaster::WorkItem.find("split"))

      assert_equal "ok", entry(plan, "branch", "worktree-split").status, entry(plan, "branch", "worktree-split").reasons.inspect
      assert_equal "ok", entry(plan, "worktree", temp).status
    end
  end

  def test_unpushed_unique_commits_warn_and_only_go_when_forced
    with_repo do
      temp = worktree("worktree-unique")
      commit(temp, "only-here.txt", "precious", message: "precious work")
      Quartermaster::WorkItem.create("Uniq", project: "Other").add_temp_branch("worktree-unique")
      tool = cleanup

      plan = tool.plan_item(Quartermaster::WorkItem.find("uniq"))
      wt = entry(plan, "worktree", temp)
      branch = entry(plan, "branch", "worktree-unique")

      assert_equal "warn", wt.status
      assert_match(/1 commit found nowhere else \(\h{7} precious work\)/, wt.reasons.join)
      refute wt.ticked
      assert_equal "n/a", wt.db_status, "worktrees of a project without test_db have no test DBs"
      assert_equal ["warn", false], [branch.status, branch.ticked]

      skipped = tool.execute(plan, selected: [wt.id, branch.id])
      assert_equal %w[skipped skipped], skipped.map(&:result)
      assert File.directory?(temp)

      forced = tool.execute(plan, selected: [], force: [wt.id, branch.id])
      assert_equal %w[removed removed], forced.map(&:result), forced.map(&:to_h).inspect
      assert_includes @runner.argvs, ["git", "worktree", "remove", "--force", temp]
      assert_empty git(@repo, "branch", "--list", "worktree-unique")
    end
  end

  def test_dirty_and_untracked_worktrees_warn
    with_repo do
      dirty = worktree("worktree-dirty")
      File.write(File.join(dirty, "base.txt"), "edited")
      untracked = worktree("worktree-untracked")
      File.write(File.join(untracked, "new.txt"), "new")
      item = Quartermaster::WorkItem.create("Dirt", project: "Other")
      item.add_temp_branch("worktree-dirty")
      item.add_temp_branch("worktree-untracked")
      tool = cleanup

      plan = tool.plan_item(Quartermaster::WorkItem.find("dirt"))
      dirty_entry = entry(plan, "worktree", dirty)
      dirty_branch = entry(plan, "branch", "worktree-dirty")

      assert_equal ["warn", ["uncommitted changes"]], [dirty_entry.status, dirty_entry.reasons]
      assert_equal ["untracked files"], entry(plan, "worktree", untracked).reasons
      # The clean branch itself is safe, but stays unticked while its worktree does.
      assert_equal ["ok", false], [dirty_branch.status, dirty_branch.ticked]

      outcomes = tool.execute(plan, selected: [dirty_branch.id])
      assert_equal "skipped", outcomes.first.result
      assert_match(/worktree stays/, outcomes.first.message)

      forced = tool.execute(plan, selected: [], force: [entry(plan, "worktree", untracked).id])
      assert_equal ["removed"], forced.map(&:result)
      refute File.directory?(untracked)
    end
  end

  def test_pf_served_and_live_session_worktrees_are_hard_blocked
    with_repo do
      served = worktree("worktree-served")
      busy = worktree("worktree-busy")
      FileUtils.mkdir_p(File.join(busy, "app"))
      item = Quartermaster::WorkItem.create("Busy", project: "WebApp", session_id: "sess-busy")
      item.add_temp_branch("worktree-served")
      log_start("sess-busy", File.join(busy, "app"), live: true)
      status = JSON.generate("mode" => "dev", "root" => served, "switching" => false)
      tool = cleanup(runner: GitPassThroughRunner.new(["curl"] => [status, "", true], ["app-test-db"] => ["", "", true]))

      plan = tool.plan_item(Quartermaster::WorkItem.find("busy"))
      pf = entry(plan, "worktree", served)
      live = entry(plan, "worktree", busy)

      assert_equal ["blocked", ["the dev server serves it"], false], [pf.status, pf.reasons, pf.ticked]
      assert_equal ["blocked", ["live session sess-bus works here"]], [live.status, live.reasons]
      assert_equal "ok", entry(plan, "branch", "worktree-served").status
      refute entry(plan, "branch", "worktree-served").ticked, "its worktree can't go, so neither can it"

      outcomes = tool.execute(plan, selected: [pf.id], force: [pf.id, live.id])
      assert_equal %w[skipped skipped], outcomes.map(&:result)
      assert File.directory?(served)
      assert File.directory?(busy)
      refute(@runner.argvs.any? { |a| a.first(3) == %w[git worktree remove] })
    end
  end

  def test_execute_reports_each_entry_before_and_after_in_execution_order
    with_repo do
      tool = cleanup
      make = lambda do |kind, key, status|
        Quartermaster::Cleanup::Entry.new(id: "#{kind}:#{key}", kind: kind, repo: @repo, path: kind == "worktree" ? key : nil,
                                          branch: key, status: status, reasons: ["because"], notes: [],
                                          ticked: false, db_names: [], db_status: "n/a")
      end
      entries = [make.("branch", "b1", "blocked"), make.("worktree", "/w1", "warn"),
                 make.("worktree", "/w2", "blocked"), make.("worktree", "/w3", "blocked")]
      plan = Quartermaster::Cleanup::Plan.new(scope: "x", entries: entries, notes: [])
      events = []

      outcomes = tool.execute(plan, selected: %w[branch:b1 worktree:/w1 worktree:/w3],
                                    on_start: ->(entry, index, total) { events << [:start, entry.id, index, total] },
                                    on_outcome: ->(outcome, index, total) { events << [:done, outcome.id, index, total] })

      assert_equal %w[worktree:/w1 worktree:/w3 branch:b1], outcomes.map(&:id), "worktrees first, unselected left out"
      assert_equal [[:start, "worktree:/w1", 1, 3], [:done, "worktree:/w1", 1, 3],
                    [:start, "worktree:/w3", 2, 3], [:done, "worktree:/w3", 2, 3],
                    [:start, "branch:b1", 3, 3], [:done, "branch:b1", 3, 3]], events
      assert_equal outcomes.map(&:to_h), tool.execute(plan, selected: %w[branch:b1 worktree:/w1 worktree:/w3]).map(&:to_h),
                   "callbacks are optional"
    end
  end

  def test_a_squash_merged_pr_branch_is_safe_to_delete_and_a_later_commit_is_not
    with_repo do
      system("git", "-C", @repo, "branch", "-q", "done")
      done = worktree("done-wt", branch: "done-scratch", base: "done")
      commit(done, "a.txt", "a")
      commit(done, "b.txt", "b")
      system("git", "-C", @repo, "branch", "-q", "-f", "done", "done-scratch")
      system("git", "-C", @repo, "worktree", "remove", done)
      system("git", "-C", @repo, *GIT_ID, "merge", "-q", "--squash", "done", out: File::NULL)
      system("git", "-C", @repo, *GIT_ID, "commit", "-q", "-m", "Squashed PR")
      Quartermaster::WorkItem.create("Done", project: "Other", branch: "done")
      Quartermaster::WorkItem.create("Open", project: "Other", branch: "open")
      system("git", "-C", @repo, "branch", "-q", "open")
      tool = cleanup(merged: %w[done])

      merged = entry(tool.plan_item(Quartermaster::WorkItem.find("done")), "branch", "done")
      assert_equal ["ok", true, ["PR merged"]], [merged.status, merged.ticked, merged.notes]
      assert_empty tool.plan_item(Quartermaster::WorkItem.find("open")).entries, "an open PR's branch stays"

      later = worktree("later", branch: "later", base: "done")
      commit(later, "c.txt", "c", message: "after the merge")
      system("git", "-C", @repo, "branch", "-q", "-f", "done", "later")
      again = entry(cleanup(merged: %w[done]).plan_item(Quartermaster::WorkItem.find("done")), "branch", "done")
      assert_equal "warn", again.status
      assert_match(/after the merge/, again.reasons.join)
    end
  end

  # `git log docs` fails as "ambiguous argument" when docs/ is also a
  # directory; that failure must not read as "nothing would be lost".
  def test_a_branch_named_like_a_directory_still_has_its_commits_checked
    with_repo do
      FileUtils.mkdir_p(File.join(@repo, "docs"))
      commit(@repo, "docs/readme.txt", "r")
      temp = worktree("docs-wt", branch: "docs")
      commit(temp, "docs/only-here.txt", "precious", message: "precious docs")
      Quartermaster::WorkItem.create("Docs", project: "Other").add_temp_branch("docs")
      repo = Quartermaster::GitRepo.new(@repo)

      assert_equal ["precious docs"], repo.unpreserved_commits("docs", ["main"]).map(&:last)
      assert_nil repo.unpreserved_commits("no-such-branch", ["main"])
      branch = entry(cleanup.plan_item(Quartermaster::WorkItem.find("docs")), "branch", "docs")
      assert_equal ["warn", false], [branch.status, branch.ticked]
    end
  end

  def test_test_dbs_read_unknown_when_the_tool_is_missing
    with_repo do
      temp = worktree("worktree-nodb")
      Quartermaster::WorkItem.create("Nodb", project: "WebApp").add_temp_branch("worktree-nodb")
      missing = { ["app-test-db"] => ["", "No such file or directory - app-test-db", false] }
      tool = cleanup(dbs: missing)

      plan = tool.plan_item(Quartermaster::WorkItem.find("nodb"))
      wt = entry(plan, "worktree", temp)

      assert_equal ["ok", "unknown", nil], [wt.status, wt.db_status, wt.db_names]
      assert_match(/test DBs unknown: No such file/, wt.notes.join)
      tool.execute(plan, selected: [wt.id])
      refute_includes @runner.argvs, ["app-test-db", "drop", temp]
      refute File.directory?(temp)
    end
  end

  def test_the_item_plan_finds_worktrees_by_session_cwd_and_spares_the_main_checkout
    with_repo do
      wt = worktree("by-cwd", branch: "unlinked-branch")
      Quartermaster::WorkItem.create("Cwd", project: "Other", session_id: "sess-cwd")
      log_start("sess-cwd", wt)
      Quartermaster::WorkItem.create("Main", project: "Other", session_id: "sess-main")
      log_start("sess-main", @repo)

      assert_equal [wt], cleanup.plan_item(Quartermaster::WorkItem.find("cwd")).entries.map(&:path)
      assert_empty cleanup.plan_item(Quartermaster::WorkItem.find("main")).entries
    end
  end

  def test_sweep_lists_orphans_and_never_preticks_an_open_items_worktree
    with_repo do
      orphan = worktree("worktree-orphan")
      mine = worktree("worktree-mine")
      system("git", "-C", @repo, "branch", "-q", "worktree-loose")
      system("git", "-C", @repo, "branch", "-q", "keeper")
      outside = add_worktree(@repo, "elsewhere", "outside-wt")
      Quartermaster::WorkItem.create("Mine", project: "WebApp").add_temp_branch("worktree-mine")
      done = Quartermaster::WorkItem.create("Old", project: "WebApp")
      done.add_temp_branch("worktree-orphan")
      done.update_state("resolved")
      tool = cleanup

      plan = tool.plan_sweep

      assert_equal [orphan, mine].sort, plan.worktrees.map(&:path).sort
      refute(plan.entries.any? { |e| e.path == outside || %w[keeper main elsewhere].include?(e.branch) })
      assert entry(plan, "worktree", orphan).ticked
      claimed = entry(plan, "worktree", mine)
      assert_equal ["ok", false], [claimed.status, claimed.ticked]
      assert_match(/unresolved item 'mine'/, claimed.notes.join)
      refute entry(plan, "branch", "worktree-mine").ticked
      assert entry(plan, "branch", "worktree-loose").ticked
      assert_equal "sweep", plan.scope
      assert_match(/\A2 worktrees, 3 branches — 3 ready/, plan.summary)

      outcomes = tool.execute(plan, selected: plan.entries.select(&:ticked).map(&:id))
      assert_equal 3, outcomes.count(&:removed?), outcomes.map(&:to_h).inspect
      assert File.directory?(mine)
      assert_empty Quartermaster::WorkItem.find("old").temp_branches
    end
  end

  # The delegate-build pattern: an agent's worktree commit is cherry-picked
  # onto an integration branch that is not trunk. The sweep must see it there.
  def test_sweep_counts_a_commit_picked_onto_a_local_branch_as_preserved_and_reports_one_that_was_not
    with_repo do
      picked = worktree("worktree-picked")
      sha = commit(picked, "feature.txt", "feature", message: "agent work")
      lost = worktree("worktree-lost")
      commit(lost, "feature.txt", "something else", message: "unpicked work")
      system("git", "-C", @repo, "branch", "-q", "integration")
      integration = worktree("integration-wt", branch: "integration-wt", base: "integration")
      commit(integration, "other.txt", "other", message: "integration's own work")
      system("git", "-C", integration, *GIT_ID, "cherry-pick", sha, out: File::NULL)
      system("git", "-C", @repo, "branch", "-q", "-f", "integration", "integration-wt")
      system("git", "-C", @repo, "worktree", "remove", integration)
      system("git", "-C", @repo, "branch", "-q", "-D", "integration-wt")

      plan = cleanup.plan_sweep

      assert_equal ["ok", true], [entry(plan, "worktree", picked).status, entry(plan, "worktree", picked).ticked],
                   entry(plan, "worktree", picked).reasons.inspect
      assert_equal "ok", entry(plan, "branch", "worktree-picked").status
      unpicked = entry(plan, "worktree", lost)
      assert_equal "warn", unpicked.status
      assert_match(/1 commit found nowhere else \(\h{7} unpicked work\)/, unpicked.reasons.join)
      assert_equal "warn", entry(plan, "branch", "worktree-lost").status
    end
  end

  # Counts the git calls one head costs, whatever the number of bases.
  class CountingGitRepo < Quartermaster::GitRepo
    attr_reader :calls

    def git(*args, stdin: "")
      (@calls ||= []) << args.first
      super
    end
  end

  def test_checking_a_head_costs_the_same_git_calls_for_one_base_or_many
    with_repo do
      head = worktree("worktree-head")
      first = commit(head, "one.txt", "1", message: "picked")
      commit(head, "two.txt", "2", message: "kept here")
      commit(head, "three.txt", "3", message: "also here")
      system("git", "-C", @repo, "branch", "-q", "keeper-0")
      keeper = worktree("keeper-wt", branch: "keeper-wt", base: "keeper-0")
      system("git", "-C", keeper, *GIT_ID, "cherry-pick", first, out: File::NULL)
      system("git", "-C", @repo, "branch", "-q", "-f", "keeper-0", "keeper-wt")
      30.times { |i| system("git", "-C", @repo, "branch", "-q", "keeper-#{i + 1}", "main") }

      counts = [1, 31].map do |n|
        repo = CountingGitRepo.new(@repo)
        lost = repo.unpreserved_commits("worktree-head", ["main", *Array.new(n) { |i| "keeper-#{i}" }])
        assert_equal ["also here", "kept here"], lost.map(&:last)
        repo.calls.size
      end

      assert_equal counts.first, counts.last, "git calls must not grow with the number of bases"
      assert_operator counts.last, :<=, 10
    end
  end

  def test_plan_to_h_is_checklist_data
    with_repo do
      worktree("worktree-h")
      Quartermaster::WorkItem.create("Hash", project: "WebApp").add_temp_branch("worktree-h")

      data = cleanup.plan_item(Quartermaster::WorkItem.find("hash")).to_h

      assert_equal %w[scope summary notes entries], data.keys
      assert_equal %w[id kind repo path branch item status reasons notes ticked db_names db_status requires title],
                   data["entries"].first.keys
      assert_equal(%w[worktree branch], data["entries"].map { |e| e["kind"] })
    end
  end
end

class CleanupCliTest < Minitest::Test
  include QmTestHelpers

  class FixedCleanup
    attr_reader :executed

    def initialize(plan) = @plan = plan
    def plan_item(_item) = @plan
    def plan_sweep = @plan

    def execute(plan, selected:, force: [], on_start: nil, on_outcome: nil)
      @executed = { selected: selected, force: force }
      ids = selected + force
      ids.map.with_index(1) do |id, index|
        on_start&.call(plan.entries.find { |e| e.id == id }, index, ids.size)
        outcome = Quartermaster::Cleanup::Outcome.new(id: id, kind: "worktree", result: "removed", message: "removed")
        on_outcome&.call(outcome, index, ids.size)
        outcome
      end
    end
  end

  def with_cleanup(fake)
    klass = Quartermaster::Cleanup
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  def plan
    entries = [
      Quartermaster::Cleanup::Entry.new(id: "worktree:/r/.claude/worktrees/a", kind: "worktree", repo: "/r",
                                        path: "/r/.claude/worktrees/a", branch: "worktree-a", status: "ok",
                                        reasons: [], notes: [], ticked: true, db_names: ["db_a"], db_status: "ok"),
      Quartermaster::Cleanup::Entry.new(id: "worktree:/r/.claude/worktrees/b", kind: "worktree", repo: "/r",
                                        path: "/r/.claude/worktrees/b", branch: "worktree-b", status: "warn",
                                        reasons: ["untracked files"], notes: [], ticked: false, db_names: [],
                                        db_status: "ok")
    ]
    Quartermaster::Cleanup::Plan.new(scope: "cli", entries: entries, notes: [])
  end

  def test_cleanup_prints_the_plan_and_runs_only_with_yes
    Quartermaster::WorkItem.create("Cli", project: "Other")
    fake = FixedCleanup.new(plan)

    stdout, = capture_io { with_cleanup(fake) { Quartermaster::CLI.new.run(%w[cleanup cli]) } }
    assert_match(/cli: 2 worktrees — 1 ready, 1 needs a look/, stdout)
    assert_match(%r{\[x\] .*worktree.* /r/.claude/worktrees/a \(worktree-a\) · test DBs: db_a}, stdout)
    assert_match(/\[ \] .*⚠ worktree.* — untracked files/, stdout)
    assert_nil fake.executed

    stdout, = capture_io do
      with_cleanup(fake) { Quartermaster::CLI.new.run(%w[cleanup cli --yes --force /r/.claude/worktrees/b]) }
    end
    assert_equal({ selected: ["worktree:/r/.claude/worktrees/a"], force: ["worktree:/r/.claude/worktrees/b"] },
                 fake.executed)
    assert_match(%r{removed.* /r/.claude/worktrees/b: removed}, stdout)
  end

  # Piped or backgrounded (Claude Code runs it so): each outcome line as it
  # happens, flushed, and not repeated at the end.
  def test_sweep_streams_one_line_per_entry_when_stdout_is_not_a_terminal
    fake = FixedCleanup.new(plan)
    stdout, = capture_io do
      with_cleanup(fake) { Quartermaster::CLI.new.run(%w[sweep --yes --force /r/.claude/worktrees/b]) }
    end
    outcome_lines = stdout.lines.grep(/removed/)
    assert_equal 2, outcome_lines.size, stdout
    assert_match(%r{removed.* /r/.claude/worktrees/a: removed\n\z}, outcome_lines[0])
    assert_match(%r{removed.* /r/.claude/worktrees/b: removed\n\z}, outcome_lines[1])
    refute_includes stdout, "\r"
  end

  def test_sweep_draws_a_progress_bar_on_a_terminal_and_ends_it_with_a_newline
    fake = FixedCleanup.new(plan)
    stdout, = capture_io do
      $stdout.define_singleton_method(:tty?) { true }
      with_cleanup(fake) { Quartermaster::CLI.new.run(%w[sweep --yes --force /r/.claude/worktrees/b]) }
    end
    bar, after = stdout.split(/(?<=\e\[K)\n/, 2)
    assert_match(%r{\r\[ +\] 0/2  removing worktree a…\e\[K}, bar, "names the entry before working on it")
    assert_match(%r{\r\[#+ +\] 1/2  removing worktree b…\e\[K}, bar)
    assert_match(%r{\r\[#+\] 2/2\e\[K\z}, bar, "finished, then a newline")
    assert_equal 2, after.lines.grep(/removed/).size, "the outcome lines follow the bar once"
    refute_includes after, "\r"
  end

  def test_the_progress_bar_fits_the_terminal_width
    cli = Quartermaster::CLI.new
    cli.define_singleton_method(:terminal_width) { 40 }
    line = cli.send(:progress_bar, 112, 248, "removing worktree agent-a1b2c3d4e5f6a7b8c9…")
    assert_equal 39, line.length
    assert line.start_with?("[#####        ] 112/248  removing"), line
    assert_equal "…", line[-1]
  end

  def test_sweep_uses_the_sweep_plan
    fake = FixedCleanup.new(plan)
    stdout, = capture_io { with_cleanup(fake) { Quartermaster::CLI.new.run(%w[sweep --yes]) } }
    assert_equal ["worktree:/r/.claude/worktrees/a"], fake.executed[:selected]
    assert_match(/removed/, stdout)
  end

  def test_resolving_offers_the_cleanup_plan_on_the_cli_and_in_the_gui
    Quartermaster::WorkItem.create("Res", project: "Other")
    Quartermaster::WorkItem.create("Gui res", project: "Other")
    fake = FixedCleanup.new(plan)

    stdout, = capture_io { with_cleanup(fake) { Quartermaster::CLI.new.run(%w[state res resolved]) } }
    assert_equal "cleanup: 2 worktrees — 1 ready, 1 needs a look — qm cleanup res\n", stdout
    assert_equal "resolved", Quartermaster::WorkItem.find("res").state

    stdout, = capture_io { with_cleanup(fake) { Quartermaster::CLI.new.run(%w[state res fridge]) } }
    assert_empty stdout

    reply = with_cleanup(fake) do
      Quartermaster::Gui.new(runner: quiet_runner).actions.dispatch("cmd" => "state", "slug" => "gui-res", "args" => { "state" => "resolved" })
    end
    assert_equal true, reply["ok"]
    assert_equal "2 worktrees — 1 ready, 1 needs a look", reply.dig("cleanup", "summary")
    assert_equal 2, reply.dig("cleanup", "entries").size
  end

  def test_a_failing_plan_never_fails_the_resolve
    Quartermaster::WorkItem.create("Boom", project: "Other")
    broken = Object.new
    def broken.plan_item(_item) = raise("git exploded")

    stdout, = capture_io { with_cleanup(broken) { Quartermaster::CLI.new.run(%w[state boom resolved]) } }
    assert_empty stdout
    assert_equal "resolved", Quartermaster::WorkItem.find("boom").state
  end
end
