//! Many threads fold `events.jsonl` at once, as the GUI's connection threads, the turn notifier and the run
//! lifecycle do: none may collide on the fold's temp file and light the error badge.

use std::io::Write;

#[test]
fn concurrent_folds_leave_no_error_and_a_whole_fold() {
    let root = tempfile::tempdir().unwrap();
    std::env::set_var("QM_ROOT", root.path());
    let log = root.path().join("events.jsonl");
    std::fs::write(&log, "").unwrap();
    let threads: Vec<_> = (0..8)
        .map(|t| {
            let log = log.clone();
            std::thread::spawn(move || {
                for i in 0..150 {
                    let mut f = std::fs::OpenOptions::new().append(true).open(&log).unwrap();
                    let line = format!("{{\"session_id\":\"s{t}\",\"event\":\"UserPromptSubmit\",\"ts\":\"2999-01-01T00:00:{:02}Z\"}}\n", i % 60);
                    f.write_all(line.as_bytes()).unwrap();
                    drop(f);
                    quartermaster::event_log::turns();
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    let errors = std::fs::read_to_string(root.path().join("qm.log")).unwrap_or_default();
    assert!(!errors.contains("event-fold"), "fold write failed: {errors}");
    let fold: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(root.path().join("events-fold.json")).unwrap()).unwrap();
    assert!(fold["sessions"].is_object());
    assert_eq!(quartermaster::event_log::turns().len(), 8);
}
