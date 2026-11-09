//! `qm statusline`: the Claude Code status line, its second line for the linked work item, its
//! rate-limits snapshot, and what a qm chat drops.

mod common;
use common::*;
use std::fs;

struct World {
    qm: Qm,
    cwd: tempfile::TempDir,
    now: i64,
}

fn world() -> World {
    // a Rust-only command: always the Rust binary
    std::env::set_var("QM_BIN", env!("CARGO_BIN_EXE_qm"));
    let qm = Qm::new();
    qm.ok(&["list"]);
    fs::create_dir_all(qm.root.path().join("work-items")).unwrap();
    fs::write(qm.root.path().join("work-items/stub.md"), "---\nv: 1\ntitle: Stub item title\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\nsessions:\n- id: s-1\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n").unwrap();
    World { qm, cwd: tempfile::tempdir().unwrap(), now: chrono::Utc::now().timestamp() }
}

impl World {
    fn input(&self, limits: bool) -> String {
        let mut data = serde_json::json!({"session_id": "s-1", "workspace": {"current_dir": self.cwd.path()}, "model": {"display_name": "Opus"}, "context_window": {"used_percentage": 31.4}});
        if limits {
            data["rate_limits"] = serde_json::json!({"five_hour": {"used_percentage": 42.2, "resets_at": self.now + 8100}, "seven_day": {"used_percentage": 61.0, "resets_at": self.now + 273_600}});
        }
        data.to_string()
    }

    fn line(&self, stdin: &str, env: &[(&str, &str)]) -> String {
        let mut all = vec![("COLUMNS", "160"), ("TERM", "dumb")];
        all.extend_from_slice(env);
        let o = self.qm.run_with(&["statusline"], stdin, &all);
        assert_eq!(o.code, 0, "{}", o.stderr);
        strip_ansi(&o.stdout)
    }

    fn snapshot(&self) -> std::path::PathBuf {
        self.qm.root.path().join("rate-limits.json")
    }
}

fn matches(pattern: &str, text: &str) -> bool {
    regex::Regex::new(pattern).unwrap().is_match(text)
}

#[test]
fn outside_qm_it_shows_limits_and_the_item_line() {
    let w = world();
    let out = w.line(&w.input(true), &[]);
    assert!(matches(r"ctx \[.*\] 31%", &out), "{out}");
    assert!(matches(r"5h \[.*\] 42% \(2h1[45]m\)", &out), "{out}");
    assert!(matches(r"wk \[.*\] 61% \(3d[34]h\)", &out), "{out}");
    assert!(out.ends_with("\n◆ Stub item title"), "{out}");
    assert!(out.starts_with("➜ ") && out.contains("[Opus]"), "{out}");
}

#[test]
fn a_qm_chat_drops_the_limits_and_the_item_line_but_keeps_context() {
    let w = world();
    let out = w.line(&w.input(true), &[("TMUX", "/private/tmp/tmux-501/qm,4242,3")]);
    assert!(matches(r"ctx \[.*\] 31%", &out), "{out}");
    assert!(!matches(r"\b(5h|wk) \[", &out) && !out.contains('◆') && !out.contains('\n'), "{out}");
}

#[test]
fn a_test_gui_socket_counts_as_qm_and_another_server_does_not() {
    let w = world();
    let out = w.line(&w.input(true), &[("TMUX", "/private/tmp/tmux-501/qm-test-7,1,0"), ("QM_TMUX_SOCKET", "qm-test-7")]);
    assert!(!matches(r"\b5h \[", &out) && !out.contains('◆'), "{out}");
    let out = w.line(&w.input(true), &[("TMUX", "/private/tmp/tmux-501/default,99,0")]);
    assert!(matches(r"\b5h \[", &out) && out.contains("◆ Stub item title"), "{out}");
}

#[test]
fn the_snapshot_is_written_atomically_into_the_qm_root() {
    let w = world();
    w.line(&w.input(true), &[("TMUX", "/private/tmp/tmux-501/qm,4242,3")]);
    let doc: serde_json::Value = serde_json::from_str(&fs::read_to_string(w.snapshot()).unwrap()).unwrap();
    assert_eq!(doc["v"], 1);
    assert_eq!(doc["five_hour"], serde_json::json!({"used_percentage": 42.2, "resets_at": w.now + 8100}));
    assert_eq!(doc["seven_day"], serde_json::json!({"used_percentage": 61.0, "resets_at": w.now + 273_600}));
    let at = chrono::DateTime::parse_from_rfc3339(doc["captured_at"].as_str().unwrap()).unwrap().timestamp();
    assert!((at - chrono::Utc::now().timestamp()).abs() < 30);
    assert!(!fs::read_dir(w.qm.root.path()).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
}

#[test]
fn no_rate_limits_leaves_the_last_snapshot_alone() {
    let w = world();
    fs::write(w.snapshot(), "previous").unwrap();
    let out = w.line(&w.input(false), &[]);
    assert_eq!(fs::read_to_string(w.snapshot()).unwrap(), "previous");
    assert!(!matches(r"\b5h \[", &out), "{out}");
}

#[test]
fn it_never_creates_the_qm_root_and_an_unwritable_snapshot_never_breaks_the_line() {
    let w = world();
    let missing = w.cwd.path().join("no-such-root");
    let out = w.line(&w.input(true), &[("QM_ROOT", missing.to_str().unwrap())]);
    assert!(!missing.exists());
    assert!(matches(r"5h \[.*\] 42%", &out), "{out}");
    let w = world();
    fs::create_dir_all(w.snapshot()).unwrap(); // a directory where the file goes: the rename fails
    let out = w.line(&w.input(true), &[]);
    assert!(matches(r"5h \[.*\] 42%", &out), "{out}");
    assert!(w.snapshot().is_dir());
}

#[test]
fn git_branch_dirty_mark_bars_and_padding() {
    let w = world();
    git(w.cwd.path(), &["init", "-q", "-b", "trunk"]);
    fs::write(w.cwd.path().join("f"), "x").unwrap();
    git(w.cwd.path(), &["add", "."]);
    git(w.cwd.path(), &["commit", "-q", "-m", "one"]);
    let clean = w.line(&w.input(true), &[]);
    assert!(clean.contains("git:(trunk)") && !clean.contains('✗'), "{clean}");
    fs::write(w.cwd.path().join("g"), "y").unwrap();
    let dirty = w.line(&w.input(true), &[]);
    assert!(dirty.contains("git:(trunk) ✗"), "{dirty}");
    let first = dirty.lines().next().unwrap();
    assert_eq!(first.chars().count(), 160 - 5, "{first}");
    // 31% of 8 cells, 42% and 61%
    assert!(dirty.contains("ctx [███░░░░░]") || dirty.contains("ctx [██░░░░░░]"), "{dirty}");
    assert!(dirty.contains("5h [███░░░░░]") && dirty.contains("wk [█████░░░]"), "{dirty}");
    let hot = w.line(&serde_json::json!({"workspace": {"current_dir": w.cwd.path()}, "context_window": {"used_percentage": 95}}).to_string(), &[]);
    assert!(hot.contains("ctx [████████] 95%") && !hot.contains("[Opus]"), "{hot}");
}

#[test]
fn a_document_that_is_not_json_leaves_the_line_empty() {
    let w = world();
    let o = w.qm.run_with(&["statusline"], "not json", &[]);
    assert_eq!((o.code, o.stdout.as_str()), (0, ""));
}
