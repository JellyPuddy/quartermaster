//! How `SessionLog` groups sessions.jsonl into sessions, with the expected values written out, and a guard
//! that a log of hundreds of sessions is not rescanned per session. No Ruby oracle.

use quartermaster::gui_state;
use quartermaster::session_log::SessionLog;
use std::fs;
use std::sync::Mutex;
use std::time::Instant;

static ENV: Mutex<()> = Mutex::new(());

fn root_with(lines: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var("QM_ROOT", dir.path());
    std::env::set_var("QM_TMUX_SOCKET", "qm-test-session-log");
    fs::create_dir_all(dir.path().join("work-items")).unwrap();
    fs::write(dir.path().join("sessions.jsonl"), lines).unwrap();
    dir
}

fn start(id: &str, ts: &str, cwd: &str) -> String {
    format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"cwd\":\"{cwd}\",\"ts\":\"{ts}\"}}\n")
}
fn end(id: &str, ts: &str) -> String {
    format!("{{\"v\":1,\"event\":\"end\",\"session_id\":\"{id}\",\"reason\":\"other\",\"ts\":\"{ts}\"}}\n")
}
fn dismissed(id: &str, ts: &str) -> String {
    format!("{{\"v\":1,\"event\":\"dismissed\",\"session_id\":\"{id}\",\"ts\":\"{ts}\"}}\n")
}

fn summary(log: &SessionLog) -> Vec<(String, String, String, bool)> {
    log.sessions().iter().map(|s| (s.id.clone(), s.started_ts(), s.last_ts(), s.ended())).collect()
}

fn row(id: &str, started: &str, last: &str, ended: bool) -> (String, String, String, bool) {
    (id.into(), started.into(), last.into(), ended)
}

#[test]
fn sessions_come_in_first_seen_order_with_interleaved_events_grouped() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let lines = [
        start("b", "2026-01-01T00:00:01Z", "/b"),
        start("a", "2026-01-01T00:00:02Z", "/a"),
        end("b", "2026-01-01T00:00:03Z"),
        start("c", "2026-01-01T00:00:04Z", "/c"),
        end("a", "2026-01-01T00:00:05Z"),
    ]
    .concat();
    let _dir = root_with(&lines);
    let log = SessionLog::read();
    assert_eq!(
        summary(&log),
        vec![
            row("b", "2026-01-01T00:00:01Z", "2026-01-01T00:00:03Z", true),
            row("a", "2026-01-01T00:00:02Z", "2026-01-01T00:00:05Z", true),
            row("c", "2026-01-01T00:00:04Z", "2026-01-01T00:00:04Z", false),
        ]
    );
    assert_eq!(log.session_for("a").unwrap().cwd().as_deref(), Some("/a"));
    assert!(log.session_for("zzz").is_none());
}

#[test]
fn a_repeated_start_uses_the_newest_start_and_the_newest_event_that_is_not_a_dismissal() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let lines = [
        start("a", "2026-01-01T00:00:01Z", "/old"),
        start("b", "2026-01-01T00:00:02Z", "/b"),
        end("a", "2026-01-01T00:00:03Z"),
        start("a", "2026-01-01T00:00:04Z", "/new"),
        dismissed("a", "2026-01-01T00:00:09Z"),
    ]
    .concat();
    let _dir = root_with(&lines);
    let log = SessionLog::read();
    assert_eq!(summary(&log), vec![row("a", "2026-01-01T00:00:04Z", "2026-01-01T00:00:04Z", false), row("b", "2026-01-01T00:00:02Z", "2026-01-01T00:00:02Z", false)]);
    assert_eq!(log.session_for("a").unwrap().cwd().as_deref(), Some("/new"));
    assert_eq!(log.last_activity_ts().as_deref(), Some("2026-01-01T00:00:04Z"));
}

#[test]
fn events_without_a_session_id_bad_lines_and_sessions_never_started_are_skipped() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let lines = [
        "{\"v\":1,\"event\":\"start\",\"cwd\":\"/x\",\"ts\":\"2026-01-01T00:00:00Z\"}\n".to_string(),
        "not json at all\n".to_string(),
        "[1,2]\n".to_string(),
        "{\"v\":1,\"event\":\"start\",\"session_id\":7,\"ts\":\"2026-01-01T00:00:00Z\"}\n".to_string(),
        end("only-end", "2026-01-01T00:00:01Z"),
        dismissed("only-dismissed", "2026-01-01T00:00:02Z"),
        start("ok", "2026-01-01T00:00:03Z", "/ok"),
        "\n".to_string(),
        "{\"v\":1,\"session_id\":\"ok\",\"ts\":\"2026-01-01T00:00:04Z\"}\n".to_string(),
    ]
    .concat();
    let _dir = root_with(&lines);
    let log = SessionLog::read();
    // the event-less line after the start still counts as the session's latest activity
    assert_eq!(summary(&log), vec![row("ok", "2026-01-01T00:00:03Z", "2026-01-01T00:00:04Z", false)]);
    assert!(log.session_for("only-end").is_none());
    assert!(log.session_for("only-dismissed").is_none());
}

#[test]
fn a_log_read_again_after_an_append_sees_the_new_event() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _dir = root_with(&start("a", "2026-01-01T00:00:01Z", "/a"));
    let before = SessionLog::read();
    assert_eq!(before.sessions().len(), 1);
    SessionLog::append(serde_json::from_str(&format!("{{\"event\":\"start\",\"session_id\":\"b\",\"ts\":\"2026-01-01T00:00:02Z\"}}")).unwrap()).unwrap();
    assert_eq!(before.sessions().len(), 1, "a value read earlier keeps what it read");
    let after = SessionLog::read();
    assert_eq!(after.sessions().iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
}

fn big_log(sessions: usize) -> String {
    let mut lines = String::new();
    for i in 0..sessions {
        let id = format!("s{i:05}");
        lines.push_str(&start(&id, "2026-01-01T00:00:00Z", "/p"));
        lines.push_str(&end(&id, "2026-01-01T00:00:01Z"));
    }
    lines
}

#[test]
fn lookups_in_a_large_log_do_not_rescan_the_events() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let n = 6000;
    let _dir = root_with(&big_log(n));
    let began = Instant::now();
    let log = SessionLog::read();
    assert_eq!(log.sessions().len(), n);
    for i in (0..n).step_by(3) {
        assert!(log.session_for(&format!("s{i:05}")).is_some());
    }
    assert!(began.elapsed().as_secs() < 5, "grouping and {} lookups took {:?}", n / 3, began.elapsed());
}

#[test]
fn the_state_of_a_few_hundred_sessions_builds_in_seconds_not_tens_of_seconds() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let dir = root_with(&big_log(600));
    for j in 0..40 {
        let ids: String = (0..8).map(|k| format!("- id: s{:05}\n", j * 8 + k)).collect();
        fs::write(dir.path().join(format!("work-items/item-{j:02}.md")), format!("---\nv: 1\ntitle: Item {j}\nstate: in_progress\ncreated: '2026-01-01'\nsessions:\n{ids}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    }
    let began = Instant::now();
    let state = gui_state::build("tok");
    assert_eq!(state["items"].as_array().unwrap().len(), 40);
    assert!(began.elapsed().as_secs() < 3, "the state build took {:?}", began.elapsed());
}
