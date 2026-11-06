# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_tick_test.rb`).
require_relative "test_helper"

# The local automations' tick, at its #call seam: guards answer from a
# FakeRunner, chats open in a FakeTmux, session states come from a prepared
# events.jsonl and usage from a prepared rate-limits.json.
class AutomationTickTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  # 11:00 in Amsterdam (CET), a minute every */5 cron lists.
  NOW = Time.utc(2026, 11, 6, 10, 0, 0)
  GUARD = "list-things"

  def automation(slug, **record)
    base = { "runner" => "local", "name" => slug, "cron" => "*/5 * * * *", "enabled" => true, "cwd" => Dir.home }
    Quartermaster::AutomationStore.new.write(slug, base.merge(record), "Do the thing.\n")
  end

  def config(**automations)
    configure_projects({}, automations: automations.transform_keys(&:to_s))
  end

  def tick(runner: FakeRunner.new, tmux: FakeTmux.new, **rest)
    Quartermaster::AutomationTick.new(runner: runner, tmux: tmux, **rest)
  end

  def log(slug) = Quartermaster::RunLog.new(slug)

  def events(slug)
    path = log(slug).path
    File.exist?(path) ? File.readlines(path).map { JSON.parse(_1) } : []
  end

  def guard_says(out, success: true, err: "")
    FakeRunner.new(["sh", "-c", GUARD] => [out, err, success])
  end

  def rate_limits(five:, seven: 10, resets_in: 3600)
    Quartermaster.ensure_setup
    File.write(Quartermaster::RateLimits::FILE, JSON.generate(
      "v" => 1, "captured_at" => NOW.to_i,
      "five_hour" => { "used_percentage" => five, "resets_at" => NOW.to_i + resets_in },
      "seven_day" => { "used_percentage" => seven, "resets_at" => NOW.to_i + 86_400 }
    ))
  end

  # A run already going: queued, started, its session live (this process).
  def live_run(slug, session_id, *turn_events)
    run_log = log(slug)
    id = run_log.enqueue(key: "k-#{session_id}", item: nil, flow: "chat", trigger: "manual", at: NOW - 900)
    run_log.started(id, session_id: session_id, tmux: "#{slug}--run-#{id}", item_slug: slug, at: NOW - 900)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)
    log_events(session_id, *turn_events) unless turn_events.empty?
    id
  end

  def test_a_due_cron_without_a_guard_queues_one_run_and_starts_it_in_its_own_chat
    automation("nightly")
    tmux = FakeTmux.new

    summary = tick(tmux: tmux).call(now: NOW)

    queued, checked, started = events("nightly")
    assert_equal "checked", checked["event"]
    assert_equal ["queued", "cron:2026-11-06T10:00:00Z", "cron", nil], queued.values_at("event", "key", "trigger", "item")
    assert_equal ["started", queued["run_id"], "nightly--run-#{queued["run_id"]}"], started.values_at("event", "run_id", "tmux")
    assert_equal "nightly--run-#{queued["run_id"]}", tmux.opened.first[:name]
    assert_equal "Do the thing.\n", tmux.opened.first[:argv].last
    assert_equal [["nightly", queued["run_id"]]], summary["started"]
    state = Quartermaster::AutomationTick.state
    assert_equal [1, "2026-11-06T10:00:00Z", 1, 2], state.values_at("v", "last_tick_at", "running", "max_running")
  end

  def test_a_cron_that_is_not_due_queues_nothing
    automation("nightly", "cron" => "30 3 * * *")

    tick.call(now: NOW)

    assert_empty events("nightly")
  end

  def test_missed_cron_minutes_coalesce_into_one_queued_run
    automation("nightly")
    rate_limits(five: 95, resets_in: 7200)

    tick.call(now: NOW)
    tick.call(now: NOW + 600)
    tick.call(now: NOW + 3600)

    assert_equal 1, log("nightly").queue.size
    assert_equal 3, events("nightly").count { _1["event"] == "checked" }
  end

  def test_a_guard_queues_one_run_per_line_and_refuses_a_json_line_without_a_key
    config(local_max_running: 0)
    automation("triage", "when" => GUARD)
    runner = guard_says(%({"key":"pr-1","url":"https://x/1"}\nplain line\n\n{"url":"no key"}\n))

    tick(runner: runner).call(now: NOW)

    assert_equal [{ argv: ["sh", "-c", GUARD], chdir: Dir.home, timeout: 60 }], runner.calls
    items = log("triage").queue.map(&:item)
    assert_equal [{ "key" => "pr-1", "url" => "https://x/1" }, { "key" => "plain line", "line" => "plain line" }], items
    assert_equal %w[guard guard], log("triage").queue.map(&:trigger)
    assert_equal "a guard's JSON item needs a string key", log("triage").last_guard_error["error"]
  end

  def test_a_guard_item_already_seen_is_not_queued_again
    config(local_max_running: 0)
    automation("triage", "when" => GUARD)
    runner = guard_says("a\nb\n")

    tick(runner: runner).call(now: NOW)
    summary = tick(runner: guard_says("b\nc\n")).call(now: NOW + 300)

    assert_equal %w[a b c], log("triage").queue.map(&:key)
    assert_equal 1, summary["queued"].size
  end

  def test_a_failing_guard_queues_nothing_and_records_the_error
    automation("triage", "when" => GUARD)

    summary = tick(runner: guard_says("x\n", success: false, err: "boom\n")).call(now: NOW)

    assert_empty log("triage").queue
    assert_equal "guard failed: boom", log("triage").last_guard_error["error"]
    assert_empty summary["queued"]
  end

  def test_an_item_lacking_a_field_its_flow_needs_is_a_guard_error
    automation("reviews", "when" => GUARD, "flow" => "pr-review")

    tick(runner: guard_says("not a url\n")).call(now: NOW)

    assert_empty log("reviews").queue
    assert_includes log("reviews").last_guard_error["error"], "lacks url"
  end

  PR_LINES = %({"key":"a","url":"https://github.com/acme/WebApp/pull/1"}\n{"key":"b","url":"https://github.com/stranger/fork/pull/2"}\n)

  def test_a_pr_review_guard_queues_listed_repos_and_refuses_the_rest_once
    config(local_max_running: 0)
    automation("reviews", "when" => GUARD, "flow" => "pr-review", "repos" => ["acme/webapp"])

    tick(runner: guard_says(PR_LINES)).call(now: NOW)
    tick(runner: guard_says(PR_LINES)).call(now: NOW + 300)

    assert_equal %w[a], log("reviews").queue.map(&:key)
    refused = events("reviews").select { _1["event"] == "refused" }
    assert_equal [["b", "repo stranger/fork isn't in this automation's repos"]], refused.map { _1.values_at("key", "reason") }
    assert_equal "https://github.com/stranger/fork/pull/2", refused.first["item"]["url"]
    run = log("reviews").recent.first
    assert_equal ["refused", "b"], [run.status, run.key]
  end

  def test_a_pr_review_automation_without_repos_queues_nothing
    automation("reviews", "when" => GUARD, "flow" => "pr-review")
    tmux = FakeTmux.new

    tick(runner: guard_says(PR_LINES), tmux: tmux).call(now: NOW)

    assert_empty log("reviews").queue
    assert_empty tmux.opened
    assert_equal %w[a b], events("reviews").select { _1["event"] == "refused" }.map { _1["key"] }
    assert_includes log("reviews").recent.first.error, "no repos list"
  end

  def test_a_queued_pr_review_run_whose_repo_left_the_list_is_refused_at_start
    automation("reviews", "flow" => "pr-review", "repos" => ["acme/other"], "cron" => "")
    id = log("reviews").enqueue(key: "a", item: { "key" => "a", "url" => "https://github.com/acme/WebApp/pull/1" },
                                flow: "pr-review", trigger: "manual", at: NOW - 60)
    tmux = FakeTmux.new

    summary = tick(tmux: tmux).call(now: NOW)

    assert_empty tmux.opened
    assert_equal ["refused", "repo acme/WebApp isn't in this automation's repos"], log("reviews").run(id).then { [_1.status, _1.error] }
    assert_empty summary["started"]
  end

  def test_paused_runs_no_guard_and_starts_nothing
    config(local_paused: true)
    automation("triage", "when" => GUARD)
    log("triage").enqueue(key: "old", item: nil, flow: "chat", trigger: "manual", at: NOW - 60)
    runner = guard_says("a\n")
    tmux = FakeTmux.new

    summary = tick(runner: runner, tmux: tmux).call(now: NOW)

    assert_empty runner.calls
    assert_empty tmux.opened
    assert_equal true, summary["paused"]
    assert_equal true, Quartermaster::AutomationTick.state["paused"]
  end

  def test_a_disabled_automation_runs_no_guard_and_starts_only_its_manual_and_retry_runs
    config(local_max_running: 5)
    automation("triage", "when" => GUARD, "enabled" => false)
    run_log = log("triage")
    run_log.enqueue(key: "cron:2026-11-06T09:55:00Z", item: nil, flow: "chat", trigger: "cron", at: NOW - 240)
    run_log.enqueue(key: "from-guard", item: nil, flow: "chat", trigger: "guard", at: NOW - 180)
    manual = run_log.enqueue(key: "by-hand", item: nil, flow: "chat", trigger: "manual", at: NOW - 120)
    retried = run_log.enqueue(key: "again", item: nil, flow: "chat", trigger: "retry", at: NOW - 60)
    runner = guard_says("a\n")
    tmux = FakeTmux.new

    summary = tick(runner: runner, tmux: tmux).call(now: NOW)

    assert_empty runner.calls
    assert_equal [["triage", manual], ["triage", retried]], summary["started"]
    assert_equal ["triage--run-#{manual}", "triage--run-#{retried}"], tmux.opened.map { _1[:name] }
    assert_equal ["cron:2026-11-06T09:55:00Z", "from-guard"], log("triage").queue.map(&:key)
  end

  def test_a_manual_run_of_a_disabled_automation_still_waits_while_paused_or_held
    automation("triage", "enabled" => false)
    log("triage").enqueue(key: "by-hand", item: nil, flow: "chat", trigger: "manual", at: NOW - 60)
    tmux = FakeTmux.new

    config(local_paused: true)
    tick(tmux: tmux).call(now: NOW)
    config(local_paused: false)
    rate_limits(five: 99)
    tick(tmux: tmux).call(now: NOW + 300)

    assert_empty tmux.opened
    assert_equal ["by-hand"], log("triage").queue.map(&:key)
  end

  def test_a_usage_limit_over_its_hold_starts_nothing_but_guards_still_run
    automation("triage", "when" => GUARD)
    rate_limits(five: 84)
    tmux = FakeTmux.new

    summary = tick(runner: guard_says("a\n"), tmux: tmux).call(now: NOW)

    assert_equal "5h at 84%", summary["held"]
    assert_equal ["a"], log("triage").queue.map(&:key)
    assert_empty tmux.opened
  end

  def test_the_weekly_limit_holds_too
    automation("nightly")
    rate_limits(five: 10, seven: 91)

    assert_equal "7d at 91%", tick.call(now: NOW)["held"]
  end

  def test_a_snapshot_whose_five_hour_window_has_reset_holds_nothing
    automation("nightly")
    rate_limits(five: 99, seven: 99, resets_in: -60)
    tmux = FakeTmux.new

    summary = tick(tmux: tmux).call(now: NOW)

    assert_nil summary["held"]
    assert_equal 1, tmux.opened.size
  end

  def test_the_cap_counts_runs_whose_session_works
    config(local_max_running: 1)
    automation("nightly")
    live_run("nightly", "s-working", [60, "UserPromptSubmit"])
    tmux = FakeTmux.new

    summary = tick(tmux: tmux).call(now: NOW)

    assert_empty tmux.opened
    assert_equal 1, summary["running"]
    assert_equal 1, log("nightly").queue.size
  end

  def test_a_run_whose_turn_ended_frees_its_slot
    config(local_max_running: 1)
    automation("nightly")
    live_run("nightly", "s-done", [120, "UserPromptSubmit"], [60, "Stop"])
    tmux = FakeTmux.new

    tick(tmux: tmux).call(now: NOW)

    assert_equal 1, tmux.opened.size
  end

  def test_a_run_whose_session_has_not_reported_yet_holds_its_slot_while_its_tmux_lives
    config(local_max_running: 1)
    automation("nightly")
    run_log = log("nightly")
    id = run_log.enqueue(key: "k", item: nil, flow: "chat", trigger: "manual", at: NOW - 60)
    run_log.started(id, session_id: "s-unseen", tmux: "nightly--run-#{id}", item_slug: "nightly", at: NOW - 60)

    held = FakeTmux.new(["nightly--run-#{id}"])
    tick(tmux: held).call(now: NOW)
    assert_equal 0, held.opened.size

    gone = FakeTmux.new
    tick(tmux: gone).call(now: NOW + 300)
    assert_equal 1, gone.opened.size
  end

  def test_guard_items_queued_in_one_tick_start_in_the_order_the_guard_printed_them
    config(local_max_running: 1)
    keys = ("a".."t").to_a
    automation("triage", "when" => GUARD)
    tmux = FakeTmux.new

    tick(runner: guard_says(keys.join("\n")), tmux: tmux).call(now: NOW)

    assert_equal keys.drop(1), log("triage").queue.map(&:key)
    assert_equal ["Do the thing.\n\n## Item\n\na"], tmux.opened.map { _1[:argv].last }
  end

  def test_queued_runs_start_oldest_first_across_automations
    config(local_max_running: 1)
    automation("alpha", "cron" => "")
    automation("beta", "cron" => "")
    log("alpha").enqueue(key: "newer", item: nil, flow: "chat", trigger: "manual", at: NOW - 60)
    older = log("beta").enqueue(key: "older", item: nil, flow: "chat", trigger: "manual", at: NOW - 120)
    tmux = FakeTmux.new

    tick(tmux: tmux).call(now: NOW)

    assert_equal ["beta--run-#{older}"], tmux.opened.map { _1[:name] }
    assert_equal ["newer"], log("alpha").queue.map(&:key)
  end

  # A flow that can't start yet (a Review chat already open) leaves the run
  # queued with its reason and uses no slot.
  class WaitingFlows
    def initialize(waiting_key) = @waiting_key = waiting_key
    def problem(*) = nil

    def start(automation, item, _prompt, run_id:, session_id:)
      return { waiting: "Review chat for acme/app#1 is open" } if item && item["key"] == @waiting_key

      { item_slug: automation.slug, tmux: "#{automation.slug}--run-#{run_id}" }
    end
  end

  def test_a_run_its_flow_holds_back_stays_queued_with_its_reason_and_uses_no_slot
    config(local_max_running: 1)
    automation("reviews", "cron" => "")
    waiting = log("reviews").enqueue(key: "pr-1", item: { "key" => "pr-1" }, flow: "chat", trigger: "guard", at: NOW - 120)
    other = log("reviews").enqueue(key: "pr-2", item: { "key" => "pr-2" }, flow: "chat", trigger: "guard", at: NOW - 60)

    tick(flows: WaitingFlows.new("pr-1")).call(now: NOW)
    tick(flows: WaitingFlows.new("pr-1")).call(now: NOW + 300)

    assert_equal "Review chat for acme/app#1 is open", log("reviews").run(waiting).waiting
    assert log("reviews").run(waiting).queued?
    assert log("reviews").run(other).live?
    assert_equal 1, events("reviews").count { _1["event"] == "waiting" }
  end

  def test_a_run_that_fails_to_start_is_marked_failed_and_the_tick_goes_on
    automation("nightly", "cron" => "")
    id = log("nightly").enqueue(key: "k", item: nil, flow: "chat", trigger: "manual", at: NOW - 60)
    tmux = FakeTmux.new(["nightly--run-#{id}"])

    summary = tick(tmux: tmux).call(now: NOW)

    assert_equal "failed", log("nightly").run(id).status
    assert_includes log("nightly").run(id).error, "already running"
    assert_equal [["nightly", id]], summary["failed"]
  end

  def test_a_tick_while_another_holds_the_lock_does_nothing
    automation("nightly")
    FileUtils.mkdir_p(Quartermaster::AUTOMATIONS_DIR)
    File.open(File.join(Quartermaster::AUTOMATIONS_DIR, "tick.lock"), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)

      assert_equal({ "locked" => true }, tick.call(now: NOW))
    end
    assert_empty events("nightly")
  end

  class BrokenConfig
    def local_automations = raise("config exploded")
  end

  def test_a_tick_never_raises
    automation("nightly")

    assert_nil tick(config: BrokenConfig.new).call(now: NOW)
    assert_includes File.read(File.join(Quartermaster::ROOT, "qm.log")), "config exploded"
  end

  def test_a_dry_run_lists_what_the_guard_would_queue_and_writes_nothing
    automation("triage", "when" => GUARD)
    log("triage").mark_seen(["a"])
    seen_before = events("triage")

    dry = tick(runner: guard_says("a\nb\n{\"x\":1}\nb\n")).dry_run("triage")

    assert_equal [{ "key" => "b", "line" => "b" }], dry.items
    assert_equal [{ "key" => "a", "line" => "a" }, { "key" => "b", "line" => "b" }], dry.seen
    assert_equal ["a guard's JSON item needs a string key"], dry.problems.map { _1["error"] }
    assert_equal seen_before, events("triage")
  end

  def test_a_dry_run_of_an_automation_without_a_guard_says_so
    automation("nightly")

    error = assert_raises(ArgumentError) { tick.dry_run("nightly") }
    assert_includes error.message, "has no guard"
  end

  def test_queue_guard_queues_new_items_as_a_manual_run
    automation("triage", "when" => GUARD)

    ids = tick(runner: guard_says("a\n")).queue_guard("triage", now: NOW)

    assert_equal ["manual"], ids.map { log("triage").run(_1).trigger }
  end

  def test_a_command_past_its_timeout_is_killed_and_fails
    started = Time.now
    result = Quartermaster::CommandRunner.new.call(["sh", "-c", "sleep 5; echo late"], timeout: 0.3)

    refute result.success?
    assert_equal "timed out after 0.3 s", result.err
    assert_operator Time.now - started, :<, 3
  end

  def test_a_command_within_its_timeout_answers_as_usual
    result = Quartermaster::CommandRunner.new.call(["sh", "-c", "echo hi; echo err >&2"], timeout: 5)

    assert result.success?
    assert_equal ["hi\n", "err\n"], [result.out, result.err]
  end
end
