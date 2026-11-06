# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_benchmark_test.rb`).
require_relative "test_helper"

# The benchmark modal's actions and the state payload's busy run: a
# BenchmarkRun with a stub spawner, process lookup and killer, so nothing
# real starts, measures or dies.
class GuiBenchmarkTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  RUN = Quartermaster::BenchmarkRun
  NOW = Time.utc(2026, 11, 4, 13, 45, 7)
  ID = "20261104_134507"
  PID = 4242

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def respond(server, payload, headers = ok_host)
    status, _type, body = server.respond("POST", "/api/action", headers, JSON.generate(payload))
    [status, status == "200 OK" ? JSON.parse(body) : body]
  end

  def act(server, cmd, slug: nil, **args) = respond(server, { "cmd" => cmd, "slug" => slug, "args" => args })[1]
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])

  # live: whether the stub pipeline pid counts as running, per run id it was asked about.
  def benchmarks(runner, spawned: [], killed: [], live: -> { true })
    RUN.new(runner: runner, tmux: FakeTmux.new, now: -> { NOW },
            spawner: ->(dir) { spawned << dir && PID },
            process_line: ->(pid) { pid == PID && live.call ? "ruby qm bench-run #{RUN::DIR}/#{ID}" : nil },
            killer: ->(signal, pgid) { killed << [signal, pgid] })
  end

  def server_with(run) = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new, benchmarks: run)

  # project: "my-app" configures benchmarks, any other name doesn't.
  def with_branch(project: "my-app", title: "Speed up")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      configure_projects({ project => project == "my-app" ? benchmarked_project(repo) : repo })
      add_worktree(repo, "feature", "wt-feature")
      yield Quartermaster::WorkItem.create(title, project: project, branch: "feature")
    end
  end

  def settle(server)
    Timeout.timeout(5) { sleep 0.01 until state_of(server)["jobs"].empty? }
  end

  def test_start_spawns_the_pipeline_and_the_state_names_the_busy_run
    with_branch do |item|
      spawned = []
      server = server_with(benchmarks(FakeRunner.new, spawned: spawned))
      assert_nil state_of(server)["benchmark"]

      reply = act(server, "benchmark-start", slug: item.slug, branch: "feature", request: "the list", model: "sonnet")

      assert_equal({ "ok" => true, "run" => ID }, reply)
      assert_equal [File.join(RUN::DIR, ID)], spawned
      assert_equal ["feature", "the list", "sonnet", "planning"], RUN.read(ID).values_at("branch", "request", "model", "state")
      assert_equal({ "id" => ID, "slug" => item.slug, "branch" => "feature", "state" => "planning" },
                   state_of(server)["benchmark"])
    end
  end

  def test_start_defaults_to_opus_and_refuses_an_item_whose_project_has_no_benchmarks
    with_branch(project: "other-app") do |item|
      spawned = []
      reply = act(server_with(benchmarks(FakeRunner.new, spawned: spawned)), "benchmark-start", slug: item.slug,
                                                                                                branch: "feature")

      assert_equal [false, "other-app has no benchmarks: run `qm config set projects.other-app.benchmark.database <database>` " \
                           "and `qm config set projects.other-app.benchmark.skill <skill folder>`"],
                   reply.values_at("ok", "error")
      assert_empty spawned
    end
    with_branch(title: "Configured") do |item|
      server = server_with(benchmarks(FakeRunner.new))
      assert act(server, "benchmark-start", slug: item.slug, branch: "feature", model: "")["ok"]
      assert_equal "opus", RUN.read(ID)["model"]
    end
  end

  # The diff bar shows 🏁 for an item whose state carries benchmarkable.
  def test_only_an_item_of_a_benchmarked_project_is_benchmarkable_in_the_state
    flags = [["other-app", "Other"], ["my-app", "Configured"]].map do |project, title|
      with_branch(project: project, title: title) do |item|
        state_of(server_with(benchmarks(FakeRunner.new)))["items"].find { |i| i["slug"] == item.slug }["benchmarkable"]
      end
    end
    assert_equal [false, true], flags
  end

  def write_run(id, slug:, branch:, state:, finished_at: nil, pid: nil)
    dir = RUN.dir_for(id)
    FileUtils.mkdir_p(dir)
    RUN.write_meta(dir, { "v" => 1, "id" => id, "slug" => slug, "branch" => branch, "state" => state,
                          "startedAt" => "#{id[0, 4]}-#{id[4, 2]}-#{id[6, 2]}T#{id[9, 2]}:#{id[11, 2]}:#{id[13, 2]}Z",
                          "finishedAt" => finished_at, "pid" => pid })
  end

  def item_state(server, item) = state_of(server)["items"].find { |i| i["slug"] == item.slug }

  # The 🏁 marker: per branch, the newest run of this item that finished
  # done; other items' runs and runs that failed, were cancelled or are
  # still going don't count.
  def test_the_state_names_each_branchs_newest_done_run
    with_branch do |item|
      write_run("20261101_100000", slug: item.slug, branch: "feature", state: "done", finished_at: "2026-11-01T10:20:00Z")
      write_run("20261102_100000", slug: item.slug, branch: "feature", state: "done", finished_at: "2026-11-02T10:20:00Z")
      write_run("20261103_100000", slug: item.slug, branch: "feature", state: "failed", finished_at: "2026-11-03T10:20:00Z")
      write_run("20261103_110000", slug: item.slug, branch: "feature", state: "cancelled", finished_at: "2026-11-03T11:20:00Z")
      write_run("20261101_120000", slug: item.slug, branch: "other", state: "done", finished_at: "2026-11-01T12:20:00Z")
      write_run("20261104_090000", slug: "someone-else", branch: "feature", state: "done", finished_at: "2026-11-04T09:20:00Z")
      write_run("20261104_134500", slug: item.slug, branch: "feature", state: "measuring", pid: PID)

      server = server_with(benchmarks(FakeRunner.new, live: -> { false }))

      assert_equal({ "feature" => { "id" => "20261102_100000", "finishedAt" => "2026-11-02T10:20:00Z" },
                     "other" => { "id" => "20261101_120000", "finishedAt" => "2026-11-01T12:20:00Z" } },
                   item_state(server, item)["benchmarked"])
    end
  end

  def test_an_unbenchmarked_item_has_no_benchmarked_branches_and_busy_still_reads_the_runs
    with_branch(project: "other-app") do |item|
      write_run("20261101_100000", slug: item.slug, branch: "feature", state: "done", finished_at: "2026-11-01T10:20:00Z")
      write_run(ID, slug: item.slug, branch: "feature", state: "measuring", pid: PID)

      state = state_of(server_with(benchmarks(FakeRunner.new)))

      assert_equal({}, state["items"].find { |i| i["slug"] == item.slug }["benchmarked"])
      assert_equal({ "id" => ID, "slug" => item.slug, "branch" => "feature", "state" => "measuring" }, state["benchmark"])
    end
  end

  def test_a_start_while_a_run_is_live_answers_the_busy_run
    with_branch do |item|
      spawned = []
      server = server_with(benchmarks(FakeRunner.new, spawned: spawned))
      act(server, "benchmark-start", slug: item.slug, branch: "feature")

      reply = act(server, "benchmark-start", slug: item.slug, branch: "feature")

      assert_equal false, reply["ok"]
      assert_equal({ "id" => ID, "slug" => item.slug, "branch" => "feature", "state" => "planning" }, reply["busy"])
      assert_match(/already running: feature/, reply["error"])
      assert_equal 1, spawned.size
    end
  end

  def test_cancel_kills_the_pipeline_group_and_drops_only_its_clone_off_the_request
    with_branch do |item|
      runner = FakeRunner.new
      killed = []
      server = server_with(benchmarks(runner, killed: killed))
      act(server, "benchmark-start", slug: item.slug, branch: "feature")

      reply = act(server, "benchmark-cancel", run: ID)
      settle(server)

      assert reply["ok"]
      assert_equal [["TERM", -PID]], killed
      assert_equal [["dropdb", "--if-exists", "--force", "app_benchmark_#{ID}"]], runner.calls.map { |c| c[:argv] }
      assert_equal "cancelled", RUN.read(ID)["state"]
      assert_nil state_of(server)["benchmark"]

      again = act(server, "benchmark-cancel", run: ID)
      assert_equal [false, "run #{ID} already cancelled"], again.values_at("ok", "error")
      assert_equal false, act(server, "benchmark-cancel", run: "../x")["ok"]
    end
  end

  def test_rerun_starts_a_new_run_of_the_script_and_answers_a_busy_run
    with_branch do |item|
      alive = true
      spawned = []
      server = server_with(benchmarks(FakeRunner.new, spawned: spawned, live: -> { alive }))
      act(server, "benchmark-start", slug: item.slug, branch: "feature")
      File.write(File.join(RUN::DIR, ID, "bench.rb"), "puts 1\n")
      File.write(File.join(RUN::DIR, ID, "run.json"), "{}")

      busy = act(server, "benchmark-rerun", run: ID)
      assert_equal [false, ID], [busy["ok"], busy.dig("busy", "id")]

      alive = false
      reply = act(server, "benchmark-rerun", run: ID)

      assert_equal({ "ok" => true, "run" => "#{ID}_2" }, reply)
      assert_equal [ID, "measuring"], RUN.read("#{ID}_2").values_at("rerunOf", "state")
      assert_equal 2, spawned.size
    end
  end

  def test_the_benchmark_actions_refuse_a_foreign_or_missing_origin
    server = server_with(benchmarks(FakeRunner.new))
    %w[benchmark-start benchmark-cancel benchmark-rerun].each do |cmd|
      payload = { "cmd" => cmd, "slug" => "x", "args" => { "run" => ID } }
      assert_equal "403 Forbidden", respond(server, payload, ok_host.merge("origin" => "https://evil.example.com"))[0], cmd
      assert_equal "403 Forbidden", respond(server, payload, { "host" => "127.0.0.1:4567" })[0], cmd
    end
  end

  # Held by the test's own thread, a mutex the action reached for would raise.
  def test_the_benchmark_actions_never_wait_on_the_action_mutex
    with_branch do |item|
      server = server_with(benchmarks(FakeRunner.new))
      server.instance_variable_get(:@mutex).synchronize do
        assert act(server, "benchmark-start", slug: item.slug, branch: "feature")["ok"]
        assert act(server, "benchmark-cancel", run: ID)["ok"]
      end
      settle(server)
    end
  end
end
