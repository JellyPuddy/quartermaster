# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/run_log_test.rb`).
require_relative "test_helper"

class RunLogTest < Minitest::Test
  include QmTestHelpers

  T0 = Time.utc(2026, 11, 6, 9, 0, 0)

  def log = Quartermaster::RunLog.new("digest")

  def path = File.join(Quartermaster::ROOT, "automations", "digest.runs.jsonl")

  def lines = File.readlines(path).map { |l| JSON.parse(l) }

  def test_an_absent_log_folds_to_nothing
    assert_empty log.queue
    assert_empty log.live
    assert_empty log.recent
    assert_empty log.seen_keys
    assert_nil log.last_guard_error
    assert_nil log.last_cron_check
    refute log.cron_queued?
  end

  def test_every_line_carries_v_at_and_event_and_writes_only_append
    id = log.enqueue(key: "a", item: { "key" => "a" }, flow: "chat", trigger: "guard", at: T0)
    log.started(id, session_id: "s-1", tmux: "digest--run-#{id}", item_slug: "digest", at: T0 + 60)

    first, second = lines
    assert_equal({ "v" => 1, "at" => "2026-11-06T09:00:00Z", "event" => "queued", "run_id" => id, "key" => "a",
                   "item" => { "key" => "a" }, "flow" => "chat", "trigger" => "guard" }, first)
    assert_equal %w[v at event run_id session_id tmux item_slug], second.keys
    assert_match(/\A[a-z0-9]+\z/, id)
  end

  def test_the_queue_holds_queued_runs_not_yet_started_oldest_first
    a = log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    b = log.enqueue(key: "b", item: nil, flow: "chat", trigger: "guard", at: T0 + 1)
    c = log.enqueue(key: "c", item: nil, flow: "chat", trigger: "guard", at: T0 + 2)
    log.started(b, session_id: "s-b", tmux: "t", item_slug: "digest", at: T0 + 3)

    assert_equal [a, c], log.queue.map(&:id)
    assert_equal [b], log.live.map(&:id)
  end

  def test_a_run_ends_live_on_finished_timed_out_closed_or_failed
    ids = %w[finished timed_out closed failed].to_h do |ending|
      id = log.enqueue(key: ending, item: nil, flow: "chat", trigger: "guard", at: T0)
      log.started(id, session_id: "s-#{ending}", tmux: "t", item_slug: "digest", at: T0 + 1)
      [ending, id]
    end
    still = log.enqueue(key: "still", item: nil, flow: "chat", trigger: "guard", at: T0)
    log.started(still, session_id: "s-still", tmux: "t", item_slug: "digest", at: T0 + 1)
    log.finished(ids["finished"], at: T0 + 2)
    log.timed_out(ids["timed_out"], at: T0 + 2)
    log.closed(ids["closed"], at: T0 + 2)
    log.failed(ids["failed"], error: "tmux said no", at: T0 + 2)

    assert_equal [still], log.live.map(&:id)
    statuses = log.recent.to_h { |run| [run.key, run.status] }
    assert_equal({ "finished" => "finished", "timed_out" => "timed_out", "closed" => "closed", "failed" => "failed",
                   "still" => "live" }, statuses)
    assert_equal "tmux said no", log.run(ids["failed"]).error
  end

  def test_a_finished_run_closed_later_reads_closed
    id = log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    log.started(id, session_id: "s", tmux: "t", item_slug: "digest", at: T0 + 1)
    log.finished(id, at: T0 + 2)
    log.closed(id, at: T0 + 3)

    run = log.run(id)
    assert_equal "closed", run.status
    assert_equal T0 + 2, run.finished_at
    assert_equal T0 + 3, run.ended_at
  end

  def test_a_run_that_fails_before_it_starts_leaves_the_queue
    id = log.enqueue(key: "a", item: nil, flow: "pr-review", trigger: "guard", at: T0)
    log.failed(id, error: "no such PR", at: T0 + 1)

    assert_empty log.queue
    assert_equal "failed", log.run(id).status
  end

  def test_recent_lists_runs_that_left_the_queue_newest_first
    a = log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    b = log.enqueue(key: "b", item: nil, flow: "chat", trigger: "guard", at: T0)
    log.enqueue(key: "c", item: nil, flow: "chat", trigger: "guard", at: T0)
    log.started(a, session_id: "s-a", tmux: "t", item_slug: "digest", at: T0 + 10)
    log.started(b, session_id: "s-b", tmux: "t", item_slug: "digest", at: T0 + 20)

    assert_equal [b, a], log.recent.map(&:id)
    assert_equal [b], log.recent(limit: 1).map(&:id)
  end

  def test_a_guard_item_whose_key_was_seen_is_not_queued_again
    first = log.enqueue_item(key: "pr-1", item: { "key" => "pr-1" }, flow: "chat", at: T0)
    again = log.enqueue_item(key: "pr-1", item: { "key" => "pr-1" }, flow: "chat", at: T0 + 300)

    refute_nil first
    assert_nil again
    assert_equal 1, log.queue.size
    assert_equal ["pr-1"], log.seen_keys.to_a
  end

  def test_dedupe_and_coalescing_see_what_another_writer_appended
    mine = log
    mine.queue
    theirs = Quartermaster::RunLog.new("digest")
    theirs.enqueue_item(key: "pr-1", item: nil, flow: "chat", at: T0)
    theirs.enqueue_cron(due: T0, flow: "chat", at: T0)
    queued = theirs.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    theirs.started(queued, session_id: "s", tmux: "t", item_slug: "digest", at: T0)
    theirs.failed(queued, error: "x", at: T0)
    theirs.retry(queued, at: T0)

    assert_nil mine.enqueue_item(key: "pr-1", item: nil, flow: "chat", at: T0 + 1)
    assert_nil mine.enqueue_cron(due: T0 + 60, flow: "chat", at: T0 + 1)
    assert_equal 3, lines.count { |l| l["event"] == "queued" && l["trigger"] != "retry" }
  end

  def test_a_key_stays_consumed_after_its_run_failed
    id = log.enqueue_item(key: "pr-1", item: nil, flow: "chat", at: T0)
    log.started(id, session_id: "s", tmux: "t", item_slug: "digest", at: T0 + 1)
    log.timed_out(id, at: T0 + 2)

    assert_nil log.enqueue_item(key: "pr-1", item: nil, flow: "chat", at: T0 + 300)
  end

  def test_keys_marked_seen_without_queuing_are_skipped_by_later_guard_runs
    log.mark_seen(%w[pr-1 pr-2], at: T0)

    assert_empty log.queue
    assert_nil log.enqueue_item(key: "pr-2", item: nil, flow: "chat", at: T0 + 1)
    refute_nil log.enqueue_item(key: "pr-3", item: nil, flow: "chat", at: T0 + 1)
    assert_equal %w[pr-1 pr-2 pr-3], log.seen_keys.to_a.sort
  end

  def test_cron_runs_coalesce_into_one_queued_run
    first = log.enqueue_cron(due: Time.utc(2026, 11, 6, 7, 0), flow: "chat", at: T0)
    second = log.enqueue_cron(due: Time.utc(2026, 11, 6, 8, 0), flow: "chat", at: T0 + 3600)

    assert_nil second
    assert log.cron_queued?
    assert_equal ["cron:2026-11-06T07:00:00Z"], log.queue.map(&:key)
    assert_equal "cron", log.run(first).trigger
    assert_nil log.run(first).item
  end

  def test_a_new_cron_run_queues_once_the_previous_one_started
    first = log.enqueue_cron(due: Time.utc(2026, 11, 6, 7, 0), flow: "chat", at: T0)
    log.started(first, session_id: "s", tmux: "t", item_slug: "digest", at: T0 + 1)

    refute log.cron_queued?
    refute_nil log.enqueue_cron(due: Time.utc(2026, 11, 7, 7, 0), flow: "chat", at: T0 + 86_400)
  end

  def test_a_queued_guard_or_manual_run_does_not_hold_back_a_cron_run
    log.enqueue(key: "manual:1", item: nil, flow: "chat", trigger: "manual", at: T0)

    refute log.cron_queued?
    refute_nil log.enqueue_cron(due: T0, flow: "chat", at: T0)
  end

  def test_retry_queues_a_new_run_with_the_same_item_bypassing_dedupe
    item = { "key" => "pr-1", "url" => "https://github.com/o/r/pull/1" }
    id = log.enqueue_item(key: "pr-1", item: item, flow: "pr-review", at: T0)
    log.started(id, session_id: "s", tmux: "t", item_slug: "review-pr-1", at: T0 + 1)
    log.failed(id, error: "boom", at: T0 + 2)

    new_id = log.retry(id, at: T0 + 60)

    refute_equal id, new_id
    retried = log.run(new_id)
    assert_equal ["pr-1", item, "pr-review", "retry"], [retried.key, retried.item, retried.flow, retried.trigger]
    assert_equal [new_id], log.queue.map(&:id)
    assert_equal new_id, log.run(id).retried_as
    assert_equal({ "event" => "retried", "run_id" => id, "new_run_id" => new_id }, lines[-2].slice("event", "run_id", "new_run_id"))
  end

  def test_retry_refuses_an_unknown_queued_or_live_run
    queued = log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    live = log.enqueue(key: "b", item: nil, flow: "chat", trigger: "guard", at: T0)
    log.started(live, session_id: "s", tmux: "t", item_slug: "digest", at: T0 + 1)

    assert_raises(ArgumentError) { log.retry("nope", at: T0) }
    assert_raises(ArgumentError) { log.retry(queued, at: T0) }
    assert_raises(ArgumentError) { log.retry(live, at: T0) }
  end

  def test_waiting_records_a_reason_only_when_it_changes
    id = log.enqueue(key: "a", item: nil, flow: "pr-review", trigger: "guard", at: T0)
    log.waiting(id, reason: "Review chat for o/r#1 is open", at: T0 + 300)
    log.waiting(id, reason: "Review chat for o/r#1 is open", at: T0 + 600)
    log.waiting(id, reason: "held: 5h at 84%", at: T0 + 900)

    assert_equal 2, lines.count { |l| l["event"] == "waiting" }
    assert_equal "held: 5h at 84%", log.queue.first.waiting
  end

  def test_last_guard_error_is_cleared_by_a_later_successful_guard_run
    log.guard_error(error: "exit 1: gh: not logged in", at: T0)
    assert_equal "exit 1: gh: not logged in", log.last_guard_error["error"]

    log.guard_ran(items: 2, at: T0 + 300)
    assert_nil log.last_guard_error

    log.guard_error(error: "item lacks url", item: { "key" => "x" }, at: T0 + 301)
    assert_equal({ "key" => "x" }, log.last_guard_error["item"])
  end

  def test_last_cron_check_is_the_latest_checked_event
    log.checked(at: T0)
    log.checked(at: T0 + 300)

    assert_equal T0 + 300, log.last_cron_check
  end

  def test_unknown_events_fields_and_broken_lines_are_tolerated
    id = log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)
    File.open(path, "a") do |f|
      f.puts("not json")
      f.puts("[1, 2]")
      f.puts(JSON.generate("v" => 2, "at" => "2026-11-06T09:01:00Z", "event" => "teleported", "run_id" => id))
      f.puts(JSON.generate("v" => 1, "at" => "2026-11-06T09:02:00Z", "event" => "started", "run_id" => id,
                           "session_id" => "s", "colour" => "blue"))
      f.puts(JSON.generate("v" => 1, "at" => "2026-11-06T09:03:00Z", "event" => "finished", "run_id" => "ghost"))
    end

    assert_equal [id], log.live.map(&:id)
    assert_equal "s", log.run(id).session_id
    assert_nil log.run("ghost")
  end

  def test_logs_are_per_automation
    log.enqueue(key: "a", item: nil, flow: "chat", trigger: "guard", at: T0)

    assert_empty Quartermaster::RunLog.new("other").queue
    assert_raises(ArgumentError) { Quartermaster::RunLog.new("../etc") }
  end
end
