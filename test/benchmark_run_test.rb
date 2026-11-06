# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/benchmark_run_test.rb`).
require_relative "test_helper"

class BenchmarkRunTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  RUN = Quartermaster::BenchmarkRun
  PIPELINE = Quartermaster::BenchmarkPipeline
  NOW = Time.utc(2026, 11, 4, 13, 45, 7)
  ID = "20261104_134507"
  CLONE = "app_benchmark_20261104_134507"
  READ_ONLY = "postgres:///app_benchmark?options=-c%20default_transaction_read_only%3Don"
  TABLE = "| subject | case | main ms | feature ms | same ids |\n|---|---|---:|---:|---|\n| u1/p2 | list | 41.2 | 12.0 | ✓ |\n"
  PLAN = { "t" => "plan", "stages" => [{ "name" => "main" }, { "name" => "feature" }],
           "cases" => [{ "subject" => "u1/p2", "case" => "list", "why" => "heaviest share holder" }] }.freeze

  # Records what a finished run announces.
  class FakeNotifier
    attr_reader :announced

    def initialize = @announced = []
    def announce(**options) = @announced << options
  end

  def commit(path, file, content)
    File.write(File.join(path, file), content)
    system("git", "-C", path, "add", file)
    system("git", "-C", path, *GIT_ID, "commit", "-q", "-m", "change #{file}")
  end

  def sha_of(path, rev) = `git -C #{path} rev-parse #{rev}`.strip

  # A repo with a `feature` worktree one commit ahead of main and an item linked to it.
  def with_branch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      configure_projects({ "my-app" => benchmarked_project(repo) })
      wt = add_worktree(repo, "feature", "wt-feature")
      commit(wt, "one.txt", "1\n")
      item = Quartermaster::WorkItem.create("Speed up", project: "my-app", branch: "feature")
      yield repo, wt, item
    end
  end

  # live: run ids whose pipeline counts as running.
  def subject(runner: FakeRunner.new, live: [], spawned: [], killed: [], now: NOW)
    RUN.new(runner: runner, tmux: FakeTmux.new, now: -> { now },
            spawner: ->(dir) { spawned << dir && 4242 },
            process_line: ->(pid) { pid == 4242 && live.any? ? "ruby qm bench-run /x/#{live.join(" ")}" : nil },
            killer: ->(signal, pgid) { killed << [signal, pgid] })
  end

  def meta(id = ID) = RUN.read(id)
  def dir(id = ID) = RUN.dir_for(id)

  # A runner standing in for the agent, rails and the verdict call; each
  # records the run's state when it ran and writes what the real one would.
  # extra: longer argv prefixes answered before these.
  def pipeline_runner(states, clone: false, cwd: nil, rails: true, extra: {})
    FakeRunner.new(extra.merge(["env"] => lambda do |argv|
      states << meta["state"]
      if argv.include?("--allowedTools")
        File.write(File.join(dir, "bench.rb"), "puts 1\n")
        File.write(File.join(dir, "run.json"), JSON.generate("cwd" => cwd, "clone" => clone))
        File.write(File.join(dir, "events.jsonl"), "#{JSON.generate(PLAN)}\n", mode: "a")
        ["{\"type\":\"result\"}\n", "", true]
      elsif argv.include?("runner")
        File.write(File.join(dir, "events.jsonl"), "#{JSON.generate("t" => "done")}\n", mode: "a")
        rails ? [TABLE, "case done\n", true] : ["", "PG::ConnectionBad: boom\n", false]
      else
        ["Feature is about 3x faster on the list.\nIds match.", "", true]
      end
    end))
  end

  def run_pipeline(runner, notifier: FakeNotifier.new, free: 100 * 1024**3)
    PIPELINE.new(dir, runner: runner, notifier: notifier, free_bytes: -> { free }, now: -> { NOW + 600 }).call
    notifier
  end

  def test_start_makes_the_run_folder_and_meta_and_spawns_the_pipeline
    with_branch do |repo, wt, item|
      spawned = []
      started = subject(spawned: spawned).start(item, branch: "feature", request: "  the list  ", model: "sonnet")

      assert_equal [dir], spawned
      assert File.directory?(File.join(dir, "plans"))
      assert_equal started, meta
      assert_equal [1, ID, item.slug, "my-app", "app_benchmark", repo, wt, "feature", "the list", "sonnet", "2026-11-04T13:45:07Z", nil,
                    "planning", nil, 4242, sha_of(wt, "HEAD"), nil],
                   meta.values_at("v", "id", "slug", "project", "database", "root", "checkout", "branch", "request", "model", "startedAt",
                                  "finishedAt", "state", "error", "pid", "head", "rerunOf")
      assert_equal [{ "name" => "main", "ref" => "main", "sha" => sha_of(repo, "main") },
                    { "name" => "feature", "ref" => "feature", "sha" => sha_of(wt, "HEAD") }], meta["stages"]
      prompt = meta["prompt"]
      assert_includes prompt, "for the branch `feature`"
      assert_includes prompt, "/skills/bench/SKILL.md"
      assert_includes prompt, "/skills/bench/bin/example_bench.rb"
      assert_includes prompt, "- feature: feature @ #{sha_of(wt, "HEAD")}"
      assert_includes prompt, "What to benchmark: the list"
      assert_includes prompt, "The run folder is #{dir}"
      assert_includes prompt, "#{CLONE} and drops it afterwards"
      assert_includes prompt, "DATABASE_URL='#{READ_ONLY}'"
      assert_includes prompt, "Do not measure"
      assert_includes prompt, "BENCH_DRY=1 DATABASE_URL='#{READ_ONLY}' bin/rails runner $QM_BENCH_DIR/bench.rb"
      assert_includes prompt, "until it exits 0"
      assert_includes prompt, "Keep the example's dry mode"
      assert_includes prompt, "realtime_ms.\n   Use nothing outside the app's bundle."
      assert_includes prompt, %({"cwd": "#{wt}", "clone": false})
      assert_includes prompt, "Protocol step 2"
      assert_includes prompt, "never rely on the checkout for main's code"
      assert_includes prompt, "Never check out a branch or create a worktree"
      refute_includes prompt, "main checkout"
    end
  end

  def test_an_empty_request_asks_the_agent_to_work_it_out_and_a_bad_model_is_refused
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      assert_includes meta["prompt"], "What to benchmark: work out what this branch's changes make slower or faster"
      assert_equal "opus", meta["model"]
      assert_raises(ArgumentError) { subject.start(item, branch: "feature", model: "haiku") }
    end
  end

  def test_a_stacked_branch_gets_main_then_each_layer_up_to_itself
    with_branch do |repo, wt, item|
      branch_off(repo, "lower", "main")
      commit_on(repo, "lower", "lower work")
      branch_off(repo, "upper", "feature")
      write_stack(repo, %w[lower feature upper])

      subject.start(item, branch: "feature")

      assert_equal [%w[main main], %w[#100 lower], %w[#101 feature]], meta["stages"].map { |s| s.values_at("name", "ref") }
      assert_equal [sha_of(repo, "main"), sha_of(repo, "lower"), sha_of(wt, "HEAD")], meta["stages"].map { |s| s["sha"] }
    end
  end

  def test_one_run_at_a_time_and_a_dead_pipeline_reads_as_failed
    with_branch do |_repo, _wt, item|
      subject(live: [ID]).start(item, branch: "feature")
      busy = subject(live: [ID]).busy
      assert_equal({ "id" => ID, "slug" => item.slug, "branch" => "feature", "state" => "planning" }, busy)

      error = assert_raises(ArgumentError) { subject(live: [ID]).start(item, branch: "feature") }
      assert_match(/already running: feature \(#{item.slug}, run #{ID}\)/, error.message)

      dead = subject(live: [])
      assert_nil dead.busy
      assert_equal %w[failed pipeline\ died], dead.effective(meta).values_at("state", "error")
      second = dead.start(item, branch: "feature")
      assert_equal "#{ID}_2", second["id"], "same second: the id takes a suffix"
    end
  end

  def test_a_pid_whose_command_line_lacks_the_run_id_is_not_the_pipeline
    with_branch do |_repo, _wt, item|
      subject(live: ["20990101_000000"]).start(item, branch: "feature")

      assert_nil subject(live: ["20990101_000000"]).busy
      assert_nil subject(live: ["#{ID}_2"]).busy, "a later run of the same second is another run"
    end
  end

  def test_a_run_with_no_pid_yet_is_live_for_thirty_seconds_after_it_started
    with_branch do |_repo, _wt, item|
      FileUtils.mkdir_p(dir)
      RUN.write_meta(dir, { "v" => 1, "id" => ID, "slug" => item.slug, "branch" => "feature", "state" => "planning",
                            "startedAt" => "2026-11-04T13:45:07Z", "pid" => nil })

      within = subject(now: NOW + 29)
      assert_equal ID, within.busy&.fetch("id")
      assert_equal "planning", within.effective(meta)["state"]
      error = assert_raises(ArgumentError) { within.start(item, branch: "feature") }
      assert_match(/already running/, error.message)

      after = subject(now: NOW + 30)
      assert_nil after.busy
      assert_equal %w[failed pipeline\ died], after.effective(meta).values_at("state", "error")

      killed = []
      subject(killed: killed, now: NOW + 29).cancel(ID)
      assert_empty killed, "no pid yet, nothing to kill"
      assert_equal "cancelled", meta["state"]
    end
  end

  def test_the_pipeline_plans_measures_read_only_and_writes_the_verdict
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature", model: "sonnet")
      states = []
      runner = pipeline_runner(states, cwd: wt)
      notifier = run_pipeline(runner)

      assert_equal %w[planning measuring verdict], states
      agent, rails, verdict = runner.calls
      assert_equal ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{dir}", "QM_BENCH_RUN=#{ID}", "claude", "-p", meta["prompt"],
                    "--model", "sonnet", "--allowedTools", "Read,Grep,Glob,Write,Edit,Bash", "--add-dir", dir,
                    "--output-format", "stream-json", "--verbose", "--strict-mcp-config"], agent[:argv]
      assert_equal [wt, File.join(dir, "agent.jsonl")], agent.values_at(:chdir, :out)
      assert_equal ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{dir}", "QM_BENCH_RUN=#{ID}", "DATABASE_URL=#{READ_ONLY}",
                    "bin/rails", "runner", File.join(dir, "bench.rb")], rails[:argv]
      assert_equal [wt, File.join(dir, "bench.out"), File.join(dir, "bench.log")], rails.values_at(:chdir, :out, :err)
      assert_equal ["--model", "sonnet", "--tools", "", "--strict-mcp-config", "--no-session-persistence"], verdict[:argv][5..]
      assert_includes verdict[:argv][4], "Timings move 20-40%"
      assert_includes verdict[:argv][4], "- u1/p2 / list: heaviest share holder"
      assert_includes verdict[:argv][4], TABLE
      assert_equal 3, runner.calls.size, "no createdb or dropdb for a read-only run"

      assert_equal TABLE, File.read(File.join(dir, "bench.out"))
      assert_equal "Feature is about 3x faster on the list.\nIds match.\n", File.read(File.join(dir, "verdict.md"))
      assert_equal ["done", "2026-11-04T13:55:07Z", nil], meta.values_at("state", "finishedAt", "error")
      assert_equal [{ title: "Benchmark done · feature", body: "Feature is about 3x faster on the list. Ids match.",
                      group: "qm-bench-#{ID}", click: ["open-chat", item.slug, "--benchmark", "feature"] }],
                   notifier.announced
      note = Quartermaster::WorkItem.find(item.slug).notes.last
      assert_equal ["history", "Benchmark feature: Feature is about 3x faster on the list. Ids match. (run #{ID})"],
                   [note.kind, note.text]
    end
  end

  def test_a_writing_plan_runs_on_its_own_clone_and_drops_it
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      runner = pipeline_runner([], cwd: wt, clone: true)
      run_pipeline(runner)

      argvs = runner.argvs.reject { |a| a.first == "env" && a.include?("claude") }
      assert_equal [["createdb", "-T", "app_benchmark", CLONE]], argvs.first(1)
      assert_includes argvs[1], "DATABASE_URL=postgres:///#{CLONE}"
      assert_equal ["dropdb", "--if-exists", "--force", CLONE], argvs[2]
      assert_equal "done", meta["state"]
    end
  end

  def test_a_failing_measurement_still_drops_the_clone_and_announces_the_failure
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      runner = pipeline_runner([], cwd: wt, clone: true, rails: false)
      notifier = run_pipeline(runner)

      assert_equal ["dropdb", "--if-exists", "--force", CLONE], runner.argvs.last
      assert_equal "failed", meta["state"]
      assert_match(/bin\/rails runner failed: PG::ConnectionBad: boom/, meta["error"])
      assert_equal "Benchmark failed · feature", notifier.announced.first[:title]
      refute File.exist?(File.join(dir, "verdict.md"))
      assert_match(/failed: bin\/rails runner failed/, Quartermaster::WorkItem.find(item.slug).notes.last.text)
    end
  end

  DROP_FAILED = { ["dropdb"] => ["", "dropdb: error: database removal failed: ERROR:  must be owner of database\n", false] }.freeze
  DROP_WARNING = "dropdb failed: dropdb: error: database removal failed: ERROR:  must be owner of database — clone " \
                 "#{CLONE} is still on disk; drop it with: dropdb #{CLONE} — see pipeline.log".freeze

  def test_a_failed_clone_drop_leaves_a_done_run_done_with_a_warning
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(pipeline_runner([], cwd: wt, clone: true, extra: DROP_FAILED))

      assert_equal ["done", nil, DROP_WARNING], meta.values_at("state", "error", "warning")
      assert_includes File.read(File.join(dir, "pipeline.log")), "must be owner of database"
    end
  end

  def test_a_failed_clone_drop_keeps_the_runs_own_error_and_adds_a_warning
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(pipeline_runner([], cwd: wt, clone: true, rails: false, extra: DROP_FAILED))

      assert_equal "failed", meta["state"]
      assert_match(/\Abin\/rails runner failed: PG::ConnectionBad: boom/, meta["error"])
      assert_equal DROP_WARNING, meta["warning"]
    end
  end

  def test_a_failed_createdb_claims_no_clone_and_drops_none
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      createdb_failed = { ["createdb"] => ["", "createdb: error: could not connect to server: No such file or directory\n", false] }
      runner = pipeline_runner([], cwd: wt, clone: true, extra: DROP_FAILED.merge(createdb_failed))
      run_pipeline(runner)

      assert_equal "failed", meta["state"]
      assert_match(/\Acreatedb #{CLONE} failed: createdb: error: could not connect to server/, meta["error"])
      assert_nil meta["warning"]
      refute(runner.argvs.any? { |a| a.first == "dropdb" })
    end
  end

  def test_a_cancel_whose_clone_drop_fails_warns
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      RUN.update(ID) { |current| current.merge("state" => "measuring") }
      subject(runner: FakeRunner.new(DROP_FAILED)).cancel(ID)

      assert_equal ["cancelled", nil, DROP_WARNING], meta.values_at("state", "error", "warning")
    end
  end

  def test_a_cancel_before_measuring_claims_no_clone_when_dropdb_fails
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      subject(runner: FakeRunner.new(DROP_FAILED)).cancel(ID)

      assert_equal ["cancelled", nil], meta.values_at("state", "warning")
    end
  end

  def test_the_same_failed_clone_drop_warns_once
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      2.times { RUN.clone_left(ID, DROP_FAILED[["dropdb"]][1]) }

      assert_equal DROP_WARNING, meta["warning"]
    end
  end

  def test_a_failed_runner_names_its_exception_line_not_the_stack_tail
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      stderr = File.read(File.join(__dir__, "fixtures", "benchmark-load-error-bench.log"))
      runner = pipeline_runner([], cwd: wt, extra: { ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{dir}", "QM_BENCH_RUN=#{ID}",
                                                       "DATABASE_URL=#{READ_ONLY}"] => ["", stderr, false] })
      run_pipeline(runner)

      assert_equal "bin/rails runner failed: /Users/dev/.asdf/installs/ruby/4.0.9/lib/ruby/4.0.0/" \
                   "bundled_gems.rb:60:in 'Kernel.require': cannot load such file -- benchmark (LoadError) " \
                   "— see bench.log", meta["error"]
      assert_includes File.read(File.join(dir, "pipeline.log")), "from bin/rails:6:in '<main>'"
    end
  end

  def test_a_long_error_line_loses_its_front_at_a_word_boundary
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      line = "#{(1..80).map { |n| "dir#{n}" }.join("/")}/bench.rb:3:in 'Foo#bar': undefined method 'baz' (NoMethodError)"
      runner = pipeline_runner([], cwd: wt, extra: { ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{dir}", "QM_BENCH_RUN=#{ID}",
                                                       "DATABASE_URL=#{READ_ONLY}"] => ["", "#{line}\n", false] })
      run_pipeline(runner)

      error = meta["error"]
      assert_operator error.length, :<=, 300
      assert_match(%r{\Abin/rails runner failed: …dir\d+/}, error)
      assert error.end_with?("/bench.rb:3:in 'Foo#bar': undefined method 'baz' (NoMethodError) — see bench.log")
    end
  end

  def test_a_failed_agent_names_its_cause_and_pipeline_log
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      runner = FakeRunner.new(["env"] => ["", "API Error: 401 invalid x-api-key\n", false])
      run_pipeline(runner)

      assert_equal "the planning agent failed: API Error: 401 invalid x-api-key — see pipeline.log", meta["error"]
    end
  end

  def test_a_failed_verdict_names_its_cause_and_keeps_its_stderr_in_pipeline_log
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      verdict = ["env", "QM_SKIP=1", "claude", "-p"]
      runner = pipeline_runner([], cwd: wt, extra: { verdict => ["", "warning: slow\nRateLimitError: try later\n", false] })
      run_pipeline(runner)

      assert_equal "the verdict call failed: RateLimitError: try later — see pipeline.log", meta["error"]
      assert_includes File.read(File.join(dir, "pipeline.log")), "warning: slow"
    end
  end

  def test_a_silent_agent_failure_points_at_its_transcript
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(FakeRunner.new(["env"] => ["{\"type\":\"result\",\"is_error\":true}\n", "", false]))

      assert_equal "the planning agent failed: it printed nothing — see agent.jsonl", meta["error"]
    end
  end

  def test_a_clone_needs_twenty_gigabytes_free
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      runner = pipeline_runner([], cwd: wt, clone: true)
      run_pipeline(runner, free: 19 * 1024**3)

      assert_match(/only 19 GB free/, meta["error"])
      refute(runner.argvs.any? { |a| a.first == "createdb" || a.include?("runner") })
    end
  end

  def test_an_agent_that_writes_no_run_json_fails_the_run
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      runner = FakeRunner.new(["env"] => ["", "", true])
      run_pipeline(runner)

      assert_equal ["failed", "the planning agent wrote no bench.rb"], meta.values_at("state", "error")
      assert_equal 1, runner.calls.size
    end
  end

  def test_cancel_kills_the_process_group_and_drops_only_its_own_clone
    with_branch do |_repo, _wt, item|
      killed = []
      runner = FakeRunner.new
      subject(live: [ID]).start(item, branch: "feature")
      subject(runner: runner, live: [ID], killed: killed).cancel(ID)

      assert_equal [["TERM", -4242]], killed
      assert_equal [["dropdb", "--if-exists", "--force", CLONE]], runner.argvs
      assert_equal ["cancelled", "2026-11-04T13:45:07Z"], meta.values_at("state", "finishedAt")

      notifier = run_pipeline(pipeline_runner([]))
      assert_equal "cancelled", meta["state"], "the dying pipeline writes no other state"
      assert_empty notifier.announced
      assert_raises(ArgumentError) { subject.cancel(ID) }
    end
  end

  def test_cancelling_a_dead_run_kills_nothing
    with_branch do |_repo, _wt, item|
      killed = []
      subject.start(item, branch: "feature")
      subject(killed: killed).cancel(ID)

      assert_empty killed
      assert_equal "cancelled", meta["state"]
    end
  end

  def test_a_rerun_measures_the_same_script_again_without_the_agent
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(pipeline_runner([], cwd: wt))
      later = subject(now: NOW + 3600)
      rerun = later.rerun(ID)

      new_id = "20261104_144507"
      assert_equal [new_id, ID, "measuring", "feature"], rerun.values_at("id", "rerunOf", "state", "branch")
      assert_equal meta["stages"], rerun["stages"]
      %w[bench.rb run.json].each { |f| assert_equal File.read(File.join(dir, f)), File.read(File.join(dir(new_id), f)) }
      assert_equal [PLAN], PIPELINE.events(dir(new_id))

      runner = pipeline_runner([], cwd: wt)
      PIPELINE.new(dir(new_id), runner: runner, notifier: FakeNotifier.new, free_bytes: -> { 0 }).call
      refute(runner.argvs.any? { |a| a.include?("--allowedTools") }, "no agent")
      assert_equal "done", meta(new_id)["state"]
    end
  end

  def test_a_rerun_is_refused_once_a_stage_moved
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(pipeline_runner([], cwd: wt))
      commit(wt, "two.txt", "2\n")

      error = assert_raises(ArgumentError) { subject(now: NOW + 60).rerun(ID) }
      assert_match(/feature moved since it ran/, error.message)
    end
  end

  def test_a_rerun_waits_its_turn_too
    with_branch do |_repo, wt, item|
      subject.start(item, branch: "feature")
      run_pipeline(pipeline_runner([], cwd: wt))
      busy = "20261104_134607"
      subject(live: [busy], now: NOW + 60).start(item, branch: "feature")

      error = assert_raises(ArgumentError) { subject(live: [busy], now: NOW + 120).rerun(ID) }
      assert_match(/already running: feature/, error.message)
    end
  end

  def test_a_project_without_benchmark_settings_is_refused
    with_branch do |repo, _wt, _item|
      configure_projects({ "my-app" => repo })
      other = Quartermaster::WorkItem.create("Plain", project: "my-app", branch: "feature")
      spawned = []

      error = assert_raises(ArgumentError) { subject(spawned: spawned).start(other, branch: "feature") }
      assert_equal "my-app has no benchmarks: run `qm config set projects.my-app.benchmark.database <database>` and " \
                   "`qm config set projects.my-app.benchmark.skill <skill folder>`", error.message
      assert_empty spawned
    end
  end

  # Notes spanning lines stay inside the prompt's numbered bench.rb step.
  def test_multi_line_notes_are_indented_under_the_script_step
    with_branch do |repo, _wt, item|
      project = benchmarked_project(repo)
      project["benchmark"]["notes"] = "Use nothing outside the bundle:\nRuby dropped `benchmark`.\n"
      configure_projects({ "my-app" => project })

      prompt = subject.start(item, branch: "feature")["prompt"]
      assert_includes prompt, "realtime_ms.\n   Use nothing outside the bundle:\n   Ruby dropped `benchmark`.\n2. One `plan` event"
    end
  end

  def test_benchmarks_need_both_a_database_and_a_skill
    settings = ->(value) { Quartermaster::ProjectSettings.new("my-app", "root" => "/r", "benchmark" => value).benchmark }
    assert_equal ["app_benchmark", "/skills/bench", nil],
                 settings.call("database" => "app_benchmark", "skill" => "/skills/bench").to_a
    assert_nil settings.call("database" => "app_benchmark")
    assert_nil settings.call("skill" => "/skills/bench")
    assert_nil settings.call("database" => "app bench; drop", "skill" => "/skills/bench"), "not a database name"
    assert_nil settings.call("app_benchmark")
  end

  # The pipeline, cancel and re-run act on the database the run started
  # with, whatever config.yml says by then.
  def test_a_run_keeps_the_database_it_started_with
    with_branch do |repo, wt, item|
      subject.start(item, branch: "feature")
      configure_projects({ "my-app" => benchmarked_project(repo).merge("benchmark" => { "database" => "other_db", "skill" => "/s" }) })
      runner = pipeline_runner([], cwd: wt, clone: true)
      run_pipeline(runner)

      assert_equal [["createdb", "-T", "app_benchmark", CLONE]], runner.argvs.select { |a| a.first == "createdb" }
      assert_equal "app_benchmark", subject(now: NOW + 3600).rerun(ID)["database"]
    end
  end

  # A meta from before runs recorded their database falls back to its project's.
  def test_an_older_run_without_a_database_uses_its_projects
    with_branch do |_repo, _wt, item|
      subject.start(item, branch: "feature")
      RUN.update(ID) { |current| current.except("database") }
      runner = FakeRunner.new
      subject(runner: runner).cancel(ID)

      assert_equal [["dropdb", "--if-exists", "--force", CLONE]], runner.argvs
    end
  end

  def test_a_run_id_must_be_a_run_id
    assert_raises(ArgumentError) { RUN.dir_for("../work-items") }
    assert_raises(ArgumentError) { PIPELINE.new("/tmp/not-a-run") }
  end
end

class BenchmarkNotifyTest < Minitest::Test
  include QmTestHelpers

  def test_announce_raises_a_terminal_notifier_whose_click_runs_qm
    runner = FakeRunner.new
    notifier = Quartermaster::TurnNotifier.new(runner: runner, terminal_notifier: "/bin/terminal-notifier")
    notifier.announce(title: "Benchmark done · b", body: "Faster.", group: "qm-bench-1", click: ["open-chat", "s", "--benchmark", "b"])

    argv = runner.argvs.last
    assert_equal ["/bin/terminal-notifier", "-title", "Benchmark done · b", "-message", "Faster.", "-group", "qm-bench-1", "-execute"],
                 argv[0..7]
    assert_equal [RbConfig.ruby, Quartermaster::EXECUTABLE, "open-chat", "s", "--benchmark", "b"], Shellwords.split(argv.last)
  end

  def test_qm_open_chat_with_a_benchmark_puts_the_branch_in_the_hash
    runner = FakeRunner.new(["osascript"] => ["found\n", "", true])
    Quartermaster::CLI.new(runner: runner).run(["open-chat", "fix-login", "--benchmark", "issue/7-x"])

    assert_includes runner.argvs.first, "http://127.0.0.1:#{Quartermaster::Gui.port}/#chat=fix-login&benchmark=issue%2F7-x"
  end

  def test_a_streamed_command_appends_to_its_files
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      File.write(out, "before\n")
      result = Quartermaster::CommandRunner.new.call(["sh", "-c", "echo hi; echo oops >&2; exit 3"], out: out, err: File.join(dir, "err"))

      refute result.success?
      assert_equal "before\nhi\n", File.read(out)
      assert_equal "oops\n", File.read(File.join(dir, "err"))
    end
  end
end
