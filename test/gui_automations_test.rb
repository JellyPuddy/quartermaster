# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_automations_test.rb`).
require_relative "test_helper"
require_relative "automation_cli_test"

# The ⚙ area's Automations tab, server side: /api/automations… through the
# GUI router with a stub routines client (no keychain, no network). Network
# work runs as GUI jobs; each test waits for them to settle.
class GuiAutomationsTest < Minitest::Test
  include QmTestHelpers

  StubClient = AutomationCliTest::StubClient
  DIGEST = AutomationCliTest::DIGEST
  ID = AutomationCliTest::ID
  ON = "automations:\n  token_source: claude_code\n"

  def setup
    super
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, ON)
    @client = StubClient.new(DIGEST)
  end

  def gui = @gui ||= Quartermaster::Gui.new(port: 4567, runner: quiet_runner, routines: @client)

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def get(route)
    status, _type, body = gui.respond("GET", route, ok_host, "")
    assert_equal "200 OK", status, body
    JSON.parse(body)
  end

  def post(route, payload = {}, headers = ok_host)
    status, _type, body = gui.respond("POST", route, headers, JSON.generate(payload))
    [status, (JSON.parse(body) rescue body)]
  end

  # The finished jobs, once every running one is done.
  def settle
    Timeout.timeout(10) { sleep 0.02 until gui.jobs.running.empty? }
    gui.jobs.take_finished
  end

  def store = Quartermaster::AutomationStore.new

  def adopt
    Quartermaster::Automations.new(client: @client).adopt(ID, project: "MyApp", slug: "digest")
    @client.calls.clear
  end

  def row(payload, slug = "digest") = payload["rows"].find { |r| r["slug"] == slug }

  def test_the_list_answers_the_local_files_at_once_and_the_routines_after_one_list_call
    adopt
    first = get("/api/automations")

    assert_empty @client.calls, "the list itself never touches the network"
    assert_equal({ "state" => "idle" }, first["remote"].slice("state"))
    assert_equal %w[digest MyApp active 0\ 7\ *\ *\ 1,4 cloud], row(first).values_at("slug", "project", "state", "cron", "runner")
    assert_equal [1, 4], row(first)["schedule"]["days"]

    status, answer = post("/api/automations/refresh")
    assert_equal ["200 OK", true], [status, answer["background"]]
    assert_equal [true], settle.map { |job| job["quiet"] }
    assert_equal [[:list]], @client.calls

    listed = get("/api/automations")
    assert_equal "ok", listed["remote"]["state"]
    assert_equal false, row(listed)["drift"]
    assert_equal DIGEST["next_run_at"], row(listed)["nextRunAt"]
    assert_equal "https://claude.ai/code/routines/#{ID}", row(listed)["routineUrl"]
  end

  def test_routines_without_local_files_are_listed_for_adoption_and_adopt_takes_them_in
    post("/api/automations/refresh")
    settle
    unmanaged = get("/api/automations")["unmanaged"]
    assert_equal [[ID, DIGEST["name"], "0 7 * * 1,4"]], unmanaged.map { |r| r.values_at("id", "name", "cron") }

    _status, answer = post("/api/automations/adopt", "id" => ID, "project" => "MyApp", "slug" => "digest")
    assert answer["background"]
    job = settle.find { |j| j["key"] == "automation-adopt-#{ID}" }
    assert_equal [true, "digest"], job.values_at("ok", "automation")

    listed = get("/api/automations")
    assert_empty listed["unmanaged"]
    assert_equal %w[MyApp active], row(listed).values_at("project", "state")
    assert_equal "automation", Quartermaster::WorkItem.find("digest").kind
  end

  def test_a_routine_changed_outside_qm_shows_drift_until_pulled
    adopt
    @client.touch(ID)
    post("/api/automations/refresh")
    settle
    assert_equal true, row(get("/api/automations"))["drift"]
    assert_equal true, get("/api/automations/digest")["drift"]

    post("/api/automations/pull", "slug" => "digest")
    assert_equal [true], settle.map { |job| job["ok"] }
    assert_equal false, row(get("/api/automations"))["drift"]
  end

  def test_apply_saves_the_schedule_and_prompt_locally_then_pushes
    adopt
    status, answer = post("/api/automations/apply", "slug" => "digest", "cron" => "30 6 * * 1", "prompt" => "New prompt.")
    assert_equal ["200 OK", true], [status, answer["background"]]
    assert_equal ["30 6 * * 1", "New prompt."], [store.read("digest").record["cron"], store.read("digest").prompt]

    job = settle.find { |j| j["key"] == "automation-digest" }
    assert job["ok"], job["error"]
    update = @client.calls.find { |c| c.first == :update }
    assert_equal "30 6 * * 1", @client.routines[ID]["cron_expression"]
    assert_includes update[2].keys, "prompt"
    history = Quartermaster::WorkItem.find("digest").notes.select(&:history?).map(&:text)
    assert(history.any? { |t| t.start_with?("pushed: schedule → Mon") && t.include?("prompt changed") }, history.inspect)
  end

  def test_apply_turns_weekdays_and_a_local_time_into_the_utc_cron
    adopt
    post("/api/automations/apply", "slug" => "digest", "days" => [1, 5], "time" => "09:30")
    settle
    # Amsterdam is UTC+1 in winter and UTC+2 in summer.
    expected = Quartermaster::LocalSchedule.offset_minutes(Time.now) == 60 ? "30 8 * * 1,5" : "30 7 * * 1,5"
    assert_equal expected, store.read("digest").record["cron"]
  end

  def test_apply_refuses_a_cron_that_isnt_five_fields_and_writes_nothing
    adopt
    status, answer = post("/api/automations/apply", "slug" => "digest", "cron" => "every monday")
    assert_equal ["422 Unprocessable Content", false], [status, answer["ok"]]
    assert_match(/five fields/, answer["error"])
    assert_equal "0 7 * * 1,4", store.read("digest").record["cron"]
    assert_empty gui.jobs.running
  end

  def test_pause_resume_run_and_delete_run_as_jobs_and_move_the_item
    adopt
    post("/api/automations/pause", "slug" => "digest")
    settle
    assert_equal ["fridge", false], [Quartermaster::WorkItem.find("digest").state, @client.routines[ID]["enabled"]]
    assert_equal false, row(get("/api/automations"))["enabled"]

    post("/api/automations/resume", "slug" => "digest")
    settle
    assert_equal "active", Quartermaster::WorkItem.find("digest").state

    post("/api/automations/run", "slug" => "digest")
    assert_includes settle.map { |j| j["message"] }.join, "running"
    assert_includes @client.calls, [:run, ID]

    post("/api/automations/delete", "slug" => "digest")
    job = settle.first
    assert_match(/delete it on claude.ai/, job["message"])
    assert_equal "resolved", Quartermaster::WorkItem.find("digest").state
  end

  def test_a_stale_apply_is_refused_and_the_list_call_after_it_shows_the_drift
    adopt
    @client.touch(ID)
    post("/api/automations/apply", "slug" => "digest", "cron" => "30 6 * * 1")
    job = settle.first
    assert_equal false, job["ok"]
    assert_includes @client.calls, [:list]
    assert_equal true, row(get("/api/automations"))["drift"]
  end

  def test_a_routine_gone_from_claude_ai_shows_as_missing_even_when_none_are_left
    adopt
    @client.routines.clear
    post("/api/automations/refresh")
    settle
    assert_equal true, row(get("/api/automations"))["missing"]
  end

  def test_pushing_a_routine_gone_from_claude_ai_says_so_not_that_the_api_changed
    adopt
    @client.routines.clear
    post("/api/automations/push", "slug" => "digest")
    job = settle.first
    assert_equal false, job["ok"]
    assert_equal "digest: routine #{ID} isn't on claude.ai any more — delete the automation in qm " \
                 "(`qm automation delete digest`) or re-create it (`qm automation push digest --recreate`)", job["error"]
  end

  def test_recreate_makes_a_new_routine_for_a_missing_one_and_the_detail_stops_showing_missing
    adopt
    @client.routines.clear
    post("/api/automations/refresh")
    settle
    assert_equal true, get("/api/automations/digest")["missing"]

    status, = post("/api/automations/recreate", "slug" => "digest")
    assert_equal "200 OK", status
    job = settle.first
    assert job["ok"], job["error"]
    assert_equal "digest: re-created routine trig_NEW (was #{ID})", job["message"]
    assert_equal ["trig_NEW", "trig_NEW"], [store.read("digest").record["routine"], Quartermaster::WorkItem.find("digest").routine]
    detail = get("/api/automations/digest")
    assert_equal [false, "trig_NEW"], detail.values_at("missing", "routine")
  end

  def test_recreate_refuses_a_routine_that_is_still_there
    adopt
    post("/api/automations/refresh")
    settle
    assert_equal false, row(get("/api/automations"))["missing"]

    post("/api/automations/recreate", "slug" => "digest")
    job = settle.first
    assert_equal false, job["ok"]
    assert_equal "digest: routine #{ID} is still on claude.ai — `qm automation push digest` updates it", job["error"]
    assert_equal ID, store.read("digest").record["routine"]
    refute(@client.calls.any? { |c| c.first == :create })
  end

  def test_recreate_from_another_origin_or_without_one_is_refused
    adopt
    @client.routines.clear
    status, = post("/api/automations/recreate", { "slug" => "digest" }, { "host" => "127.0.0.1:4567", "origin" => "http://evil.example" })
    assert_equal "403 Forbidden", status
    status, = post("/api/automations/recreate", { "slug" => "digest" }, { "host" => "127.0.0.1:4567" })
    assert_equal "403 Forbidden", status
    assert_empty gui.jobs.running
    assert_empty @client.calls
  end

  def test_the_recreate_button_is_rendered_only_for_a_missing_routine
    page = served_page(gui, ok_host)
    assert page.match?(/d\.missing \? [^:]{0,300}data-au="recreate">Re-create on claude\.ai</m), "the button sits in the missing branch"
    assert_includes page, %(case "recreate": run("recreate"))
  end

  def test_force_push_overwrites_a_drifted_routine
    adopt
    @client.touch(ID)
    store.write("digest", { "name" => "Renamed" }, store.read("digest").prompt)
    post("/api/automations/push", "slug" => "digest", "force" => true)
    job = settle.first
    assert job["ok"], job["error"]
    assert_equal "Renamed", @client.routines[ID]["name"]
  end

  def test_the_detail_answers_the_local_files_and_loads_the_last_runs_on_request
    adopt
    detail = get("/api/automations/digest")
    assert_equal [nil, "idle"], detail.values_at("runs", "runsState")
    assert_equal store.prompt_path("digest"), detail["promptPath"]
    assert_equal "MyApp", detail["item"]["project"]
    assert_empty @client.calls

    post("/api/automations/runs", "slug" => "digest")
    assert_equal [true], settle.map { |j| j["quiet"] }
    detail = get("/api/automations/digest")
    assert_equal ["ok", ["https://claude.ai/code/cse_1"]], [detail["runsState"], detail["runs"].map { |r| r["url"] }]
    assert_equal [[:runs, ID, 10]], @client.calls, "runs alone, no GET of the routine"
  end

  def load_runs_then
    post("/api/automations/runs", "slug" => "digest")
    settle
    assert_equal "ok", get("/api/automations/digest")["runsState"]
    yield
    settle
    runs, state = get("/api/automations/digest").values_at("runs", "runsState")
    [runs&.map { |r| r["id"] }, state]
  end

  def test_runs_go_back_to_idle_after_an_action_on_that_automation_so_the_page_asks_again
    adopt
    assert_equal [["cse_1"], "idle"], load_runs_then { post("/api/automations/run", "slug" => "digest") }
  end

  def test_runs_go_back_to_idle_after_a_refused_action_too
    adopt
    @client.touch(ID)
    assert_equal [["cse_1"], "idle"], load_runs_then { post("/api/automations/apply", "slug" => "digest", "cron" => "30 6 * * 1") }
  end

  def test_a_refresh_sends_the_shown_runs_back_to_idle
    adopt
    assert_equal [["cse_1"], "idle"], load_runs_then { post("/api/automations/refresh") }
  end

  def test_the_detail_edits_the_items_description_through_the_describe_action
    adopt
    describe = { "cmd" => "describe", "slug" => "digest", "args" => { "text" => "Mondays and Thursdays: what shipped.\n" } }
    status, = post("/api/action", describe, { "host" => "127.0.0.1:4567", "origin" => "http://evil.example" })
    assert_equal "403 Forbidden", status
    status, = post("/api/action", describe, { "host" => "127.0.0.1:4567" })
    assert_equal "403 Forbidden", status

    status, answer = post("/api/action", describe)
    assert_equal ["200 OK", true], [status, answer["ok"]]
    assert_equal "Mondays and Thursdays: what shipped.", get("/api/automations/digest")["item"]["description"]
    assert_empty @client.calls, "a description is the item's, never pushed"

    page = served_page(gui, ok_host)
    assert_includes page, %(data-au="edit-description")
    assert_includes page, %(act("describe", { slug, args: { text } }))
  end

  # Opening the tab asks for runs and refreshes at once: runs that arrive
  # while that refresh is under way are already fresh.
  def test_runs_loaded_during_a_refresh_stay_loaded
    gate = Queue.new
    @client.define_singleton_method(:list) { gate.pop && super() }
    adopt
    post("/api/automations/refresh")
    post("/api/automations/runs", "slug" => "digest")
    Timeout.timeout(10) { sleep 0.02 until get("/api/automations/digest")["runsState"] == "ok" }
    gate << true
    settle
    assert_equal "ok", get("/api/automations/digest")["runsState"]
  end

  def test_new_creates_the_item_and_its_empty_files_for_the_chat_to_fill
    status, answer = post("/api/automations/new", "title" => "Weekly report", "project" => "MyApp")
    assert_equal ["200 OK", true, "weekly-report"], [status, answer["ok"], answer["slug"]]
    item = Quartermaster::WorkItem.find("weekly-report")
    assert_equal %w[automation cloud in_progress], [item.kind, item.runner, item.state]
    assert_equal "", store.read("weekly-report").prompt
    assert_empty @client.calls
  end

  def test_new_with_runner_local_creates_a_disabled_local_automation
    status, answer = post("/api/automations/new", "title" => "Weekly report", "project" => "MyApp", "runner" => "local")
    assert_equal ["200 OK", "weekly-report"], [status, answer["slug"]]
    assert_equal %w[local in_progress], [Quartermaster::WorkItem.find("weekly-report").runner, Quartermaster::WorkItem.find("weekly-report").state]
    assert_equal [false, "local"], store.read("weekly-report").record.values_at("enabled", "runner")
    assert_empty @client.calls
  end

  def test_off_until_the_token_source_is_set_and_nothing_reaches_the_client
    File.write(Quartermaster::CONFIG_FILE, "")
    remote = get("/api/automations")["remote"]
    assert_equal "off", remote["state"]
    assert_equal "qm config set automations.token_source claude_code", remote["command"]

    _status, answer = post("/api/automations/refresh")
    assert_equal "off", answer["remote"]["state"]
    assert_empty gui.jobs.running
    assert_empty @client.calls
  end

  def test_an_expired_token_is_a_state_of_the_tab_not_an_error_toast
    adopt
    @client.fail_with = Quartermaster::RoutinesClient::TokenExpired.new
    post("/api/automations/refresh")
    assert_equal [true], settle.map { |j| j["quiet"] }
    remote = get("/api/automations")["remote"]
    assert_equal "expired", remote["state"]
    assert_match(/login token expired/, remote["message"])

    post("/api/automations/run", "slug" => "digest")
    job = settle.first
    assert_equal [false, true], job.values_at("ok", "quiet")
  end

  def test_posts_from_another_origin_are_refused
    status, = post("/api/automations/refresh", {}, { "host" => "127.0.0.1:4567", "origin" => "http://evil.example" })
    assert_equal "403 Forbidden", status
    status, = post("/api/automations/refresh", {}, { "host" => "127.0.0.1:4567" })
    assert_equal "403 Forbidden", status
  end

  def test_the_page_has_the_settings_automations_tab_strip_and_reloads_after_automation_jobs
    page = served_page(gui, ok_host)
    assert_includes page, %(data-st-tab="automations")
    assert_includes page, %(id="au-body")
    assert_includes page, "fetch(\"/api/automations\")"
    assert_includes page, "if (automationJobFinished(r)) return;"
  end
end

# The tab's `runner: local` part: rows, detail and actions from the store and
# run logs, never the routines client. Runs open in a FakeTmux, guards and
# launchctl answer from a FakeRunner, the LaunchAgents directory is a temp dir.
class GuiLocalAutomationsTest < Minitest::Test
  include QmTestHelpers

  NoNetwork = Class.new { def method_missing(name, *) = raise("no #{name} call expected") }

  def setup
    super
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, GuiAutomationsTest::ON)
    @tmux = FakeTmux.new
    @runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false],
                             ["sh", "-c", "list-things"] => ["a\nb\n", "", true])
    @agents = Dir.mktmpdir("qm-agents")
  end

  def teardown
    FileUtils.rm_rf(@agents)
    super
  end

  # The GUI, its TickInstaller pointed at the temp LaunchAgents dir and the FakeRunner.
  def gui
    @gui ||= begin
      original = Quartermaster::TickInstaller.method(:new)
      runner = @runner
      agents = @agents
      Quartermaster::TickInstaller.define_singleton_method(:new) { |**kw| original.call(**kw, runner: runner, agents_dir: agents) }
      Quartermaster::Gui.new(port: 4567, runner: @runner, tmux: @tmux, routines: NoNetwork.new)
    ensure
      Quartermaster::TickInstaller.define_singleton_method(:new, original)
    end
  end

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def get(route)
    status, _type, body = gui.respond("GET", route, ok_host, "")
    assert_equal "200 OK", status, body
    JSON.parse(body)
  end

  def post(route, payload = {}, headers = ok_host)
    status, _type, body = gui.respond("POST", route, headers, JSON.generate(payload))
    [status, (JSON.parse(body) rescue body)]
  end

  def settle
    Timeout.timeout(10) { sleep 0.02 until gui.jobs.running.empty? }
    gui.jobs.take_finished
  end

  def store = Quartermaster::AutomationStore.new

  def log = Quartermaster::RunLog.new("nightly")

  def local_automation(**record)
    Quartermaster::WorkItem.create("Nightly", project: "MyApp", slug: "nightly", front: { "kind" => "automation", "runner" => "local" })
    base = { "runner" => "local", "name" => "Nightly", "cron" => "0 8 * * 1,4", "enabled" => true, "cwd" => Dir.home }
    store.write("nightly", base.merge(record), "Do the thing.\n")
  end

  # A run that started (session sess-<id>) in its own --run- chat.
  def started_run(key: "a", item: { "key" => "a", "title" => "Thing A" })
    id = log.enqueue(key: key, item: item, flow: "chat", trigger: "guard")
    log.started(id, session_id: "sess-#{id}", tmux: Quartermaster::ChatFlow.tmux_name("nightly", id), item_slug: "nightly")
    id
  end

  def test_a_local_row_reads_its_cron_in_local_time_and_its_last_run_from_the_run_log
    local_automation
    id = started_run
    log.finished(id)
    list = get("/api/automations")
    row = list["rows"].first
    assert_equal ["local", "Mon, Thu 08:00", [1, 4], "08:00", false], [row["runner"], *row["schedule"].values_at("label", "days", "time", "raw")]
    assert_equal "finished", row["lastRun"]["status"]
    assert_match(/T0[67]:00:00Z\z/, row["nextRunAt"], "08:00 Amsterdam is 06:00 or 07:00 UTC")
    header = list["local"]
    assert_equal [1, false, nil, true, false], header.values_at("count", "installed", "lastTickAt", "stale", "paused")
  end

  def test_the_local_detail_has_its_guard_queue_runs_and_last_guard_error
    local_automation("when" => "list-things")
    live = started_run
    @tmux.open(Quartermaster::ChatFlow.tmux_name("nightly", live), cwd: Dir.home, argv: ["claude"])
    ended = started_run(key: "b", item: { "key" => "b" })
    log.failed(ended, error: "boom")
    waiting = log.enqueue(key: "c", item: { "key" => "c" }, flow: "chat", trigger: "guard")
    log.waiting(waiting, reason: "Review chat for o/r#1 is open")
    log.guard_error(error: "guard failed: exit 2")
    refused = log.refuse_item(key: "d", item: { "key" => "d", "url" => "u" }, flow: "chat", reason: "repo o/r isn't in this automation's repos")

    d = get("/api/automations/nightly")
    assert_equal ["list-things", "chat", "attention", 30, "ok"], d.values_at("guard", "flow", "notify", "timeoutMinutes", "runsState")
    assert_equal "guard failed: exit 2", d["guardError"]["error"]
    assert_equal [[waiting, "c", "Review chat for o/r#1 is open"]], d["queue"].map { |q| q.values_at("id", "subject", "waiting") }
    runs = d["runs"].to_h { |r| [r["id"], r] }
    assert_equal ["live", "Thing A", "nightly--run-#{live}", false, false],
                 runs[live].values_at("status", "subject", "chat", "resumable", "retryable")
    assert_equal ["failed", "boom", nil, true, true], runs[ended].values_at("status", "error", "chat", "resumable", "retryable")
    assert_equal ["refused", "repo o/r isn't in this automation's repos", false, true],
                 runs[refused].values_at("status", "error", "resumable", "retryable")
    assert_equal "Nightly", d["item"]["title"]
  end

  def test_apply_saves_a_local_cron_unshifted_and_pushes_nothing
    local_automation
    status, answer = post("/api/automations/apply", "slug" => "nightly", "days" => [1, 4], "time" => "06:30", "prompt" => "New.\n")
    assert_equal ["200 OK", true, nil], [status, answer["ok"], answer["background"]]
    assert_equal ["30 6 * * 1,4", "New.\n"], [store.read("nightly").record["cron"], store.read("nightly").prompt]

    status, answer = post("/api/automations/apply", "slug" => "nightly", "cron" => "61 * * * *")
    assert_equal "422 Unprocessable Content", status
    assert_match(/minute/, answer["error"])
    assert_equal "30 6 * * 1,4", store.read("nightly").record["cron"]
  end

  def test_claude_ai_verbs_are_refused_for_a_local_automation
    local_automation
    %w[push pull recreate].each do |verb|
      status, answer = post("/api/automations/#{verb}", "slug" => "nightly")
      assert_equal ["422 Unprocessable Content", "nightly runs locally — nothing on claude.ai"], [status, answer["error"]]
    end
    assert_empty gui.jobs.running
  end

  def test_run_now_queues_a_manual_run_and_one_tick_starts_it_in_its_own_chat
    local_automation
    _status, answer = post("/api/automations/run", "slug" => "nightly")
    assert answer["background"]
    job = settle.first
    assert_equal [true, "nightly: started 1 run", "automation-nightly"], job.values_at("ok", "message", "key")
    run = log.recent.first
    assert_equal ["manual", "live"], [run.trigger, run.status]
    assert_equal ["nightly--run-#{run.id}"], @tmux.opened.map { |o| o[:name] }
  end

  # A tick whose flow kept the run queued says so in the run log (as a
  # pr-review run does while its Review chat is open); Run now says why.
  def test_run_now_names_the_flows_waiting_reason_when_the_run_stays_queued
    local_automation
    waiting_tick = Object.new
    run_log = log
    waiting_tick.define_singleton_method(:call) do |**|
      run_log.queue.each { |run| run_log.waiting(run.id, reason: "Review chat for o/r#1 is open") }
      { "started" => [], "running" => 0, "max_running" => 2 }
    end
    gui.instance_variable_get(:@automations).instance_variable_get(:@locals).local.instance_variable_set(:@tick, waiting_tick)
    post("/api/automations/run", "slug" => "nightly")
    assert_equal "nightly: queued 1 (waiting: Review chat for o/r#1 is open)", settle.first["message"]
  end

  def test_enable_with_mark_existing_as_seen_records_the_guards_keys_without_queuing
    local_automation("when" => "list-things", "enabled" => false)
    post("/api/automations/resume", "slug" => "nightly", "skipExisting" => true)
    job = settle.first
    assert_equal "nightly: enabled, 2 existing items marked seen", job["message"]
    assert_equal [true, Set["a", "b"], []], [store.read("nightly").record["enabled"], log.seen_keys, log.queue]
    assert_equal "active", Quartermaster::WorkItem.find("nightly").state

    _status, answer = post("/api/automations/pause", "slug" => "nightly")
    assert_equal [true, "nightly: paused"], answer.values_at("ok", "message")
    assert_equal [false, "fridge"], [store.read("nightly").record["enabled"], Quartermaster::WorkItem.find("nightly").state]
  end

  def test_retry_queues_an_ended_runs_item_again_and_resume_reopens_its_session
    local_automation
    id = started_run
    log.closed(id)
    post("/api/automations/retry", "slug" => "nightly", "run" => id)
    assert_equal "nightly: started 1 retry", settle.first["message"]
    retried = log.run(id).retried_as
    assert_equal [{ "key" => "a", "title" => "Thing A" }, "retry"], [log.run(retried).item, log.run(retried).trigger]

    _status, answer = post("/api/automations/resume-run", "slug" => "nightly", "run" => id)
    assert_equal [true, "nightly--run-#{id}"], answer.values_at("ok", "name")
    opened = @tmux.opened.last
    assert_equal [["--resume", "sess-#{id}"], { "QM_ITEM" => "nightly" }], [opened[:argv].last(2), opened[:env]]
  end

  def test_install_and_uninstall_tick_drive_launchctl_as_jobs
    local_automation
    _status, answer = post("/api/automations/install-tick")
    assert answer["background"]
    assert settle.first["ok"]
    plist = File.join(@agents, "#{Quartermaster::TickInstaller::LABEL}.plist")
    assert_includes @runner.argvs, ["launchctl", "bootstrap", "gui/#{Process.uid}", plist]
    assert_equal true, get("/api/automations")["local"]["installed"]

    post("/api/automations/uninstall-tick")
    assert settle.first["ok"]
    refute File.exist?(plist)
    assert_includes @runner.argvs, ["launchctl", "bootout", "gui/#{Process.uid}/#{Quartermaster::TickInstaller::LABEL}"]
  end

  def test_the_pause_toggle_writes_config_and_refuses_a_foreign_origin
    local_automation
    status, = post("/api/automations/local-pause", { "paused" => true }, { "host" => "127.0.0.1:4567", "origin" => "http://evil.example" })
    assert_equal "403 Forbidden", status
    _status, answer = post("/api/automations/local-pause", "paused" => true)
    assert_equal [true, true], answer.values_at("ok", "paused")
    assert_equal true, get("/api/automations")["local"]["paused"]
    assert_includes File.read(Quartermaster::CONFIG_FILE), "local_paused: true"
  end

  def test_a_live_run_chat_is_listed_with_the_loose_chats
    local_automation
    id = started_run
    chats = Quartermaster::RunChats.new.chats(["nightly--run-#{id}", "loose--abcd1234", "nightly", "gone--run-x"])
    assert_equal [["nightly--run-#{id}", { "slug" => "nightly", "id" => id, "quiet" => false }, "Nightly · Thing A", "none"]],
                 chats.map { |c| c.values_at("name", "run", "title", "state") }
  end

  def test_a_quiet_automations_run_chat_is_listed_but_left_out_of_the_title_count
    local_automation("notify" => "quiet")
    id = started_run
    assert_equal [true], Quartermaster::RunChats.new.chats(["nightly--run-#{id}"]).map { |c| c["run"]["quiet"] }
    assert_includes served_page(gui, ok_host), "...looseChats.filter(lc => !(lc.run && lc.run.quiet))"
  end

  def test_the_page_has_the_local_controls_and_lists_run_chats
    page = served_page(gui, ok_host)
    assert_includes page, "automationsTickBar(a.list.local)"
    assert_includes page, %(case "install-tick": automationJob("install-tick", {}, "automation-tick"))
    assert_includes page, %(data-au="local-pause")
    assert_includes page, %(data-au="mark-seen")
    assert_includes page, %(if (d.runner === "local") return automationLocalDetail(d);)
    assert_includes page, %(case "resume-run": resumeRun(slug, node.dataset.run))
    assert_includes page, %(id="au-new-runner")
    assert_includes page, %(renderLooseRows(list, "Runs ", looseChats.filter(lc => lc.run)))
    assert_includes page, "showAutomation(lc.run.slug)"
  end
end
