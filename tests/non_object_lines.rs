//! A JSONL line that parses but is not an object (`5`, `[]`, `"x"`, `null`: a hand edit, a stray write) is
//! skipped like a garbled one by every reader that parses per line, and never takes the reader down.

mod common;
use common::*;
use serde_json::json;
use std::path::Path;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const NON_OBJECTS: &str = "5\n[]\n\"x\"\nnull\n";

fn append(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    std::io::Write::write_all(&mut file, text.as_bytes()).unwrap();
}

fn stamp(secs_ago: i64) -> String {
    (chrono::Utc::now() - chrono::Duration::seconds(secs_ago)).to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn at(qm: &Qm) -> std::sync::MutexGuard<'static, ()> {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("QM_ROOT", qm.root.path());
    guard
}

#[test]
fn the_event_fold_skips_them_and_moves_its_offset_past() {
    let qm = Qm::new();
    let _guard = at(&qm);
    let events = qm.root.path().join("events.jsonl");
    let event = |secs: i64, name: &str| format!("{}\n", json!({"v": 1, "ts": stamp(secs), "event": name, "session_id": "s"}));
    append(&events, &event(30, "UserPromptSubmit"));
    append(&events, NON_OBJECTS);
    append(&events, &event(10, "Stop"));

    let turns = quartermaster::event_log::turns();
    assert_eq!(turns["s"]["state"], "your_turn");
    let fold: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(qm.root.path().join("events-fold.json")).unwrap()).unwrap();
    assert_eq!(fold["offset"], std::fs::metadata(&events).unwrap().len());
}

#[test]
fn the_session_log_skips_them() {
    let qm = Qm::new();
    let _guard = at(&qm);
    let log = qm.root.path().join("sessions.jsonl");
    append(&log, "{\"v\":1,\"event\":\"start\",\"session_id\":\"s1\",\"cwd\":\"/\",\"ts\":\"2026-01-01T00:00:00Z\"}\n");
    append(&log, NON_OBJECTS);
    append(&log, "{\"v\":1,\"event\":\"end\",\"session_id\":\"s1\",\"ts\":\"2026-01-01T01:00:00Z\"}\n");

    let sessions = quartermaster::session_log::SessionLog::read();
    assert_eq!(sessions.sessions().iter().map(|s| s.id.clone()).collect::<Vec<_>>(), vec!["s1"]);
}

#[test]
fn the_feature_use_report_skips_them() {
    let qm = Qm::new();
    let _guard = at(&qm);
    quartermaster::feature_use::record("cli", "list");
    append(&qm.root.path().join("feature-use.jsonl"), NON_OBJECTS);
    quartermaster::feature_use::record("cli", "list");

    let report = quartermaster::feature_use::report(&[]).unwrap().unwrap();
    assert!(regex::Regex::new(r"(?m)^\s+2  list ").unwrap().is_match(&report), "{report}");
}

#[test]
fn a_benchmark_runs_event_log_skips_them() {
    let dir = tempfile::tempdir().unwrap();
    append(&dir.path().join("events.jsonl"), &format!("{NON_OBJECTS}{{\"t\":\"plan\"}}\n"));
    assert_eq!(quartermaster::benchmark_pipeline::events(dir.path()), vec![json!({"t": "plan"})]);
}

fn launch(secs: i64, id: &str) -> String {
    format!(
        "{}\n",
        json!({"type": "user", "timestamp": stamp(secs), "toolUseResult": {"isAsync": true, "status": "async_launched", "agentId": id, "description": id},
               "message": {"role": "user", "content": [{"type": "tool_result", "content": "launched"}]}})
    )
}

#[test]
fn background_jobs_skip_them_even_when_they_carry_a_marker() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("t.jsonl");
    append(&path, &launch(100, "a1"));
    append(&path, "[\"async_launched\"]\n\"<task-notification>\"\n");
    append(&path, &launch(50, "a2"));
    let now = chrono::Utc::now().timestamp() as f64;

    let jobs = quartermaster::background_jobs::pending(Some(&path), now);
    assert_eq!(jobs.iter().map(|j| j.id.as_str().unwrap_or("")).collect::<Vec<_>>(), vec!["a1", "a2"]);
}

#[test]
fn transcript_readers_skip_them() {
    let qm = Qm::new();
    let _guard = at(&qm);
    let path = qm.root.path().join("transcript.jsonl");
    append(&path, &format!("{}\n", json!({"type": "user", "timestamp": stamp(60), "message": {"content": "first ask"}})));
    append(&path, NON_OBJECTS);
    let usage = json!({"input_tokens": 1234, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0});
    append(&path, &format!("{}\n", json!({"type": "assistant", "timestamp": stamp(30), "message": {"model": "claude-opus-5-5", "usage": usage}})));

    assert_eq!(quartermaster::transcripts::first_prompt(Some(&path)).as_deref(), Some("first ask"));
    assert_eq!(quartermaster::transcript_vitals::read(Some(&path)).unwrap().context_tokens, Some(1234));

    let log = qm.root.path().join("sessions.jsonl");
    append(&log, &format!("{}\n", json!({"v": 1, "event": "start", "session_id": "s", "cwd": "/", "transcript_path": path, "ts": stamp(90)})));
    let detail = quartermaster::session_detail::session_detail("s").unwrap();
    assert_eq!(detail["turns"].as_array().unwrap().iter().map(|t| t["prompt"].clone()).collect::<Vec<_>>(), vec![json!("first ask")]);
}
