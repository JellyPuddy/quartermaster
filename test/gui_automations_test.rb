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
    assert_includes @client.calls, [:runs, ID, 10]
  end

  def test_new_creates_the_item_and_its_empty_files_for_the_chat_to_fill
    status, answer = post("/api/automations/new", "title" => "Weekly report", "project" => "MyApp")
    assert_equal ["200 OK", true, "weekly-report"], [status, answer["ok"], answer["slug"]]
    item = Quartermaster::WorkItem.find("weekly-report")
    assert_equal %w[automation cloud in_progress], [item.kind, item.runner, item.state]
    assert_equal "", store.read("weekly-report").prompt
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
