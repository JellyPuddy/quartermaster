//! The run log of a local automation: the append-only file, its fold, and the writers that decide from the
//! fold under one flock.

use chrono::{DateTime, Duration, TimeZone, Utc};
use quartermaster::run_log::RunLog;
use serde_json::{json, Value};
use std::path::PathBuf;

fn t0() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 6, 9, 0, 0).unwrap()
}

fn secs(n: i64) -> DateTime<Utc> {
    t0() + Duration::seconds(n)
}

struct World {
    dir: tempfile::TempDir,
}

impl World {
    fn new() -> World {
        World { dir: tempfile::tempdir().unwrap() }
    }

    fn log(&self) -> RunLog {
        RunLog::new("digest", self.dir.path()).unwrap()
    }

    fn path(&self) -> PathBuf {
        self.dir.path().join("digest.runs.jsonl")
    }

    fn lines(&self) -> Vec<Value> {
        std::fs::read_to_string(self.path()).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }
}

fn queue(log: &RunLog, key: &str, at: i64) -> String {
    log.enqueue(key, &Value::Null, "chat", "guard", secs(at)).unwrap()
}

fn start(log: &RunLog, id: &str, session: &str, at: i64) {
    log.started(id, session, "t", "digest", secs(at)).unwrap();
}

fn ids(runs: Vec<quartermaster::run_log::Run>) -> Vec<String> {
    runs.into_iter().map(|r| r.id).collect()
}

#[test]
fn an_absent_log_folds_to_nothing() {
    let w = World::new();
    let log = w.log();
    assert!(log.queue().is_empty() && log.live().is_empty() && log.recent(20).is_empty() && log.seen_keys().is_empty());
    assert!(log.last_guard_error().is_none() && log.last_cron_check().is_none() && !log.fold().cron_queued());
}

#[test]
fn every_line_carries_v_at_and_event_and_writes_only_append() {
    let w = World::new();
    let log = w.log();
    let id = log.enqueue("a", &json!({"key": "a"}), "chat", "guard", t0()).unwrap();
    log.started(&id, "s-1", &format!("digest--run-{id}"), "digest", secs(60)).unwrap();
    let lines = w.lines();
    assert_eq!(lines[0], json!({"v": 1, "at": "2026-11-06T09:00:00Z", "event": "queued", "run_id": id, "key": "a", "item": {"key": "a"}, "flow": "chat", "trigger": "guard"}));
    let keys: Vec<&String> = lines[1].as_object().unwrap().keys().collect();
    assert_eq!(keys, ["v", "at", "event", "run_id", "session_id", "tmux", "item_slug"]);
    assert!(id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) && id.len() == 8);
}

#[test]
fn the_queue_holds_queued_runs_not_yet_started_oldest_first() {
    let w = World::new();
    let log = w.log();
    let (a, b, c) = (queue(&log, "a", 0), queue(&log, "b", 1), queue(&log, "c", 2));
    start(&log, &b, "s-b", 3);
    assert_eq!(ids(log.queue()), [a, c]);
    assert_eq!(ids(log.live()), [b]);
}

#[test]
fn runs_queued_in_the_same_second_keep_their_log_order() {
    let w = World::new();
    let log = w.log();
    let all: Vec<String> = ["a", "b", "c", "d"].iter().map(|k| queue(&log, k, 0)).collect();
    assert_eq!(ids(log.queue()), all);
}

#[test]
fn a_run_ends_live_on_finished_timed_out_closed_or_failed() {
    let w = World::new();
    let log = w.log();
    let mut ended = std::collections::HashMap::new();
    for ending in ["finished", "timed_out", "closed", "failed"] {
        let id = queue(&log, ending, 0);
        start(&log, &id, &format!("s-{ending}"), 1);
        ended.insert(ending, id);
    }
    let still = queue(&log, "still", 0);
    start(&log, &still, "s-still", 1);
    log.finished(&ended["finished"], secs(2)).unwrap();
    log.timed_out(&ended["timed_out"], secs(2)).unwrap();
    log.closed(&ended["closed"], secs(2)).unwrap();
    log.failed(&ended["failed"], "tmux said no", secs(2)).unwrap();
    assert_eq!(ids(log.live()), [still]);
    let mut statuses: Vec<(String, String)> = log.recent(20).into_iter().map(|r| (r.key.unwrap(), r.status)).collect();
    statuses.sort();
    let expected: Vec<(String, String)> = ["closed", "failed", "finished", "timed_out"].iter().map(|s| (s.to_string(), s.to_string())).chain([("still".to_string(), "live".to_string())]).collect();
    let mut expected = expected;
    expected.sort();
    assert_eq!(statuses, expected);
    assert_eq!(log.run(&ended["failed"]).unwrap().error.as_deref(), Some("tmux said no"));
}

#[test]
fn a_finished_run_closed_later_reads_closed() {
    let w = World::new();
    let log = w.log();
    let id = queue(&log, "a", 0);
    start(&log, &id, "s", 1);
    log.finished(&id, secs(2)).unwrap();
    log.closed(&id, secs(3)).unwrap();
    let run = log.run(&id).unwrap();
    assert_eq!((run.status.as_str(), run.finished_at, run.ended_at), ("closed", Some(secs(2)), Some(secs(3))));
}

#[test]
fn a_run_that_fails_before_it_starts_leaves_the_queue() {
    let w = World::new();
    let log = w.log();
    let id = log.enqueue("a", &Value::Null, "pr-review", "guard", t0()).unwrap();
    log.failed(&id, "no such PR", secs(1)).unwrap();
    assert!(log.queue().is_empty());
    assert_eq!(log.run(&id).unwrap().status, "failed");
}

#[test]
fn recent_lists_runs_that_left_the_queue_newest_first() {
    let w = World::new();
    let log = w.log();
    let (a, b) = (queue(&log, "a", 0), queue(&log, "b", 0));
    queue(&log, "c", 0);
    start(&log, &a, "s-a", 10);
    start(&log, &b, "s-b", 20);
    assert_eq!(ids(log.recent(20)), [b.clone(), a]);
    assert_eq!(ids(log.recent(1)), [b]);
}

#[test]
fn a_guard_item_whose_key_was_seen_is_not_queued_again() {
    let w = World::new();
    let log = w.log();
    let item = json!({"key": "pr-1"});
    assert!(log.enqueue_item("pr-1", &item, "chat", "guard", t0()).unwrap().is_some());
    assert!(log.enqueue_item("pr-1", &item, "chat", "guard", secs(300)).unwrap().is_none());
    assert_eq!(log.queue().len(), 1);
    assert_eq!(log.seen_keys().into_iter().collect::<Vec<_>>(), ["pr-1"]);
}

#[test]
fn dedupe_and_coalescing_see_what_another_writer_appended() {
    let w = World::new();
    let mine = w.log();
    mine.queue();
    let theirs = w.log();
    theirs.enqueue_item("pr-1", &Value::Null, "chat", "guard", t0()).unwrap();
    theirs.enqueue_cron(t0(), "chat", t0()).unwrap();
    let queued = queue(&theirs, "a", 0);
    start(&theirs, &queued, "s", 0);
    theirs.failed(&queued, "x", t0()).unwrap();
    theirs.retry(&queued, t0()).unwrap();
    assert!(mine.enqueue_item("pr-1", &Value::Null, "chat", "guard", secs(1)).unwrap().is_none());
    assert!(mine.enqueue_cron(secs(60), "chat", secs(1)).unwrap().is_none());
    assert_eq!(w.lines().iter().filter(|l| l["event"] == "queued" && l["trigger"] != "retry").count(), 3);
}

#[test]
fn a_key_stays_consumed_after_its_run_failed() {
    let w = World::new();
    let log = w.log();
    let id = log.enqueue_item("pr-1", &Value::Null, "chat", "guard", t0()).unwrap().unwrap();
    start(&log, &id, "s", 1);
    log.timed_out(&id, secs(2)).unwrap();
    assert!(log.enqueue_item("pr-1", &Value::Null, "chat", "guard", secs(300)).unwrap().is_none());
}

#[test]
fn keys_marked_seen_without_queuing_are_skipped_by_later_guard_runs() {
    let w = World::new();
    let log = w.log();
    log.mark_seen(&["pr-1".into(), "pr-2".into()], t0()).unwrap();
    assert!(log.queue().is_empty());
    assert!(log.enqueue_item("pr-2", &Value::Null, "chat", "guard", secs(1)).unwrap().is_none());
    assert!(log.enqueue_item("pr-3", &Value::Null, "chat", "guard", secs(1)).unwrap().is_some());
    let mut seen: Vec<String> = log.seen_keys().into_iter().collect();
    seen.sort();
    assert_eq!(seen, ["pr-1", "pr-2", "pr-3"]);
}

#[test]
fn cron_runs_coalesce_into_one_queued_run() {
    let w = World::new();
    let log = w.log();
    let first = log.enqueue_cron(Utc.with_ymd_and_hms(2026, 11, 6, 7, 0, 0).unwrap(), "chat", t0()).unwrap().unwrap();
    assert!(log.enqueue_cron(Utc.with_ymd_and_hms(2026, 11, 6, 8, 0, 0).unwrap(), "chat", secs(3600)).unwrap().is_none());
    assert!(log.fold().cron_queued());
    assert_eq!(log.queue().into_iter().map(|r| r.key.unwrap()).collect::<Vec<_>>(), ["cron:2026-11-06T07:00:00Z"]);
    let run = log.run(&first).unwrap();
    assert_eq!((run.trigger.as_deref(), run.item), (Some("cron"), Value::Null));
}

#[test]
fn a_new_cron_run_queues_once_the_previous_one_started() {
    let w = World::new();
    let log = w.log();
    let first = log.enqueue_cron(Utc.with_ymd_and_hms(2026, 11, 6, 7, 0, 0).unwrap(), "chat", t0()).unwrap().unwrap();
    start(&log, &first, "s", 1);
    assert!(!log.fold().cron_queued());
    assert!(log.enqueue_cron(Utc.with_ymd_and_hms(2026, 11, 7, 7, 0, 0).unwrap(), "chat", secs(86_400)).unwrap().is_some());
}

#[test]
fn a_queued_guard_or_manual_run_does_not_hold_back_a_cron_run() {
    let w = World::new();
    let log = w.log();
    log.enqueue("manual:1", &Value::Null, "chat", "manual", t0()).unwrap();
    assert!(!log.fold().cron_queued());
    assert!(log.enqueue_cron(t0(), "chat", t0()).unwrap().is_some());
}

#[test]
fn retry_queues_a_new_run_with_the_same_item_bypassing_dedupe() {
    let w = World::new();
    let log = w.log();
    let item = json!({"key": "pr-1", "url": "https://github.com/o/r/pull/1"});
    let id = log.enqueue_item("pr-1", &item, "pr-review", "guard", t0()).unwrap().unwrap();
    log.started(&id, "s", "t", "review-pr-1", secs(1)).unwrap();
    log.failed(&id, "boom", secs(2)).unwrap();
    let new_id = log.retry(&id, secs(60)).unwrap();
    assert_ne!(new_id, id);
    let retried = log.run(&new_id).unwrap();
    assert_eq!((retried.key.as_deref(), retried.item, retried.flow.as_deref(), retried.trigger.as_deref()), (Some("pr-1"), item, Some("pr-review"), Some("retry")));
    assert_eq!(ids(log.queue()), [new_id.clone()]);
    assert_eq!(log.run(&id).unwrap().retried_as.as_deref(), Some(new_id.as_str()));
    let lines = w.lines();
    let retried_line = &lines[lines.len() - 2];
    assert_eq!((&retried_line["event"], &retried_line["run_id"], &retried_line["new_run_id"]), (&json!("retried"), &json!(id), &json!(new_id)));
}

#[test]
fn retry_refuses_an_unknown_queued_or_live_run() {
    let w = World::new();
    let log = w.log();
    let queued = queue(&log, "a", 0);
    let live = queue(&log, "b", 0);
    start(&log, &live, "s", 1);
    assert!(log.retry("nope", t0()).is_err());
    assert!(log.retry(&queued, t0()).unwrap_err().message.contains("still queued"));
    assert!(log.retry(&live, t0()).is_err());
}

#[test]
fn waiting_records_a_reason_only_when_it_changes() {
    let w = World::new();
    let log = w.log();
    let id = log.enqueue("a", &Value::Null, "pr-review", "guard", t0()).unwrap();
    log.waiting(&id, "Review chat for o/r#1 is open", secs(300)).unwrap();
    log.waiting(&id, "Review chat for o/r#1 is open", secs(600)).unwrap();
    log.waiting(&id, "held: 5h at 84%", secs(900)).unwrap();
    assert_eq!(w.lines().iter().filter(|l| l["event"] == "waiting").count(), 2);
    assert_eq!(log.queue()[0].waiting.as_deref(), Some("held: 5h at 84%"));
}

#[test]
fn last_guard_error_is_cleared_by_a_later_successful_guard_run() {
    let w = World::new();
    let log = w.log();
    log.guard_error("exit 1: gh: not logged in", None, t0()).unwrap();
    assert_eq!(log.last_guard_error().unwrap()["error"], "exit 1: gh: not logged in");
    log.guard_ran(2, secs(300)).unwrap();
    assert!(log.last_guard_error().is_none());
    log.guard_error("item lacks url", Some(&json!({"key": "x"})), secs(301)).unwrap();
    assert_eq!(log.last_guard_error().unwrap()["item"], json!({"key": "x"}));
}

#[test]
fn last_cron_check_is_the_latest_checked_event() {
    let w = World::new();
    let log = w.log();
    log.checked(t0()).unwrap();
    log.checked(secs(300)).unwrap();
    assert_eq!(log.last_cron_check(), Some(secs(300)));
}

#[test]
fn a_refused_guard_item_never_queues_and_is_reported_once() {
    let w = World::new();
    let log = w.log();
    let item = json!({"key": "pr-9", "url": "https://github.com/x/y/pull/9"});
    let id = log.refuse_item("pr-9", &item, "pr-review", "guard", "repo x/y isn't in this automation's repos", t0()).unwrap().unwrap();
    assert!(log.refuse_item("pr-9", &item, "pr-review", "guard", "again", secs(1)).unwrap().is_none());
    assert!(log.enqueue_item("pr-9", &item, "pr-review", "guard", secs(2)).unwrap().is_none());
    assert!(log.queue().is_empty());
    let run = log.run(&id).unwrap();
    assert_eq!((run.status.as_str(), run.error.as_deref()), ("refused", Some("repo x/y isn't in this automation's repos")));
    assert!(log.retry(&id, secs(3)).is_ok(), "a refused run is an ended run");
}

#[test]
fn unknown_events_fields_and_broken_lines_are_tolerated() {
    let w = World::new();
    let log = w.log();
    let id = queue(&log, "a", 0);
    let extra = [
        "not json".to_string(),
        "[1, 2]".to_string(),
        json!({"v": 2, "at": "2026-11-06T09:01:00Z", "event": "teleported", "run_id": id}).to_string(),
        json!({"v": 1, "at": "2026-11-06T09:02:00Z", "event": "started", "run_id": id, "session_id": "s", "colour": "blue"}).to_string(),
        json!({"v": 1, "at": "2026-11-06T09:03:00Z", "event": "finished", "run_id": "ghost"}).to_string(),
    ];
    let mut text = std::fs::read_to_string(w.path()).unwrap();
    text.push_str(&extra.join("\n"));
    text.push('\n');
    std::fs::write(w.path(), text).unwrap();
    assert_eq!(ids(log.live()), [id.clone()]);
    assert_eq!(log.run(&id).unwrap().session_id.as_deref(), Some("s"));
    assert!(log.run("ghost").is_none());
}

#[test]
fn logs_are_per_automation_and_the_slug_is_checked() {
    let w = World::new();
    queue(&w.log(), "a", 0);
    assert!(RunLog::new("other", w.dir.path()).unwrap().queue().is_empty());
    assert!(RunLog::new("../etc", w.dir.path()).is_err());
}

#[test]
fn concurrent_writers_queue_one_run_per_key() {
    let w = World::new();
    let dir = w.dir.path().to_path_buf();
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let dir = dir.clone();
            std::thread::spawn(move || RunLog::new("digest", &dir).unwrap().enqueue_item("pr-1", &Value::Null, "chat", "guard", t0()).unwrap().is_some())
        })
        .collect();
    let queued = handles.into_iter().map(|h| h.join().unwrap()).filter(|q| *q).count();
    assert_eq!(queued, 1);
    assert_eq!(w.log().queue().len(), 1);
}
