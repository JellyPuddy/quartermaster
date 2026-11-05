# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/branch_stats_test.rb`).
require_relative "test_helper"

class BranchStatsTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  SAMPLE = File.read(File.join(__dir__, "fixtures", "branch-stats-sample.md"))
  SCRIPT = Quartermaster::BranchStats::SCRIPT
  CLAUDE = %w[env QM_SKIP=1 claude].freeze

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  # A repo with a `feature` worktree one commit ahead of main, an item
  # linked to it, and a runner answering the stats script with the sample.
  def with_branch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "one.txt", "1\n")
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      yield repo, wt, item
    end
  end

  def commit(path, file, content)
    File.write(File.join(path, file), content)
    system("git", "-C", path, "add", file)
    system("git", "-C", path, *GIT_ID, "commit", "-q", "-m", "change #{file}")
  end

  def sha_of(path, rev) = `git -C #{path} rev-parse #{rev}`.strip

  def runner(responses = {}) = FakeRunner.new({ [SCRIPT] => [SAMPLE, "", true] }.merge(responses))

  def stats(runner) = Quartermaster::BranchStats.new(runner: runner, tmux: FakeTmux.new)

  def script_runs(runner) = runner.calls.count { |c| c[:argv].first == SCRIPT }

  def cache = JSON.parse(File.read(Quartermaster::BranchStats::CACHE_FILE))

  def test_parses_the_scripts_markdown_into_totals_categories_largest_files_and_commits
    parsed = Quartermaster::BranchStats.parse(SAMPLE)

    assert_equal %w[showcase-tour main ab75812d7d], parsed.values_at("branch", "base", "mergeBase")
    assert_equal({ "files" => 29, "add" => 2572, "del" => 62 }, parsed["totals"])
    assert_equal [["backend", 23, 2250, 52, 87], ["tests", 4, 249, 0, 9], ["docs", 2, 73, 10, 2]],
                 parsed["categories"].map { |c| c.values_at("name", "files", "add", "del", "share") }
    assert_equal 8, parsed["largest"].size
    assert_equal({ "path" => "showcase/shots/shots.yml", "add" => 239, "del" => 0 }, parsed["largest"].first)
    assert_equal({ "path" => "showcase/demo-world/lib/demo_world/transcript.rb", "add" => 130, "del" => 0 },
                 parsed["largest"].last)
    assert_equal %w[cb9082d c46251e ffd58eb 2dd3c2b 2786fde d6c2871 c662f2b 21f54db], parsed["commits"].map { |c| c["sha"] }
    row = parsed["commits"][2]
    assert_equal "Show the phone page, give each world its own chats, test the seeded data", row["subject"]
    assert_equal [5, 191, 8], row.values_at("files", "add", "del")
    assert_equal({ "backend" => { "add" => 48, "del" => 4 }, "tests" => { "add" => 114, "del" => 0 },
                   "docs" => { "add" => 29, "del" => 4 } }, row["categories"])
    assert_equal [7, 983, 0], parsed["commits"][4].values_at("files", "add", "del")
  end

  def test_the_script_is_the_bundled_skills_and_its_output_parses
    assert_equal File.expand_path("../skills/branch-stats/scripts/branch-stats.sh", __dir__), SCRIPT
    with_branch do |_repo, wt, _item|
      FileUtils.mkdir_p(File.join(wt, "spec"))
      commit(wt, "spec/one_spec.rb", "it\n")
      out, status = Open3.capture2(SCRIPT, "main", "feature", chdir: wt)
      assert status.success?, out
      parsed = Quartermaster::BranchStats.parse(out)
      assert_equal({ "files" => 2, "add" => 2, "del" => 0 }, parsed["totals"])
      assert_equal [["backend", 1], ["tests", 1]], parsed["categories"].map { |c| [c["name"], c["add"]] }
      assert_equal ["change one.txt", "change spec/one_spec.rb"], parsed["commits"].map { |c| c["subject"] }
    end
  end

  def test_a_subject_with_a_pipe_keeps_its_cells
    row = "| `abc1234` Split a | b apart | 2 | +3 / -1 | +3 / -1 |  |  |  |  |"
    parsed = Quartermaster::BranchStats.parse(SAMPLE.sub(/^\| `cb9082d`.*$/, row))

    assert_equal ["Split a | b apart", 2, 3, 1], parsed["commits"].first.values_at("subject", "files", "add", "del")
  end

  def test_runs_the_script_in_the_checkout_against_the_diff_base_and_caches_on_the_shas
    with_branch do |repo, wt, item|
      runner = runner()
      first = stats(runner).call(item)

      assert_equal [{ argv: [SCRIPT, "main", "feature"], chdir: wt }], runner.calls.select { |c| c[:argv].first == SCRIPT }
      assert_equal ["feature", "main", sha_of(wt, "HEAD"), sha_of(repo, "main")],
                   first.values_at("branch", "base", "head", "mergeBase")
      assert_equal SAMPLE, first["markdown"]
      assert_equal 2572, first["stats"]["totals"]["add"]
      assert_nil first["error"]

      again = stats(runner).call(item)
      assert_equal 1, script_runs(runner), "same head and merge base: a hit"
      assert_equal first["computedAt"], again["computedAt"]
    end
  end

  def test_a_new_head_or_merge_base_misses_and_replaces_the_branchs_one_entry
    with_branch do |repo, wt, item|
      runner = runner()
      stats(runner).call(item)
      commit(wt, "two.txt", "2\n")
      moved = stats(runner).call(item)
      commit(repo, "trunk.txt", "t\n")
      system("git", "-C", wt, *GIT_ID, "rebase", "-q", "main", exception: true)
      rebased = stats(runner).call(item)

      assert_equal 3, script_runs(runner)
      assert_equal sha_of(wt, "HEAD"), rebased["head"]
      refute_equal moved["mergeBase"], rebased["mergeBase"]
      assert_equal({ repo => ["feature"] }, cache["entries"].transform_values(&:keys))
      assert_equal rebased["head"], cache["entries"][repo]["feature"]["head"]
    end
  end

  def test_refresh_recomputes_and_drops_the_commentary
    with_branch do |_repo, _wt, item|
      runner = runner(CLAUDE => ["Commit two carries it.", "", true])
      subject = stats(runner)
      subject.call(item)
      subject.comment(subject.target(item))
      assert_equal "Commit two carries it.", subject.call(item)["commentary"]

      refreshed = subject.call(item, refresh: true)

      assert_equal 2, script_runs(runner)
      assert_nil refreshed["commentary"]
      assert_nil subject.call(item)["commentary"]
    end
  end

  def test_unparseable_output_keeps_the_markdown_with_no_stats
    with_branch do |_repo, _wt, item|
      result = stats(runner([SCRIPT] => ["something else entirely\n", "", true])).call(item)

      assert_equal "something else entirely\n", result["markdown"]
      assert_nil result["stats"]
      assert_nil result["error"]
    end
  end

  def test_a_failing_or_silent_script_shows_its_error_and_caches_nothing
    with_branch do |_repo, _wt, item|
      failing = runner([SCRIPT] => ["", "fatal: bad revision 'main'", false])
      result = stats(failing).call(item)

      assert_match(/branch-stats script failed: fatal: bad revision 'main'/, result["error"])
      assert_equal %w[feature main], result.values_at("branch", "base")
      assert_nil result["markdown"]
      refute File.exist?(Quartermaster::BranchStats::CACHE_FILE)

      silent = stats(runner([SCRIPT] => ["  \n", "", true])).call(item)
      assert_match(/it printed nothing/, silent["error"])
      refute File.exist?(Quartermaster::BranchStats::CACHE_FILE)
    end
  end

  def test_an_unreadable_or_foreign_version_cache_reads_as_empty
    with_branch do |_repo, _wt, item|
      runner = runner()
      Quartermaster.ensure_setup
      File.write(Quartermaster::BranchStats::CACHE_FILE, "{not json")
      stats(runner).call(item)
      File.write(Quartermaster::BranchStats::CACHE_FILE, JSON.generate("v" => 99, "entries" => cache["entries"]))
      stats(runner).call(item)

      assert_equal 2, script_runs(runner)
      assert_equal 1, cache["v"]
    end
  end

  def test_the_commentary_is_a_headless_haiku_call_over_the_markdown_stored_on_the_entry
    with_branch do |_repo, _wt, item|
      runner = runner(CLAUDE => ["  Commit c46251e carries the change.\n", "", true])
      subject = stats(runner)
      subject.call(item)

      result = subject.comment(subject.target(item))

      assert_equal({ "ok" => true, "message" => "feature: what stands out is ready" }, result)
      argv = runner.argvs.find { |a| a.first(3) == CLAUDE }
      assert_includes argv[4], SAMPLE
      assert_includes argv[4], "which commit carries the real change"
      assert_equal ["--model", "haiku", "--tools", "", "--strict-mcp-config", "--no-session-persistence"], argv[5..]
      assert_equal "Commit c46251e carries the change.", subject.call(item)["commentary"]
    end
  end

  def test_a_commentary_is_dropped_when_the_branch_moved_while_it_was_written
    with_branch do |_repo, wt, item|
      subject = nil
      moving = lambda do |_argv|
        commit(wt, "two.txt", "2\n")
        subject.call(item)
        ["Stale sentences.", "", true]
      end
      subject = stats(runner(CLAUDE => moving))
      subject.call(item)

      result = subject.comment(subject.target(item))

      assert_equal false, result["ok"]
      assert_match(/moved on/, result["error"])
      assert_nil subject.call(item)["commentary"]
    end
  end

  def test_a_commentary_needs_stats_for_the_current_head_and_a_failing_model_says_why
    with_branch do |_repo, _wt, item|
      subject = stats(runner(CLAUDE => ["", "rate limited", false]))
      assert_raises(ArgumentError) { subject.comment(subject.target(item)) }

      subject.call(item)
      error = assert_raises(ArgumentError) { subject.comment(subject.target(item)) }
      assert_match(/claude -p failed: rate limited/, error.message)
    end
  end

  def get(gui, query) = JSON.parse(gui.respond("GET", "/api/branch-stats/feat#{query}", ok_host, "")[2])

  def test_the_gui_get_serves_the_stats_payload_and_refresh_recomputes
    with_branch do |_repo, wt, _item|
      runner = runner(["curl"] => ["", "", false], %w[pf status] => ["", "", false])
      gui = Quartermaster::Gui.new(port: 4567, runner: runner, tmux: FakeTmux.new)

      payload = get(gui, "?branch=feature")

      assert_equal %w[ok branch base head mergeBase computedAt markdown stats commentary commentaryAt error jobKey
                      commentaryRunning].sort, payload.keys.sort
      assert_equal [true, "feature", "main", sha_of(wt, "HEAD"), false],
                   payload.values_at("ok", "branch", "base", "head", "commentaryRunning")
      assert_equal 29, payload["stats"]["totals"]["files"]
      get(gui, "?branch=feature")
      assert_equal 1, script_runs(runner)
      get(gui, "?branch=feature&refresh=1")
      assert_equal 2, script_runs(runner)

      refused = get(gui, "?branch=nope")
      assert_equal false, refused["ok"]
      assert_match(/nope is not a linked branch/, refused["error"])
    end
  end

  def test_the_gui_action_runs_the_commentary_as_a_background_job_shown_while_it_runs
    with_branch do |_repo, _wt, _item|
      gate = Queue.new
      runner = runner(["curl"] => ["", "", false], %w[pf status] => ["", "", false],
                      CLAUDE => ->(_argv) { gate.pop && ["Tests are a tenth of it.", "", true] })
      gui = Quartermaster::Gui.new(port: 4567, runner: runner, tmux: FakeTmux.new)
      get(gui, "")

      body = JSON.generate("cmd" => "branch-stats-commentary", "slug" => "feat", "args" => { "branch" => "feature" })
      started = JSON.parse(gui.respond("POST", "/api/action", ok_host, body)[2])
      assert_equal({ "ok" => true, "background" => true }, started)
      running = get(gui, "")
      assert running["commentaryRunning"]
      state = JSON.parse(gui.respond("GET", "/api/state", ok_host, "")[2])
      assert_includes state["jobs"].map { |j| j["key"] }, running["jobKey"]

      gate << true
      done = Timeout.timeout(5) do
        loop do
          payload = get(gui, "")
          break payload unless payload["commentaryRunning"]

          sleep 0.01
        end
      end
      assert_equal "Tests are a tenth of it.", done["commentary"]
    end
  end
end
