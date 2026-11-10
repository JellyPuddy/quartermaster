//! One line that is not UTF-8 costs the log that line, not the whole log: `sessions.jsonl` (live-session
//! checks of cleanup read it) and the run folds.

use quartermaster::session_log::SessionLog;
use std::io::Write;

#[test]
fn a_non_utf8_line_in_sessions_jsonl_loses_only_itself() {
    let root = tempfile::tempdir().unwrap();
    std::env::set_var("QM_ROOT", root.path());
    let line = |id: &str| format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"ts\":\"2026-01-01T00:00:00Z\"}}\n");
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(root.path().join("sessions.jsonl")).unwrap();
    f.write_all(line("before").as_bytes()).unwrap();
    f.write_all(b"{\"v\":1,\"event\":\"start\",\"session_id\":\"\xff\xfe\"}\n").unwrap();
    f.write_all(line("after").as_bytes()).unwrap();
    drop(f);
    let ids: Vec<_> = SessionLog::read().sessions().into_iter().map(|s| s.id).collect();
    assert_eq!(ids, ["before", "after"]);
}
