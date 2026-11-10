//! The event fold counts each session's prompts, which tells a run's own first prompt from the user typing
//! into it.

use quartermaster::event_log;
use serde_json::json;

#[test]
fn the_fold_counts_user_prompts_per_session() {
    let root = tempfile::tempdir().unwrap();
    std::env::set_var("QM_ROOT", root.path());
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let lines: Vec<String> = [("UserPromptSubmit", "a"), ("Stop", "a"), ("UserPromptSubmit", "a"), ("UserPromptSubmit", "b"), ("PostToolUse", "b")]
        .iter()
        .map(|(event, session)| json!({"v": 1, "ts": ts, "event": event, "session_id": session}).to_string())
        .collect();
    std::fs::write(root.path().join("events.jsonl"), lines.join("\n") + "\n").unwrap();
    let turns = event_log::turns();
    assert_eq!(turns["a"]["prompts"], 2);
    assert_eq!(turns["b"]["prompts"], 1);
    assert_eq!(turns["a"]["state"], "working");
}
