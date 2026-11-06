# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/build_progress_test.rb`).
require_relative "test_helper"
class BuildProgressTest < Minitest::Test
  include QmTestHelpers

  FakeStatus = Struct.new(:ok) do
    def success? = ok
  end

  PROJECT = "-proj"

  def session_dir(sid) = File.join(Quartermaster::TRANSCRIPTS_DIR, PROJECT, sid)

  # An orchestrator session; live sessions carry this test process's pid.
  def orchestrator(sid, live: true)
    transcript = "#{session_dir(sid)}.jsonl"
    FileUtils.mkdir_p(File.dirname(transcript))
    File.write(transcript, "")
    Quartermaster.ensure_setup
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => sid, "cwd" => "/", "pid" => live ? Process.pid : nil,
               "transcript_path" => transcript, "ts" => Time.now.iso8601)
  end

  def user(text, at: "2026-10-28T12:00:00Z")
    { "type" => "user", "timestamp" => at, "message" => { "role" => "user", "content" => text } }
  end

  def assistant(*blocks)
    { "type" => "assistant", "message" => { "role" => "assistant", "content" => blocks } }
  end

  def tool(name, input) = { "type" => "tool_use", "name" => name, "input" => input }

  def result_for(id) = { "type" => "user", "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => id, "content" => "x" * 50 }] } }

  # A run directory: agents => { id => [label, entries] }, journal lines given raw.
  def workflow_run(sid, run_id, agents, journal: nil, result_status: nil)
    dir = File.join(session_dir(sid), "subagents", "workflows", run_id)
    FileUtils.mkdir_p(dir)
    agents.each do |id, (label, entries)|
      File.write(File.join(dir, "agent-#{id}.jsonl"), entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
      File.write(File.join(dir, "agent-#{id}.meta.json"), JSON.generate("description" => label, "workflowPhase" => "Build"))
    end
    File.write(File.join(dir, "journal.jsonl"), journal.map { |e| JSON.generate(e) }.join("\n") + "\n") if journal
    return unless result_status

    FileUtils.mkdir_p(File.join(session_dir(sid), "workflows"))
    File.write(File.join(session_dir(sid), "workflows", "#{run_id}.json"), JSON.generate("runId" => run_id, "status" => result_status))
  end

  def started(id, label) = { "type" => "started", "key" => "k-#{id}", "agentId" => id, "label" => label, "phase" => "Build" }
  def ended(id) = { "type" => "result", "key" => "k-#{id}", "agentId" => id, "result" => {} }

  def item_with(*sids)
    item = Quartermaster::WorkItem.create("Build", project: "No project", session_id: sids.first)
    sids.drop(1).each { |sid| item.attach_session(sid) }
    Quartermaster::WorkItem.find(item.slug)
  end

  def builder_entries
    [user("[Workflow harness — user request] relayed request"),
     user("[Workflow harness — computed task] Preamble. The computed task text follows:\n  You are the builder of task \"alpha\": add the widget"),
     assistant(tool("Bash", { "command" => "git reset --hard main", "description" => "Reset to main" })),
     result_for("1"),
     assistant({ "type" => "thinking", "thinking" => "secret thoughts" },
               { "type" => "text", "text" => "Now the tests." }, tool("Edit", { "file_path" => "/w/widget.rb" }))]
  end

  def progress(model: ->(*) { flunk "no model call expected" }, now: Time.parse("2026-10-28T12:30:00Z"))
    Quartermaster::BuildProgress.new(model: model, now: now)
  end

  def test_finds_active_agents_of_running_runs_only
    orchestrator("s1")
    orchestrator("s-dead", live: false)
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries], "a2" => ["queue#1", [user("q")]],
                           "a3" => ["review:beta", builder_entries] },
        journal: [{ "type" => "launched" }, started("a1", "build:alpha"), started("a2", "queue#1"), ended("a2"),
                  started("a3", "review:beta"), { "type" => "failed", "key" => "k-a3", "agentId" => "" }])
    workflow_run("s1", "wf_done", { "b1" => ["build:old", builder_entries] }, journal: [started("b1", "build:old")],
                                                                     result_status: "completed")
    workflow_run("s-dead", "wf_crashed", { "c1" => ["build:ghost", builder_entries] }, journal: [started("c1", "build:ghost")])
    item = item_with("s1", "s-dead")

    agents = progress.active_agents(item)

    assert_equal [%w[wf_live a1 build:alpha]], agents.map { |a| [a.run_id, a.agent_id, a.label] }
  end

  def test_agents_are_named_as_tasks_and_helpers_are_left_out
    orchestrator("s1")
    labels = { "a1" => "build:alpha", "a2" => "queue#2", "a3" => "review:beta", "a4" => "integrate", "a5" => "check:gaps" }
    workflow_run("s1", "wf_live", labels.transform_values { |label| [label, builder_entries] },
                 journal: labels.map { |id, label| started(id, label) })

    agents = progress.active_agents(item_with("s1"))

    assert_equal ["alpha · building", "beta · reviewing", "integrating"], agents.map(&:task)
  end

  def test_a_run_result_without_a_terminal_status_still_counts_as_running
    orchestrator("s1")
    workflow_run("s1", "wf_x", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")],
                                                                   result_status: "running")
    assert_equal ["build:alpha"], progress.active_agents(item_with("s1")).map(&:label)
  end

  def test_without_a_journal_a_handed_back_transcript_means_done
    orchestrator("s1")
    done = builder_entries + [assistant(tool("StructuredOutput", { "finished" => true }))]
    workflow_run("s1", "wf_old", { "a1" => ["build:alpha", builder_entries], "a2" => ["build:beta", done] })

    assert_equal ["build:alpha"], progress.active_agents(item_with("s1")).map(&:label)
  end

  def test_condense_carries_brief_and_recent_calls_but_no_thinking_or_tool_output
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    agent = progress.active_agents(item_with("s1")).first

    text = progress.condense(agent)

    assert_includes text, "## build:alpha (run wf_live, phase Build, working for 30 min)"
    assert_includes text, "You are the builder of task \"alpha\": add the widget"
    refute_includes text, "Preamble"
    refute_includes text, "relayed request"
    assert_includes text, "- Bash: Reset to main"
    assert_includes text, "- said: Now the tests."
    assert_includes text, "- Edit: /w/widget.rb"
    refute_includes text, "secret thoughts"
    refute_includes text, "x" * 50
  end

  # martijnpieters/quartermaster#5: lines that parse but are no object are skipped.
  def test_non_object_lines_in_journal_and_transcript_are_skipped
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    run_dir = File.join(session_dir("s1"), "subagents", "workflows", "wf_live")
    File.write(File.join(run_dir, "journal.jsonl"), "5\nnull\n" + File.read(File.join(run_dir, "journal.jsonl")))
    transcript = File.join(run_dir, "agent-a1.jsonl")
    File.write(transcript, "5\n[]\n\"x\"\nnull\n" + File.read(transcript) + "5\nnull\n")
    agent = progress.active_agents(item_with("s1")).first

    text = progress.condense(agent)

    assert_includes text, "You are the builder of task \"alpha\": add the widget"
    assert_includes text, "- Edit: /w/widget.rb"
  end

  def test_condense_stays_small_for_a_long_transcript
    orchestrator("s1")
    long = builder_entries + Array.new(300) { |n| assistant(tool("Bash", { "command" => "step #{n} #{"y" * 1_000}" })) }
    long[1] = user("z" * 50_000)
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", long] }, journal: [started("a1", "build:alpha")])
    agent = progress.active_agents(item_with("s1")).first

    text = progress.condense(agent)

    assert_operator text.size, :<, 8_000
    assert_includes text, "step 299"
    refute_includes text, "step 270 "
  end

  def test_nothing_running_answers_without_a_model_call
    orchestrator("s1")
    result = progress.call(item_with("s1"))
    assert result["ok"]
    assert_empty result["agents"]
    assert_equal "nothing running", result["message"]
  end

  def test_one_model_call_yields_a_line_per_active_agent
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries], "a2" => ["review:beta", builder_entries] },
        journal: [started("a1", "build:alpha"), started("a2", "review:beta")])
    calls = []
    model = lambda do |prompt, stdin|
      calls << [prompt, stdin]
      answer = { "agents" => [{ "label" => "build:alpha", "percent" => 140, "doing" => "writing tests" },
                              { "label" => "invented", "percent" => 5, "doing" => "?" }] }
      [JSON.generate("type" => "result", "structured_output" => answer), "", FakeStatus.new(true)]
    end

    result = progress(model: model).call(item_with("s1"))

    assert_equal 1, calls.size
    assert_includes calls.first[1], "## build:alpha"
    assert_includes calls.first[1], "## review:beta"
    assert_equal [{ "task" => "alpha · building", "run" => "wf_live", "agent" => "wf_live/a1", "percent" => 100, "doing" => "writing tests" },
                  { "task" => "beta · reviewing", "run" => "wf_live", "agent" => "wf_live/a2", "percent" => nil, "doing" => "no estimate" }],
                 result["agents"]
    assert_equal "2026-10-28T12:30:00Z", Time.parse(result["taken_at"]).utc.iso8601
  end

  def test_unstructured_answers_come_back_as_raw_text_and_failures_raise
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    item = item_with("s1")

    raw = progress(model: ->(*) { [JSON.generate("result" => "alpha is about half done"), "", FakeStatus.new(true)] }).call(item)
    assert_equal "alpha is about half done", raw["raw"]

    garbled = progress(model: ->(*) { ["not json", "", FakeStatus.new(true)] }).call(item)
    assert_equal "not json", garbled["raw"]

    error = assert_raises(ArgumentError) { progress(model: ->(*) { ["", "boom", FakeStatus.new(false)] }).call(item) }
    assert_match(/claude -p failed: boom/, error.message)
  end

  def test_default_model_is_headless_haiku_without_logging_itself
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    seen = nil
    with_fake_open3(lambda { |env, argv, stdin|
      seen = [env, argv, stdin]
      [JSON.generate("structured_output" => { "agents" => [] }), "", FakeStatus.new(true)]
    }) { Quartermaster::BuildProgress.new.call(item_with("s1")) }

    assert_equal({ "QM_SKIP" => "1" }, seen[0])
    assert_equal %w[claude -p], seen[1].first(2)
    assert_equal "haiku", seen[1][seen[1].index("--model") + 1]
    assert_includes seen[1], "--json-schema"
    assert_includes seen[2], "## build:alpha"
  end

  # --- the GUI action ---

  def with_fake_open3(handler)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |env, *argv, stdin_data: nil, **| handler.call(env, argv, stdin_data) }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])

  def settled(server)
    Timeout.timeout(5) do
      loop do
        state = state_of(server)
        return state if state["jobs"].empty?

        sleep 0.01
      end
    end
  end

  def click(server, slug)
    JSON.parse(server.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "build-progress", "slug" => slug))[2])
  end

  def test_gui_runs_the_estimate_as_a_background_job_and_keeps_the_newest
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    item = item_with("s1")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    percent = 30
    handler = lambda do |*|
      answer = { "agents" => [{ "label" => "build:alpha", "percent" => percent, "doing" => "editing" }] }
      [JSON.generate("structured_output" => answer), "", FakeStatus.new(true)]
    end

    state = with_fake_open3(handler) do
      response = click(server, item.slug)
      assert response["ok"]
      assert response["background"]
      settled(server)
    end
    assert_equal 30, state["buildProgress"][item.slug]["agents"].first["percent"]
    assert_equal ["#{item.slug}: build progress updated"], state["finished"].map { |f| f["message"] }

    percent = 70
    state = with_fake_open3(handler) do
      click(server, item.slug)
      settled(server)
    end
    assert_equal 70, state["buildProgress"][item.slug]["agents"].first["percent"]
  end

  def test_gui_drops_finished_tasks_from_the_estimate_and_the_button_with_the_last
    orchestrator("s1")
    agents = { "a1" => ["build:alpha", builder_entries], "a2" => ["review:beta", builder_entries] }
    journal = [started("a1", "build:alpha"), started("a2", "review:beta")]
    workflow_run("s1", "wf_live", agents, journal: journal)
    item = item_with("s1")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    answer = { "agents" => [{ "label" => "build:alpha", "percent" => 40, "doing" => "editing" },
                            { "label" => "review:beta", "percent" => 80, "doing" => "reading" }] }

    state = with_fake_open3(->(*) { [JSON.generate("structured_output" => answer), "", FakeStatus.new(true)] }) do
      click(server, item.slug)
      settled(server)
    end
    assert_equal [item.slug], state["buildActive"]
    assert_equal ["alpha · building", "beta · reviewing"], state["buildProgress"][item.slug]["agents"].map { |a| a["task"] }

    workflow_run("s1", "wf_live", agents, journal: journal + [ended("a2")])
    state = state_of(server)
    assert_equal ["alpha · building"], state["buildProgress"][item.slug]["agents"].map { |a| a["task"] }

    workflow_run("s1", "wf_live", agents, journal: journal + [ended("a2"), ended("a1")])
    state = state_of(server)
    assert_empty state["buildActive"]
    refute state["buildProgress"].key?(item.slug)
  end

  def test_gui_shows_a_failed_estimate_without_breaking
    orchestrator("s1")
    workflow_run("s1", "wf_live", { "a1" => ["build:alpha", builder_entries] }, journal: [started("a1", "build:alpha")])
    item = item_with("s1")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    state = with_fake_open3(->(*) { ["", "claude: command failed", FakeStatus.new(false)] }) do
      click(server, item.slug)
      settled(server)
    end

    stored = state["buildProgress"][item.slug]
    refute stored["ok"]
    assert_match(/claude -p failed/, stored["error"])
    refute state["finished"].first["ok"]
  end

  def test_page_has_the_progress_button_seam
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    page = served_page(server, ok_host)
    assert_includes page, 'act("build-progress"'
    assert_includes page, "buildProgress = st.buildProgress"
    assert_includes page, "buildActive.includes(it.slug)"
  end
end
