# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/benchmark_report_test.rb`).
require_relative "test_helper"

class BenchmarkReportTest < Minitest::Test
  include QmTestHelpers

  MAIN = "a" * 40
  FEAT = "b" * 40
  LIVE_PID = 4242
  DEAD_PID = 4343

  def setup
    super
    configure_projects({ "my-app" => benchmarked_project("/repo"), "other-app" => "/other" })
  end

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def run_dir(id) = File.join(Quartermaster::ROOT, "benchmarks", id)

  # A run folder as the pipeline leaves it: meta.json plus whatever files are given.
  def write_run(id, slug: "feat", branch: "feature", state: "measuring", pid: LIVE_PID, events: [], **meta)
    dir = run_dir(id)
    FileUtils.mkdir_p(File.join(dir, "plans"))
    File.write(File.join(dir, "meta.json"), JSON.generate({
      "v" => 1, "slug" => slug, "project" => "my-app", "root" => "/repo", "branch" => branch, "request" => "",
      "model" => "opus", "startedAt" => "2026-11-04T10:00:00Z", "finishedAt" => nil, "state" => state, "pid" => pid,
      "stages" => [{ "name" => "main", "ref" => "main", "sha" => MAIN }, { "name" => "feature", "ref" => "feature", "sha" => FEAT }],
      "head" => FEAT, "rerunOf" => nil
    }.merge(meta.transform_keys(&:to_s))))
    File.write(File.join(dir, "events.jsonl"), events.map { |e| e.is_a?(String) ? e : "#{JSON.generate(e)}\n" }.join)
    dir
  end

  PLAN = { "t" => "plan", "stages" => [{ "name" => "main" }, { "name" => "feature" }],
           "cases" => [{ "subject" => "u1/p2", "case" => "request list", "why" => "heaviest share holder" },
                       { "subject" => "u1/p2", "case" => "show?", "why" => "single record" }] }.freeze

  def measured(stage, kase, ms, **extra)
    { "t" => "case", "stage" => stage, "subject" => "u1/p2", "case" => kase, "ms" => ms, "timeout" => false,
      "queries" => nil, "plan" => "#{stage}-#{kase}.txt" }.merge(extra.transform_keys(&:to_s))
  end

  def report(head: FEAT, refs: { "main" => MAIN, "feature" => FEAT }, alive: [LIVE_PID])
    Quartermaster::BenchmarkReport.new(head_of: ->(_item, _branch) { head },
                                       resolve: ->(_root, ref) { refs[ref] },
                                       alive: ->(pid, _id) { alive.include?(pid) },
                                       now: -> { Time.utc(2026, 11, 4, 10, 5, 0) })
  end

  def item(project: "my-app", title: "Feat")
    @items ||= {}
    @items[title] ||= Quartermaster::WorkItem.create(title, project: project, branch: "feature")
  end

  def test_a_partial_run_folds_plan_subjects_cases_and_ids_into_rows_and_skips_a_truncated_last_line
    write_run("20261104_100000", events: [
                PLAN,
                { "t" => "subject", "subject" => "u1/p2", "about" => "user 1 (7,334 shares)", "extra" => 1 },
                { "t" => "stage", "name" => "main" },
                measured("main", "request list", 41.2),
                measured("main", "show?", 3.0),
                { "t" => "stage", "name" => "feature" },
                measured("feature", "request list", 12.5, queries: 7),
                { "t" => "ids", "stage" => "feature", "subject" => "u1/p2", "case" => "request list", "ids" => "same", "vs" => "main" },
                { "t" => "someday", "x" => 1 },
                '{"t":"case","stage":"feature","subject":"u1/p2","case":"show?","ms":'
              ])
    run = report.call(item, branch: "feature")["run"]

    assert_equal "measuring", run["state"]
    assert_equal [{ "subject" => "u1/p2", "about" => "user 1 (7,334 shares)" }], run["subjects"]
    assert_equal [["u1/p2", "request list", "heaviest share holder"], ["u1/p2", "show?", "single record"]],
                 run["rows"].map { |r| r.values_at("subject", "case", "why") }
    list, show = run["rows"].map { |r| r["cells"] }
    assert_equal({ "ms" => 41.2, "timeout" => false, "queries" => nil, "plan" => "main-request list.txt", "ids" => nil, "vs" => nil },
                 list["main"])
    assert_equal({ "ms" => 12.5, "timeout" => false, "queries" => 7, "plan" => "feature-request list.txt", "ids" => "same", "vs" => "main" },
                 list["feature"])
    assert_equal ["main"], show.keys, "the truncated feature cell is not measured yet"
    assert_equal [{ "name" => "main", "ref" => "main", "sha" => MAIN }, { "name" => "feature", "ref" => "feature", "sha" => FEAT }],
                 run["stages"]
    assert_equal 300, run["durationS"]
    refute run["canRerun"], "a running run can't be re-run"
  end

  def test_a_timeout_cell_has_no_ms
    write_run("20261104_100000", events: [PLAN, measured("main", "request list", nil, timeout: true)])
    cell = report.call(item, branch: "feature")["run"]["rows"].first["cells"]["main"]

    assert_nil cell["ms"]
    assert cell["timeout"]
  end

  def test_a_cancelled_run_keeps_its_measured_cells_and_its_state_though_its_pid_is_gone
    write_run("20261104_100000", state: "cancelled", pid: DEAD_PID, finishedAt: "2026-11-04T10:02:00Z",
                                 events: [PLAN, measured("main", "request list", 41.2)])
    run = report.call(item, branch: "feature")["run"]

    assert_equal "cancelled", run["state"]
    assert_nil run["error"]
    assert_equal 120, run["durationS"]
    assert_equal 41.2, run["rows"].first["cells"]["main"]["ms"]
  end

  def test_a_run_whose_pipeline_died_reads_as_failed
    write_run("20261104_100000", state: "measuring", pid: DEAD_PID, events: [PLAN])
    result = report.call(item, branch: "feature")

    assert_equal %w[failed pipeline\ died], result["run"].values_at("state", "error")
    assert_nil result["run"]["durationS"], "a dead run's duration doesn't keep counting"
    assert_nil result["busy"]
    assert_equal "failed", result["runs"].first["state"]
  end

  def test_a_failed_run_keeps_its_own_error
    write_run("20261104_100000", state: "failed", pid: DEAD_PID, error: "free disk below 20 GB")

    assert_equal "free disk below 20 GB", report.call(item, branch: "feature")["run"]["error"]
  end

  def test_a_run_carries_its_warning
    write_run("20261104_100000", state: "done", pid: DEAD_PID, warning: "dropdb failed: clone still on disk")

    assert_equal ["done", nil, "dropdb failed: clone still on disk"],
                 report.call(item, branch: "feature")["run"].values_at("state", "error", "warning")
  end

  def test_moved_when_the_branch_head_is_no_longer_the_recorded_one
    write_run("20261104_100000", state: "done", pid: DEAD_PID)

    run = report(head: "c" * 40).call(item, branch: "feature")["run"]
    assert_equal [FEAT, "c" * 40, true], run.values_at("head", "currentHead", "moved")
    refute report.call(item, branch: "feature")["run"]["moved"]
    refute report(head: nil).call(item, branch: "feature")["run"]["moved"], "an unknown head is not a move"
  end

  def test_runs_list_this_item_and_branch_newest_first_and_run_picks_the_asked_one
    write_run("20261104_090000", state: "done", pid: DEAD_PID, startedAt: "2026-11-04T09:00:00Z", request: "first")
    write_run("20261104_100000", state: "done", pid: DEAD_PID, startedAt: "2026-11-04T10:00:00Z", rerunOf: "20261104_090000")
    write_run("20261104_100000_2", state: "done", pid: DEAD_PID, startedAt: "2026-11-04T10:00:00Z")
    write_run("20261104_110000", state: "done", pid: DEAD_PID, branch: "other")
    write_run("20261104_120000", state: "done", pid: DEAD_PID, slug: "someone-else")
    FileUtils.mkdir_p(run_dir("20261104_130000"))
    File.write(File.join(run_dir("20261104_130000"), "meta.json"), "{not json")
    result = report.call(item, branch: "feature")

    assert_equal %w[20261104_100000_2 20261104_100000 20261104_090000], result["runs"].map { |r| r["id"] }
    assert_equal({ "id" => "20261104_100000", "startedAt" => "2026-11-04T10:00:00Z", "state" => "done", "request" => "",
                   "rerunOf" => "20261104_090000" }, result["runs"][1])
    assert_equal "20261104_100000_2", result["run"]["id"]
    asked = report.call(item, branch: "feature", run: "20261104_090000")["run"]
    assert_equal %w[20261104_090000 first], asked.values_at("id", "request")
    assert_raises(ArgumentError) { report.call(item, branch: "feature", run: "../etc") }
  end

  def test_no_runs_yet
    result = report.call(item, branch: "feature")

    assert_equal [true, "feature", [], nil, nil], result.values_at("enabled", "branch", "runs", "run", "busy")
  end

  def test_busy_is_any_live_run_machine_wide
    write_run("20261104_090000", slug: "someone-else", branch: "other", state: "planning")
    write_run("20261104_100000", state: "measuring", pid: DEAD_PID)

    assert_equal({ "id" => "20261104_090000", "slug" => "someone-else", "branch" => "other", "state" => "planning" },
                 report.call(item, branch: "feature")["busy"])
    assert_nil report(alive: []).busy
  end

  def test_a_pid_running_a_later_run_of_the_same_second_is_not_this_runs_pipeline
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", "/x/benchmarks/20261104_100000_2")
    write_run("20261104_100000", state: "measuring", pid: pid)
    write_run("20261104_100000_2", state: "measuring", pid: pid)
    plain = Quartermaster::BenchmarkReport.new(head_of: ->(*) {}, resolve: ->(*) {}, now: -> { Time.utc(2026, 11, 4, 10, 5, 0) })
    runs = plain.call(item, branch: "feature")["runs"].to_h { |r| [r["id"], r["state"]] }

    assert_equal({ "20261104_100000_2" => "measuring", "20261104_100000" => "failed" }, runs)
    assert_equal %w[failed pipeline\ died],
                 plain.call(item, branch: "feature", run: "20261104_100000")["run"].values_at("state", "error")
    Process.kill("KILL", pid)
    Process.wait(pid)
    assert_equal "failed", plain.call(item, branch: "feature")["runs"].first["state"], "a gone pid is no pipeline"
  ensure
    begin
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end

  def test_a_run_with_no_pid_yet_is_live_for_thirty_seconds_after_it_started
    write_run("20261104_100000", state: "planning", pid: nil, startedAt: "2026-11-04T10:04:31Z")
    assert_equal "planning", report.call(item, branch: "feature")["run"]["state"]
    assert_equal "20261104_100000", report.busy&.fetch("id")

    write_run("20261104_100000", state: "planning", pid: nil, startedAt: "2026-11-04T10:04:30Z")
    assert_equal %w[failed pipeline\ died], report.call(item, branch: "feature")["run"].values_at("state", "error")
    assert_nil report.busy
  end

  def test_enabled_only_for_a_project_that_configures_benchmarks
    assert report.call(item, branch: "feature")["enabled"]
    refute report.call(item(project: "other-app", title: "Other"), branch: "feature")["enabled"]
    refute report.call(item(project: "My-App", title: "Cased"), branch: "feature")["enabled"], "project names match exactly"
  end

  def test_activity_is_the_agents_latest_tool_call_while_planning
    dir = write_run("20261104_100000", state: "planning")
    lines = [
      { "type" => "system", "subtype" => "init" },
      { "type" => "assistant", "message" => { "content" => [{ "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/repo/a.rb" } }] } },
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "now writing" },
                                                            { "type" => "tool_use", "name" => "Write", "input" => { "file_path" => "/runs/bench.rb", "content" => "x" } }] } },
      { "type" => "user", "message" => { "content" => [{ "type" => "tool_result", "content" => "ok" }] } }
    ]
    File.write(File.join(dir, "agent.jsonl"), "#{lines.map { |l| JSON.generate(l) }.join("\n")}\n{\"type\":\"assist")

    assert_equal "Write  /runs/bench.rb", report.call(item, branch: "feature")["run"]["activity"]
    write_run("20261104_100000", state: "measuring")
    assert_nil report.call(item, branch: "feature")["run"]["activity"]
  end

  def test_activity_survives_a_tail_that_starts_inside_a_multibyte_character
    dir = write_run("20261104_100000", state: "planning")
    path = File.join(dir, "agent.jsonl")
    tool = JSON.generate({ "type" => "assistant", "message" => { "content" => [{ "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/repo/a.rb" } }] } })
    ["", "x"].each do |pad|
      text = JSON.generate({ "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "#{"é" * 40_000}#{pad}" }] } })
      File.write(path, "#{text}\n#{tool}\n")
      break if File.binread(path).getbyte(File.size(path) - Quartermaster::BenchmarkReport::AGENT_TAIL_BYTES) == 0xA9
    end
    assert_equal 0xA9, File.binread(path).getbyte(File.size(path) - Quartermaster::BenchmarkReport::AGENT_TAIL_BYTES)

    assert_equal "Read  /repo/a.rb", report.call(item, branch: "feature")["run"]["activity"]
  end

  def test_verdict_and_can_rerun_once_final_while_every_stage_still_resolves_to_its_sha
    dir = write_run("20261104_100000", state: "done", pid: DEAD_PID, finishedAt: "2026-11-04T10:12:00Z")
    File.write(File.join(dir, "verdict.md"), "Feature is 3x faster.\n")
    File.write(File.join(dir, "bench.rb"), "puts 1\n")
    File.write(File.join(dir, "run.json"), '{"cwd":"/repo","clone":false}')
    run = report.call(item, branch: "feature")["run"]

    assert_equal ["Feature is 3x faster.", 720, true], run.values_at("verdict", "durationS", "canRerun")
    refute report(refs: { "main" => MAIN, "feature" => "c" * 40 }).call(item, branch: "feature")["run"]["canRerun"]
    File.delete(File.join(dir, "bench.rb"))
    refute report.call(item, branch: "feature")["run"]["canRerun"], "nothing to re-run without the script"
  end

  def test_a_plan_file_is_read_only_from_its_runs_plans_folder
    dir = write_run("20261104_100000", state: "done")
    File.write(File.join(dir, "plans", "main-list.txt"), "Seq Scan on shares\n")
    File.write(File.join(dir, "meta-copy.json"), "secret")

    assert_equal "Seq Scan on shares\n", Quartermaster::BenchmarkReport.plan_file("20261104_100000", "main-list.txt")
    ["../meta-copy.json", "..", "", "sub/x.txt", "missing.txt"].each do |file|
      assert_raises(ArgumentError, file) { Quartermaster::BenchmarkReport.plan_file("20261104_100000", file) }
    end
    assert_raises(ArgumentError) { Quartermaster::BenchmarkReport.plan_file("..", "20261104_100000/plans/main-list.txt") }
  end

  def test_logs_name_the_allowed_log_files_the_run_has_in_a_fixed_order
    dir = write_run("20261104_100000", state: "failed", pid: DEAD_PID, error: "bin/rails runner failed")
    %w[bench.rb pipeline.log bench.log agent.jsonl verdict.md notes.txt].each { |name| File.write(File.join(dir, name), "x\n") }

    assert_equal %w[bench.log pipeline.log bench.rb], report.call(item, branch: "feature")["run"]["logs"]
  end

  def test_a_log_file_is_one_of_the_allow_list_and_its_last_64_kb
    dir = write_run("20261104_100000", state: "failed", pid: DEAD_PID)
    File.write(File.join(dir, "bench.log"), "warning: old\n#{'w' * (70 * 1024)}\ncannot load such file -- benchmark (LoadError)\n")
    File.write(File.join(dir, "verdict.md"), "Fast.\n")
    File.write(File.join(dir, "plans", "bench.log"), "a plan\n")

    text = Quartermaster::BenchmarkReport.log_file("20261104_100000", "bench.log")
    assert_equal 64 * 1024, text.bytesize
    assert text.end_with?("cannot load such file -- benchmark (LoadError)\n")
    refute_includes text, "warning: old"
    ["verdict.md", "meta.json", "agent.jsonl", "../20261104_100000/bench.log", "plans/bench.log", "", ".."].each do |name|
      assert_raises(ArgumentError, name) { Quartermaster::BenchmarkReport.log_file("20261104_100000", name) }
    end
    assert_raises(ArgumentError) { Quartermaster::BenchmarkReport.log_file("20261104_100000", "run.json") }
    assert_raises(ArgumentError) { Quartermaster::BenchmarkReport.log_file("20261104_100001", "bench.log") }
    assert_raises(ArgumentError) { Quartermaster::BenchmarkReport.log_file("..", "bench.log") }
  end

  def test_the_gui_serves_a_log_file_and_refuses_anything_off_the_allow_list
    item
    dir = write_run("20261104_100000", state: "failed", pid: DEAD_PID)
    File.write(File.join(dir, "pipeline.log"), "createdb failed\n")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    assert_equal ["200 OK", "text/plain; charset=utf-8", "createdb failed\n"],
                 gui.respond("GET", "/api/benchmark-log/20261104_100000/pipeline.log", ok_host, "")
    ["/20261104_100000/meta.json", "/20261104_100000/..%2F..%2Fsessions.jsonl", "/..%2Fbenchmarks/pipeline.log",
     "/20261104_100000/bench.log"].each do |rest|
      assert_equal "404 Not Found", gui.respond("GET", "/api/benchmark-log#{rest}", ok_host, "")[0], rest
    end
  end

  def test_the_gui_serves_the_payload_and_plan_files
    item
    dir = write_run("20261104_100000", state: "done", pid: DEAD_PID, events: [PLAN, measured("main", "request list", 41.2)])
    File.write(File.join(dir, "plans", "main list.txt"), "Index Scan\n")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    status, type, body = gui.respond("GET", "/api/benchmark/feat?branch=feature", ok_host, "")
    payload = JSON.parse(body)
    assert_equal ["200 OK", "application/json; charset=utf-8"], [status, type]
    assert_equal [true, true, "20261104_100000", "done"], [payload["ok"], payload["enabled"], payload["run"]["id"], payload["run"]["state"]]
    assert_equal ["200 OK", "text/plain; charset=utf-8", "Index Scan\n"],
                 gui.respond("GET", "/api/benchmark-plan/20261104_100000/main%20list.txt", ok_host, "")
    assert_equal "404 Not Found", gui.respond("GET", "/api/benchmark-plan/20261104_100000/..%2Fmeta.json", ok_host, "")[0]
    refute JSON.parse(gui.respond("GET", "/api/benchmark/feat?branch=feature&run=nope", ok_host, "")[2])["ok"]
  end
end
