//! `qm delete` and the GUI's `delete` action: the guard, the force, the chats it kills through a tmux
//! stand-in on PATH, and the logs it leaves alone.

mod common;
use common::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

/// A tmux stand-in that logs its argv and succeeds only for the sessions named in `$LIVE`.
fn fake_tmux(qm: &Qm) -> PathBuf {
    let bin = qm.root.path().join("fakebin");
    std::fs::create_dir_all(&bin).unwrap();
    let script = "#!/bin/sh\necho \"$*\" >> \"$QM_FAKE_LOG\"\nfor last; do :; done\ncase \" $QM_FAKE_LIVE \" in *\" ${last#=} \"*) exit 0;; esac\nexit 1\n";
    let path = bin.join("tmux");
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    bin
}

fn log(qm: &Qm) -> String {
    std::fs::read_to_string(qm.root.path().join("tmux.log")).unwrap_or_default()
}

fn env_for(qm: &Qm, live: &str) -> Vec<(String, String)> {
    let path = format!("{}:{}", fake_tmux(qm).display(), std::env::var("PATH").unwrap());
    vec![
        ("PATH".into(), path),
        ("HOME".into(), qm.root.path().to_string_lossy().into_owned()),
        ("QM_FAKE_LOG".into(), qm.root.path().join("tmux.log").to_string_lossy().into_owned()),
        ("QM_FAKE_LIVE".into(), live.into()),
        ("QM_TMUX_SOCKET".into(), "qm-test-deletion".into()),
    ]
}

fn delete(qm: &Qm, live: &str, args: &[&str]) -> Out {
    let env = env_for(qm, live);
    let pairs: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let mut argv = vec!["delete"];
    argv.extend_from_slice(args);
    qm.run_with(&argv, "", &pairs)
}

fn item_path(qm: &Qm, slug: &str) -> PathBuf {
    qm.root.path().join("work-items").join(format!("{slug}.md"))
}

/// An item holding a bit of everything the guard looks at.
fn busy_item(qm: &Qm) {
    qm.ok(&["new", "Busy", "--project", "MyApp", "--branch", "issue/1-a", "--session", "s1", "--description", "Real work"]);
    qm.ok(&["attach", "busy", "--session", "s2"]);
    qm.ok(&["link-branch", "busy", "issue/1-b"]);
    for note in ["first", "second", "third"] {
        qm.ok(&["note", "busy", note]);
    }
    qm.ok(&["board", "busy", "https://claude.ai/artifact/abc"]);
}

#[test]
fn deletes_an_item_qm_new_left_empty() {
    let qm = Qm::new();
    qm.ok(&["new", "Oops", "--project", "MyApp", "--session", "s1"]);
    let out = delete(&qm, "", &["oops"]);
    assert_eq!((out.code, out.stdout.as_str(), out.stderr.as_str()), (0, "deleted oops\n", ""));
    assert!(!item_path(&qm, "oops").exists());
}

#[test]
fn refuses_an_item_holding_work_and_names_what_it_holds() {
    let qm = Qm::new();
    busy_item(&qm);
    let out = delete(&qm, "", &["busy"]);
    assert_eq!((out.code, out.stdout.as_str()), (1, ""));
    assert!(out.stderr.contains("'busy' holds 3 notes, 2 branches, 2 sessions, board set, a description"), "{}", out.stderr);
    assert!(out.stderr.contains("--force") && out.stderr.contains("qm cleanup busy"), "{}", out.stderr);
    assert!(item_path(&qm, "busy").exists());
    assert_eq!(log(&qm), "", "a refusal kills no chat");
}

#[test]
fn each_kind_of_content_alone_refuses() {
    let qm = Qm::new();
    let adders: [(&str, Vec<&str>); 5] = [
        ("a note", vec!["note", "item", "x"]),
        ("a branch", vec!["link-branch", "item", "b"]),
        ("a second session", vec!["attach", "item", "--session", "s2"]),
        ("a board", vec!["board", "item", "https://b.test"]),
        ("a description", vec!["describe", "item", "Something real"]),
    ];
    for (what, add) in adders {
        qm.ok(&["new", "Item", "--project", "MyApp", "--session", "s1"]);
        qm.ok(&add);
        let out = delete(&qm, "", &["item"]);
        assert_eq!(out.code, 1, "{what} should refuse: {}", out.stderr);
        std::fs::remove_file(item_path(&qm, "item")).unwrap();
    }
}

#[test]
fn force_deletes_an_item_holding_work() {
    let qm = Qm::new();
    busy_item(&qm);
    let out = delete(&qm, "", &["busy", "--force"]);
    assert_eq!((out.code, out.stdout.as_str()), (0, "deleted busy\n"), "{}", out.stderr);
    assert!(!item_path(&qm, "busy").exists());
    let out = delete(&qm, "", &["--force", "busy"]);
    assert_eq!(out.code, 1);
}

#[test]
fn kills_the_items_chat_and_aside_through_tmux() {
    let qm = Qm::new();
    qm.ok(&["new", "Chatty", "--project", "MyApp"]);
    delete(&qm, "chatty", &["chatty"]);
    assert_eq!(log(&qm), "-L qm-test-deletion kill-session -t =chatty\n-L qm-test-deletion kill-session -t =chatty--aside\n");
}

#[test]
fn leaves_the_append_only_logs_alone() {
    let qm = Qm::new();
    qm.ok(&["new", "Logged", "--project", "MyApp", "--session", "s1"]);
    let mut before = vec![];
    for name in ["sessions.jsonl", "events.jsonl", "board-writes.jsonl"] {
        let file = qm.root.path().join(name);
        std::fs::write(&file, "{\"v\":1,\"slug\":\"logged\"}\n").unwrap();
        before.push((file.clone(), std::fs::read_to_string(&file).unwrap()));
    }
    delete(&qm, "", &["logged"]);
    for (file, text) in before {
        assert_eq!(std::fs::read_to_string(&file).unwrap(), text, "{}", file.display());
    }
}

#[test]
fn an_unknown_or_unusable_slug_errors_cleanly() {
    let qm = Qm::new();
    for (args, message) in [(vec!["nope"], "qm: no work item 'nope'"), (vec!["../config"], "not a work item slug"), (vec![], "usage: qm delete SLUG [--force]"), (vec!["a", "b"], "usage: qm delete SLUG [--force]")] {
        let out = delete(&qm, "", &args);
        assert_eq!(out.code, 1, "{args:?}");
        assert!(out.stderr.contains(message), "{args:?}: {}", out.stderr);
    }
    assert_eq!(log(&qm), "");
}

fn post(cmd: &str, slug: &str, args: Value) -> Value {
    quartermaster::gui_actions::dispatch(&json!({"cmd": cmd, "slug": slug, "args": args})).expect("delete is ported")
}

/// The GUI action runs in this process, so the environment is this test's alone while it holds `ENV`.
fn in_process(qm: &Qm, live: &str) {
    for (k, v) in env_for(qm, live) {
        std::env::set_var(k, v);
    }
    std::env::set_var("QM_ROOT", qm.root.path());
}

#[test]
fn gui_delete_refuses_with_what_it_holds_then_deletes_when_forced() {
    let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    busy_item(&qm);
    in_process(&qm, "busy");

    let refused = post("delete", "busy", Value::Null);
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["needs_force"], true);
    assert_eq!(refused["held"], json!(["3 notes", "2 branches", "2 sessions", "board set", "a description"]));
    assert!(item_path(&qm, "busy").exists());

    let forced = post("delete", "busy", json!({"force": true}));
    assert_eq!(forced, json!({"ok": true, "deleted": "busy", "killed": ["busy"]}));
    assert!(!item_path(&qm, "busy").exists());
}

#[test]
fn gui_delete_of_an_empty_item_needs_no_force() {
    let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    qm.ok(&["new", "Oops", "--project", "MyApp"]);
    in_process(&qm, "");
    assert_eq!(post("delete", "oops", Value::Null)["ok"], true);
    assert!(!Path::new(&item_path(&qm, "oops")).exists());
}

#[test]
fn the_detail_sheet_offers_delete_with_an_in_page_confirmation() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("gui/js");
    let detail = std::fs::read_to_string(root.join("detail.js")).unwrap();
    let modals = std::fs::read_to_string(root.join("modals.js")).unwrap();
    assert!(detail.contains("deleteItemModal(it)"));
    let at = modals.find("function deleteItemModal").unwrap();
    let body = &modals[at..at + modals[at..].find("\n}\n").unwrap()];
    assert!(body.contains("act(\"delete\""));
    assert!(!body.contains("confirm("), "an in-page dialog, not window.confirm");
}
