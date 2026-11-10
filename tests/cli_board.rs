//! `board-rows`, `board-answer` and `pf-mode`, pinned as transcripts generated from the Ruby implementation.

mod common;
use common::*;

#[test]
fn board_rows_answer_and_pf_mode() {
    let qm = Qm::new();
    qm.ok(&["new", "Board item", "--project", "demo"]);
    qm.ok(&["new", "Plain item", "--project", "elsewhere"]);
    let root = qm.root.path().to_path_buf();
    std::fs::write(root.join("config.yml"), "projects:\n  demo:\n    root: /tmp\n    dev_server:\n      command: devsrv\n      modes: [dev, tunnel]\n      default_mode: dev\n").unwrap();
    const url: &str = "https://claude.ai/artifact/abc";
    let line = |v: serde_json::Value| format!("{v}\n");
    let set = |id: &str, data: serde_json::Value| line(serde_json::json!({"tool_name": "ArtifactData", "tool_input": {"action": "set", "url": url, "collection": "tasks", "doc_id": id, "data": data}, "tool_response": "ok"}));
    let mut writes = String::new();
    writes += &set("short", serde_json::json!({"status": "RUNNING", "title": "A title", "batch": "2026-01-01-a", "order": 1}));
    writes += &set("a-longer-row-id", serde_json::json!({"status": "BLOCKED", "title": "Waiting", "note": "needs an answer", "batch": "2026-01-01-a", "order": 2}));
    writes += &set("noted", serde_json::json!({"status": "blocked", "title": "Éclair", "note": "", "batch": "2026-02-01-b"}));
    std::fs::write(root.join("board-writes.jsonl"), writes).unwrap();
    let answers = std::path::PathBuf::from("/tmp/qm-cli-board-answers");
    let _ = std::fs::remove_dir_all(&answers);
    let steps: Vec<Step> = vec![
        (&["board-rows"], ""),
        (&["board-rows", "board-item"], ""),
        (&["board", "board-item", url, "--answers-dir", "/tmp/qm-cli-board-answers"], ""),
        (&["board-rows", "board-item"], ""),
        (&["board-rows", "board-item", "--json"], ""),
        (&["board-rows", "--json", "board-item"], ""),
        (&["board-rows", "plain-item"], ""),
        (&["board-rows", "nowhere"], ""),
        (&["board-answer"], ""),
        (&["board-answer", "board-item"], ""),
        (&["board-answer", "board-item", "short", "no"], ""),
        (&["board-answer", "board-item", "a-longer-row-id", "Go", "ahead"], ""),
        (&["board-answer", "board-item", "noted", "-"], "from stdin\n"),
        (&["board-answer", "board-item", "noted"], "  \n"),
        (&["board-answer", "board-item", "missing", "x"], ""),
        (&["board-answer", "board-item", "../bad", "x"], ""),
        (&["board-answer", "plain-item", "short", "x"], ""),
        (&["board-answer", "nowhere", "short", "x"], ""),
        (&["pf-mode"], ""),
        (&["pf-mode", "board-item"], ""),
        (&["pf-mode", "board-item", "tunnel"], ""),
        (&["pf-mode", "board-item"], ""),
        (&["pf-mode", "board-item", "bogus"], ""),
        (&["pf-mode", "plain-item"], ""),
        (&["pf-mode", "plain-item", "dev"], ""),
        (&["pf-mode", "nowhere"], ""),
    ];
    let text = transcript(&qm, "board-item", &steps);
    let mut files = String::new();
    for f in ["a-longer-row-id.md", "noted.md"] {
        files += &format!("{f}: {:?}\n", std::fs::read_to_string(answers.join(f)).ok());
    }
    golden("cli_board.txt", &format!("{text}{files}"));
}

#[test]
fn bundled_delegate_build_skill_writes_and_renders_every_row_field() {
    let skill = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/delegate-build");
    let skill_md = std::fs::read_to_string(skill.join("SKILL.md")).unwrap();
    let seeding = regex::Regex::new(r"(?m)^3\. \*\*Seed.*$").unwrap().find(&skill_md).map(|m| m.as_str().to_string());
    let board = std::fs::read_to_string(skill.join("helpers/status-board.html")).unwrap();
    let seeding = seeding.expect("SKILL.md has its seeding step");
    for field in quartermaster::board_mirror::ROW_FIELDS {
        let word = regex::Regex::new(&format!(r"\b{field}\b")).unwrap();
        assert!(word.is_match(&seeding), "the seeding step writes {field}");
        assert!(word.is_match(&board), "status-board.html reads {field}");
    }
}
