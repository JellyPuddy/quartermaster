# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_run_lifecycle_test.rb`).
require_relative "test_helper"

# What a tick does with runs already started, at its #call seam: a run whose
# turn ended is finished, a finished `--run-` chat left alone for an hour is
# closed, an untouched run working past its timeout is stopped — and a run
# the user typed into is theirs. Session states come from a prepared
# events.jsonl counted back from the test's one clock reading.
class AutomationRunLifecycleTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def now = fixed_now

  def automation(title, **record)
    item = Quartermaster::WorkItem.create(title, project: "No project")
    base = { "runner" => "local", "name" => title, "cron" => "", "enabled" => true, "cwd" => Dir.home }
    Quartermaster::AutomationStore.new.write(item.slug, base.merge(record), "Do the thing.\n")
    item.slug
  end

  def log(slug) = Quartermaster::RunLog.new(slug)

  def notifier(runner) = Quartermaster::TurnNotifier.new(runner: runner, terminal_notifier: nil)

  def tick(tmux:, runner: FakeRunner.new)
    Quartermaster::AutomationTick.new(runner: runner, tmux: tmux, notifier: notifier(runner))
  end

  # A started run whose session (live, this process) reported these events;
  # tmux: the name it runs under (a pr-review run's is the Review item's slug).
  def started_run(slug, session_id, *turn_events, ago: 600, tmux: nil)
    run_log = log(slug)
    id = run_log.enqueue(key: "k-#{session_id}", item: nil, flow: "chat", trigger: "manual", at: now - ago)
    run_log.started(id, session_id: session_id, tmux: tmux || "#{slug}--run-#{id}", item_slug: slug, at: now - ago)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)
    log_events(session_id, *turn_events) unless turn_events.empty?
    id
  end

  def test_a_run_whose_turn_ended_is_finished_and_its_chat_stays_open_within_the_hour
    slug = automation("Nightly")
    id = started_run(slug, "s1", [600, "UserPromptSubmit"], [300, "Stop"])
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert_equal "finished", log(slug).run(id).status
    assert tmux.live?("#{slug}--run-#{id}")
  end

  def test_a_finished_run_idle_for_an_hour_is_closed
    slug = automation("Nightly")
    id = started_run(slug, "s1", [7200, "UserPromptSubmit"], [3700, "Stop"], ago: 7200)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)
    assert_equal "finished", log(slug).run(id).status

    tick(tmux: tmux).call(now: now)
    refute tmux.live?("#{slug}--run-#{id}")
    assert_equal "closed", log(slug).run(id).status
  end

  def test_a_run_the_user_typed_into_is_never_closed
    slug = automation("Nightly")
    id = started_run(slug, "s1", [7200, "UserPromptSubmit"], [7000, "Stop"], [6000, "UserPromptSubmit"],
                     [3700, "Stop"], ago: 7200)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    2.times { tick(tmux: tmux).call(now: now) }

    assert tmux.live?("#{slug}--run-#{id}")
    assert_equal "finished", log(slug).run(id).status
  end

  def test_a_run_working_past_its_timeout_is_stopped_noted_and_announced
    slug = automation("Nightly")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], [60, "PostToolUse", "Bash"], ago: 1900)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])
    runner = FakeRunner.new

    summary = tick(tmux: tmux, runner: runner).call(now: now)

    refute tmux.live?("#{slug}--run-#{id}")
    assert_equal "timed_out", log(slug).run(id).status
    assert_equal [[slug, id]], summary["timed_out"]
    note = Quartermaster::WorkItem.find(slug).notes.last
    assert_equal ["history", "run #{id} timed out after 30 min"], [note.kind, note.text]
    assert_equal ["osascript", "Nightly", "Run #{id} timed out after 30 min"], runner.argvs.last.values_at(0, -2, -1)
  end

  def test_a_run_within_its_timeout_keeps_working
    slug = automation("Nightly", "timeout_minutes" => 60)
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], ago: 1900)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert tmux.live?("#{slug}--run-#{id}")
    assert_equal "live", log(slug).run(id).status
  end

  def test_a_blocked_run_never_times_out
    slug = automation("Nightly")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], [1800, "PermissionRequest", "Bash"], ago: 1900)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert tmux.live?("#{slug}--run-#{id}")
    assert_equal "live", log(slug).run(id).status
  end

  def test_a_run_the_user_typed_into_never_times_out
    slug = automation("Nightly")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], [1850, "Stop"], [1800, "UserPromptSubmit"], ago: 1900)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert tmux.live?("#{slug}--run-#{id}")
    assert_equal "live", log(slug).run(id).status
  end

  def test_a_pr_review_run_past_its_timeout_is_only_marked_and_its_review_chat_stays
    slug = automation("Reviews", "flow" => "pr-review")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], ago: 1900, tmux: "review-acme-app-1")
    tmux = FakeTmux.new(["review-acme-app-1"])
    runner = FakeRunner.new

    tick(tmux: tmux, runner: runner).call(now: now)

    assert tmux.live?("review-acme-app-1")
    assert_equal "timed_out", log(slug).run(id).status
    assert_equal "osascript", runner.argvs.last.first
  end

  def test_a_finished_pr_review_run_is_never_closed
    slug = automation("Reviews", "flow" => "pr-review")
    id = started_run(slug, "s1", [7200, "UserPromptSubmit"], [3700, "Stop"], ago: 7200, tmux: "review-acme-app-1")
    tmux = FakeTmux.new(["review-acme-app-1"])

    2.times { tick(tmux: tmux).call(now: now) }

    assert tmux.live?("review-acme-app-1")
    assert_equal "finished", log(slug).run(id).status
  end

  def test_lifecycle_checks_run_while_paused
    configure_projects({}, automations: { "local_paused" => true })
    slug = automation("Nightly")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], ago: 1900)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert_equal "timed_out", log(slug).run(id).status
  end

  def test_a_timed_out_run_frees_its_slot_in_the_same_tick
    configure_projects({}, automations: { "local_max_running" => 1 })
    slug = automation("Nightly")
    id = started_run(slug, "s1", [1900, "UserPromptSubmit"], ago: 1900)
    queued = log(slug).enqueue(key: "next", item: nil, flow: "chat", trigger: "manual", at: now - 60)
    tmux = FakeTmux.new(["#{slug}--run-#{id}"])

    tick(tmux: tmux).call(now: now)

    assert_equal ["#{slug}--run-#{queued}"], tmux.opened.map { _1[:name] }
  end
end
