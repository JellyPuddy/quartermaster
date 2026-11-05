//! The Rust binary's hook edits against files the Ruby qm wrote and reads.

use std::path::Path;
use std::process::{Command, Stdio};

use std::io::Write;

fn run(bin: &Path, root: &Path, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> (i32, String, String) {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .env("QM_ROOT", root)
        .env("LANG", "C.UTF-8")
        .env("LC_ALL", "C.UTF-8")
        .env_remove("QM_SKIP")
        .env_remove("QM_ASIDE")
        .env_remove("QM_LOOSE")
        .env_remove("QM_ITEM")
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap();
    let _ = child.stdin.take().unwrap().write_all(stdin.as_bytes()); // a hook that exits unread closes the pipe
    let o = child.wait_with_output().unwrap();
    (o.status.code().unwrap_or(-1), String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

fn rust() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_qm"))
}

fn ruby() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster")
}

fn start(id: &str) -> String {
    format!(r#"{{"session_id":"{id}","cwd":"/tmp","source":"startup","transcript_path":"/nonexistent/x"}}"#)
}

/// An item with keys only newer qm versions understand, which a hook edit must not disturb.
fn item_with_extra_keys(root: &Path) -> String {
    run(&ruby(), root, &["new", "Keeper"], "", &[]);
    let path = root.join("work-items/keeper.md");
    let text = std::fs::read_to_string(&path).unwrap();
    let extended = text.replacen(
        "created:",
        "rotations:\n- at: '2026-01-01T00:00:00+00:00'\n  from: s0\n  carried: [1, 2]\nsnoozed_until: '2026-12-01'\nweird_key: \"quoted: value\"\ncreated:",
        1,
    );
    std::fs::write(&path, &extended).unwrap();
    extended
}

#[test]
fn a_rust_attach_changes_only_the_sessions_key_and_ruby_reads_it_back() {
    let root = tempfile::tempdir().unwrap();
    let before = item_with_extra_keys(root.path());
    let (code, _, _) = run(rust(), root.path(), &["hook-session-start"], &start("s1"), &[("QM_ITEM", "keeper")]);
    assert_eq!(code, 0);
    let after = std::fs::read_to_string(root.path().join("work-items/keeper.md")).unwrap();
    assert_eq!(after, before.replacen("\n---\n", "\nsessions:\n- id: s1\n---\n", 1));
    let (code, shown, _) = run(&ruby(), root.path(), &["show", "keeper"], "", &[]);
    assert_eq!(code, 0);
    assert!(shown.contains("s1"), "{shown}");
}

#[test]
fn a_rust_detach_leaves_every_other_key_and_the_body_untouched() {
    let root = tempfile::tempdir().unwrap();
    let before = item_with_extra_keys(root.path());
    run(rust(), root.path(), &["hook-session-start"], &start("s1"), &[("QM_ITEM", "keeper")]);
    run(rust(), root.path(), &["hook-session-start"], &start("s2"), &[("QM_ITEM", "keeper")]);
    run(rust(), root.path(), &["hook-session-end"], r#"{"session_id":"s1","cwd":"/tmp","reason":"exit"}"#, &[]);
    let after = std::fs::read_to_string(root.path().join("work-items/keeper.md")).unwrap();
    assert!(after.contains("sessions:\n- id: s2\n") && !after.contains("s1"), "{after}");
    for kept in ["rotations:\n- at: '2026-01-01T00:00:00+00:00'\n  from: s0\n  carried: [1, 2]\n", "snoozed_until: '2026-12-01'\n", "weird_key: \"quoted: value\"\n"] {
        assert!(after.contains(kept), "lost {kept:?}");
    }
    assert_eq!(after.split("\n---\n").nth(1), before.split("\n---\n").nth(1), "body changed");
}

#[test]
fn ruby_and_rust_agree_on_the_session_log_each_wrote() {
    let root = tempfile::tempdir().unwrap();
    run(&ruby(), root.path(), &["hook-session-start"], &start("from-ruby"), &[]);
    run(rust(), root.path(), &["hook-session-start"], &start("from-rust"), &[]);
    let (_, ruby_view, _) = run(&ruby(), root.path(), &["sessions"], "", &[]);
    let (_, rust_view, _) = run(rust(), root.path(), &["sessions"], "", &[]);
    assert_eq!(ruby_view, rust_view);
    assert_eq!(rust_view.lines().count(), 2);
}

#[test]
fn a_rust_hook_refuses_to_corrupt_a_flow_style_session_list() {
    let root = tempfile::tempdir().unwrap();
    run(&ruby(), root.path(), &["new", "Flow"], "", &[]);
    let path = root.path().join("work-items/flow.md");
    let text = std::fs::read_to_string(&path).unwrap().replacen("created:", "sessions: [{id: a}]\ncreated:", 1);
    std::fs::write(&path, &text).unwrap();
    let (code, out, _) = run(rust(), root.path(), &["hook-session-start"], &start("s9"), &[("QM_ITEM", "flow")]);
    assert_eq!((code, out.as_str()), (0, ""));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
    let log = std::fs::read_to_string(root.path().join("qm.log")).unwrap();
    assert!(log.contains("[hook-session-start]") && log.contains("not a block list"), "{log}");
}
