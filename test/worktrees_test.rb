# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/worktrees_test.rb`).
require_relative "test_helper"

class TargetWorktreeTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def with_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      yield repo, Quartermaster::ProjectMap.new(roots: { "WebApp" => featured_project(repo), "Other" => repo })
    end
  end

  def test_the_stack_top_with_a_worktree_is_the_target
    with_repo do |repo, map|
      add_worktree(repo, "s1", "wt-s1")
      top = add_worktree(repo, "s2", "wt-s2")
      write_stack(repo, %w[s1 s2])
      item = Quartermaster::WorkItem.create("Stacked", project: "WebApp", branch: "s1")

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: FakeRunner.new).resolve(item)

      assert_equal top, File.realpath(target.path)
      assert_equal "s2", target.branch
      refute target.create?
      assert_equal ["s1"], target.alternatives.map(&:first)
    end
  end

  def test_a_stack_top_without_a_worktree_gets_a_new_one_never_a_sibling_checkout
    with_repo do |repo, map|
      add_worktree(repo, "s1", "wt-s1")
      system("git", "-C", repo, "branch", "-q", "issue/7-top")
      write_stack(repo, %w[s1 issue/7-top])
      item = Quartermaster::WorkItem.create("Stacked", project: "WebApp", branch: "s1")
      runner = FakeRunner.new

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: runner).materialize(item)

      expected = File.join(repo, ".claude", "worktrees", "issue-7-top")
      assert_equal expected, target.path
      assert target.create?
      assert_match(/stack top issue\/7-top has no worktree; only s1/, target.warning)
      assert_equal [
        { argv: ["git", "worktree", "add", expected, "issue/7-top"], chdir: repo },
        { argv: %w[app-test-db prepare], chdir: expected }
      ], runner.calls
      refute(runner.argvs.any? { |argv| argv.include?("checkout") || argv.include?("switch") })
    end
  end

  def test_no_stack_picks_the_last_linked_branch_with_a_worktree_and_lists_the_others
    with_repo do |repo, map|
      first = add_worktree(repo, "b1", "wt-b1")
      last = add_worktree(repo, "b2", "wt-b2")
      item = Quartermaster::WorkItem.create("Plain", project: "WebApp", branch: "b1")
      item.link_branch("b2")
      item.link_branch("b3-no-worktree")

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: FakeRunner.new).resolve(item)

      assert_equal last, File.realpath(target.path)
      refute target.create?
      assert_equal [["b1", first]], target.alternatives.map { |b, p| [b, File.realpath(p)] }
    end
  end

  def test_a_remote_only_branch_is_fetched_and_tracked_without_a_test_db_without_a_test_db_command
    with_repo do |repo, map|
      item = Quartermaster::WorkItem.create("Remote", project: "Other", branch: "feature/x")
      runner = FakeRunner.new

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: runner).materialize(item)

      path = File.join(repo, ".claude", "worktrees", "feature-x")
      assert_equal [%w[git fetch origin feature/x],
                    ["git", "worktree", "add", "--track", "-b", "feature/x", path, "origin/feature/x"]], runner.argvs
      assert_equal path, target.path
    end
  end

  def test_no_branches_falls_back_to_the_main_checkout_and_explicit_worktrees_win
    with_repo do |repo, map|
      item = Quartermaster::WorkItem.create("Bare", project: "WebApp")
      resolver = Quartermaster::TargetWorktree.new(project_map: map, runner: FakeRunner.new)

      assert_equal repo, resolver.resolve(item).path
      Dir.mktmpdir do |elsewhere|
        assert_equal elsewhere, resolver.resolve(item, worktree: elsewhere).path
      end
      assert_raises(ArgumentError) { resolver.resolve(item, worktree: "/nonexistent/wt") }
    end
  end

  def test_a_selected_stack_layer_wins_over_the_stack_top
    with_repo do |repo, map|
      lower = add_worktree(repo, "s1", "wt-s1")
      top = add_worktree(repo, "s2", "wt-s2")
      write_stack(repo, %w[s1 s2])
      item = Quartermaster::WorkItem.create("Stacked", project: "WebApp", branch: "s1")

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: FakeRunner.new).resolve(item, branch: "s1")

      assert_equal lower, File.realpath(target.path)
      assert_equal "s1", target.branch
      refute target.create?
      assert_equal [["s2", top]], target.alternatives.map { |b, p| [b, File.realpath(p)] }
    end
  end

  def test_a_selected_branch_without_a_worktree_gets_a_new_one_never_a_switched_checkout
    with_repo do |repo, map|
      add_worktree(repo, "b1", "wt-b1")
      system("git", "-C", repo, "branch", "-q", "fix/typo")
      item = Quartermaster::WorkItem.create("Loose", project: "WebApp", branch: "b1")
      item.link_branch("fix/typo")
      runner = FakeRunner.new

      target = Quartermaster::TargetWorktree.new(project_map: map, runner: runner).materialize(item, branch: "fix/typo")

      expected = File.join(repo, ".claude", "worktrees", "fix-typo")
      assert_equal expected, target.path
      assert target.create?
      assert_equal [["git", "worktree", "add", expected, "fix/typo"], %w[app-test-db prepare]], runner.argvs
    end
  end

  def test_a_selected_branch_the_item_does_not_link_is_refused_and_an_explicit_worktree_still_wins
    with_repo do |repo, map|
      add_worktree(repo, "b1", "wt-b1")
      add_worktree(repo, "other", "wt-other")
      item = Quartermaster::WorkItem.create("Mine", project: "WebApp", branch: "b1")
      runner = FakeRunner.new
      resolver = Quartermaster::TargetWorktree.new(project_map: map, runner: runner)

      error = assert_raises(ArgumentError) { resolver.materialize(item, branch: "other") }
      assert_equal "branch other is not linked to 'mine'", error.message
      assert_empty runner.calls
      Dir.mktmpdir do |elsewhere|
        assert_equal elsewhere, resolver.resolve(item, worktree: elsewhere, branch: "other").path
      end
    end
  end

  def test_a_failing_worktree_add_raises_with_gits_message
    with_repo do |repo, map|
      system("git", "-C", repo, "branch", "-q", "b1")
      item = Quartermaster::WorkItem.create("Failing", project: "WebApp", branch: "b1")
      runner = FakeRunner.new(%w[git worktree] => ["", "fatal: already exists", false])

      error = assert_raises(ArgumentError) do
        Quartermaster::TargetWorktree.new(project_map: map, runner: runner).materialize(item)
      end
      assert_includes error.message, "fatal: already exists"
      refute(runner.argvs.any? { |argv| argv.first == "app-test-db" })
    end
  end

  def test_a_failing_test_db_prepare_says_the_worktree_was_created
    with_repo do |repo, map|
      system("git", "-C", repo, "branch", "-q", "b1")
      item = Quartermaster::WorkItem.create("Half made", project: "WebApp", branch: "b1")
      runner = FakeRunner.new(%w[app-test-db prepare] => ["", "createdb: permission denied", false])

      error = assert_raises(ArgumentError) do
        Quartermaster::TargetWorktree.new(project_map: map, runner: runner).materialize(item)
      end
      assert_match(/\Acreated worktree .*b1, then app-test-db prepare failed: createdb: permission denied; run/,
                   error.message)
    end
  end
end

class TempBranchTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def test_temp_branches_stay_apart_from_branches_and_linking_promotes_them
    item = Quartermaster::WorkItem.create("Temp", project: "Other", branch: "feature")

    assert Quartermaster::WorkItem.find("temp").add_temp_branch("worktree-a")
    refute item.add_temp_branch("worktree-a")
    refute item.add_temp_branch("feature"), "a real branch is never also temp"
    assert_equal %w[feature], item.branches
    assert_equal %w[worktree-a], Quartermaster::WorkItem.find("temp").to_h["temp_branches"]

    item.link_branch("worktree-a")
    reloaded = Quartermaster::WorkItem.find("temp")
    assert_equal %w[feature worktree-a], reloaded.branches
    assert_empty reloaded.temp_branches
    refute reloaded.front.key?("temp_branches")
  end

  def test_link_branch_temp_on_the_cli
    Quartermaster::WorkItem.create("Cli temp", project: "Other", branch: "feature")

    stdout, = capture_io { Quartermaster::CLI.new.run(%w[link-branch cli-temp worktree-b --temp]) }

    assert_equal "cli-temp → temp: worktree-b\n", stdout
    assert_equal %w[worktree-b], Quartermaster::WorkItem.find("cli-temp").temp_branches
  end

  def test_the_session_start_hook_records_a_worktree_sessions_branch_as_temp
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      path = File.join(repo, ".claude", "worktrees", "scratch")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "worktree-scratch", path)
      Quartermaster::WorkItem.create("Hooked", project: "Other")

      _out, err, status = run_hook("hook-session-start",
                                   JSON.generate("session_id" => "sess-wt", "cwd" => path, "source" => "startup"),
                                   "QM_ITEM" => "hooked")
      run_hook("hook-session-start", JSON.generate("session_id" => "sess-main", "cwd" => repo, "source" => "startup"),
               "QM_ITEM" => "hooked")

      assert status.success?, err
      assert_equal %w[worktree-scratch], Quartermaster::WorkItem.find("hooked").temp_branches
    end
  end
end
