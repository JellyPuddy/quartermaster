# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gh_stack_test.rb`).
require_relative "test_helper"

class GhStackTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def test_parses_stacks_bottom_to_top_with_their_prs
    stacks = Quartermaster::GhStack.parse(JSON.generate(
      "schemaVersion" => 1,
      "stacks" => [{ "trunk" => { "branch" => "main" },
                     "branches" => [{ "branch" => "a", "pullRequest" => { "number" => 1, "url" => "u1" } },
                                    { "branch" => "b" }] }]
    ))

    assert_equal [%w[a b]], stacks.map { |s| s.map(&:branch) }
    assert_equal 1, stacks[0][0].pr_number
    assert_equal "u1", stacks[0][0].pr_url
    assert_nil stacks[0][1].pr_number
  end

  def test_tolerates_garbage_unknown_schemas_and_malformed_entries
    assert_empty Quartermaster::GhStack.parse("not json")
    assert_empty Quartermaster::GhStack.parse("[1, 2]")
    assert_empty Quartermaster::GhStack.parse(JSON.generate("schemaVersion" => 7, "stacks" => "nope"))

    future = Quartermaster::GhStack.parse(JSON.generate(
      "schemaVersion" => 2, "extra" => true,
      "stacks" => [{ "branches" => [{ "branch" => "x", "new_field" => 1 }, { "nobranch" => 1 }, "junk"] },
                   { "branches" => [] }, "junk"]
    ))
    assert_equal [["x"]], future.map { |s| s.map(&:branch) }
  end

  def test_a_repo_without_a_stack_file_has_no_stacks
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      assert_empty Quartermaster::GhStack.for_root(repo).stacks
      assert_empty Quartermaster::GhStack.for_root(File.join(dir, "missing")).stacks
    end
  end

  def test_reads_the_stack_file_from_the_common_git_dir_even_via_a_worktree
    Dir.mktmpdir do |dir|
      repo = make_repo(File.join(dir, "repo").tap { |p| FileUtils.mkdir_p(p) })
      worktree = add_worktree(repo, "feature", "wt")
      write_stack(repo, %w[feature top])

      assert_equal [%w[feature top]], Quartermaster::GhStack.for_root(worktree).stacks.map { |s| s.map(&:branch) }
    end
  end

  def test_stack_for_picks_the_stack_of_the_newest_linked_branch
    stacks = Quartermaster::GhStack.new(Quartermaster::GhStack.parse(JSON.generate(
      "stacks" => [{ "branches" => [{ "branch" => "a1" }, { "branch" => "a2" }] },
                   { "branches" => [{ "branch" => "b1" }] }]
    )))

    assert_equal %w[b1], stacks.stack_for(%w[a1 b1]).map(&:branch)
    assert_equal %w[a1 a2], stacks.stack_for(%w[b9 a2]).map(&:branch)
    assert_nil stacks.stack_for(%w[zz])
  end

  def test_sync_auto_links_the_whole_stack_once_and_is_idempotent
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      write_stack(repo, %w[s1 s2 s3], %w[other])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Stacked", project: "MyApp", branch: "s2")

      stack = Quartermaster::GhStack.sync(item, project_map: map)

      assert_equal %w[s1 s2 s3], stack.map(&:branch)
      assert_equal %w[s2 s1 s3], Quartermaster::WorkItem.find("stacked").branches
      before = File.read(Quartermaster::WorkItem.path_for("stacked"))
      assert_empty Quartermaster::GhStack.for_root(repo).link_into(Quartermaster::WorkItem.find("stacked"))
      Quartermaster::GhStack.sync(Quartermaster::WorkItem.find("stacked"), project_map: map)
      assert_equal before, File.read(Quartermaster::WorkItem.path_for("stacked"))
    end
  end

  def test_sync_leaves_items_outside_any_stack_alone
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      write_stack(repo, %w[s1 s2])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Loner", project: "MyApp", branch: "solo")

      assert_nil Quartermaster::GhStack.sync(item, project_map: map)
      assert_equal %w[solo], Quartermaster::WorkItem.find("loner").branches
    end
  end

  def test_stack_line_marks_only_the_layers_that_need_a_restack
    chain = { "trunk" => "main", "layers" => [
      { "branch" => "a", "pr_number" => 1, "needsRestack" => false },
      { "branch" => "b", "pr_number" => nil, "needsRestack" => true }
    ] }

    assert_equal "stack: main → a (#1) → b ⟳", Quartermaster::CLI.new.send(:stack_line, chain)
  end

  def counting_git(calls)
    lambda do |cwd, *args|
      calls << args
      Quartermaster.git(cwd, *args)
    end
  end

  def test_chains_list_every_touched_stack_newest_linked_first_then_loose_branches
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      write_stack(repo, %w[a1 a2], %w[b1], %w[untouched])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Straddle", project: "MyApp", branch: "loose1")
      item.link_branches(%w[a2 b1 main loose2])

      chains = Quartermaster::GhStack.chains(Quartermaster::WorkItem.find("straddle"), project_map: map)

      assert_equal [%w[stack b1], %w[stack a1 a2], %w[loose loose2], %w[loose loose1]],
                   chains.map { |c| [c["kind"], *c["layers"].map { |l| l["branch"] }] }
      assert_equal %w[main main main main], chains.map { |c| c["trunk"] }
      assert_equal [101, "https://pr/101"], chains[1]["layers"][1].values_at("pr_number", "pr_url")
    end
  end

  def test_chains_take_a_pr_gh_stack_has_not_recorded_from_pr_status
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      File.write(File.join(repo, ".git", "gh-stack"), JSON.generate(
        "stacks" => [{ "branches" => [{ "branch" => "s1" }, { "branch" => "s2", "pullRequest" => { "number" => 9, "url" => "u9" } }] }]
      ))
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Linked", project: "MyApp", branch: "s2")
      item.link_branch("solo")
      pr = Quartermaster::PrStatus.new(fetcher: ->(_i, b) { { "state" => "OPEN", "number" => b.size, "url" => "u-#{b}" } })
      links = %w[s1 s2 solo].to_h { |b| pr.state_for(item, b) && [b, pr.link_for(item, b)] }

      chains = Quartermaster::GhStack.chains(Quartermaster::WorkItem.find("linked"), project_map: map, pr_links: links)

      assert_equal [[2, "u-s1"], [9, "u9"], [4, "u-solo"]],
                   chains.flat_map { |c| c["layers"] }.map { |l| l.values_at("pr_number", "pr_url") }
      assert_nil Quartermaster::PrStatus.new(fetcher: ->(*) { "OPEN" }).tap { |p| p.state_for(item, "plain") }.link_for(item, "plain")
    end
  end

  def test_layer_facts_count_ahead_and_flag_a_restack_only_above_another_stack_branch
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      branch_off(repo, "a", "main")
      commit_on(repo, "a", "a1")
      commit_on(repo, "a", "a2")
      branch_off(repo, "b", "a")
      commit_on(repo, "b", "b1")
      branch_off(repo, "c", "b")
      commit_on(repo, "c", "c1")
      commit_on(repo, "a", "a3 after b branched")
      commit_on(repo, "main", "trunk moved")
      write_stack(repo, %w[a b c])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Facts", project: "MyApp", branch: "c")

      layers = Quartermaster::GhStack.chains(item, project_map: map, pr_states: { "a" => "MERGED", "b" => "OPEN" })
                                     .first["layers"]

      assert_equal [["a", "main", 3, false, true, "MERGED"], ["b", "a", 1, true, false, "OPEN"], ["c", "b", 1, false, false, nil]],
                   layers.map { |l| l.values_at("branch", "parent", "ahead", "needsRestack", "merged", "prState") }
    end
  end

  def test_layer_facts_fall_back_to_origin_refs_and_read_packed_refs
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      branch_off(repo, "a", "main")
      commit_on(repo, "a", "a1")
      sha = Quartermaster.git(repo, "rev-parse", "a")
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/b", sha)
      system("git", "-C", repo, "pack-refs", "--all")
      write_stack(repo, %w[a b gone])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Remote", project: "MyApp", branch: "b")

      layers = Quartermaster::GhStack.chains(item, project_map: map).first["layers"]

      assert_equal [["a", 1, false], ["b", 0, false], ["gone", nil, false]],
                   layers.map { |l| l.values_at("branch", "ahead", "needsRestack") }
    end
  end

  def test_an_unchanged_repo_spawns_no_git_for_layer_facts
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      branch_off(repo, "a", "main")
      commit_on(repo, "a", "a1")
      branch_off(repo, "b", "a")
      commit_on(repo, "b", "b1")
      write_stack(repo, %w[a b])
      map = Quartermaster::ProjectMap.new(roots: { "MyApp" => repo })
      item = Quartermaster::WorkItem.create("Cached", project: "MyApp", branch: "b")
      calls = []

      first = Quartermaster::GhStack.chains(item, project_map: map, git: counting_git(calls))
      assert(calls.any? { |args| args.first == "rev-list" })
      assert(calls.any? { |args| args.first == "merge-base" })

      calls.clear
      assert_equal first, Quartermaster::GhStack.chains(item, project_map: map, git: counting_git(calls))
      assert_empty calls

      commit_on(repo, "b", "b2")
      layers = Quartermaster::GhStack.chains(item, project_map: map, git: counting_git(calls)).first["layers"]
      assert_equal 2, layers[1]["ahead"]
      assert_equal 2, calls.size, "only the moved layer's facts are recomputed"
    end
  end
end
