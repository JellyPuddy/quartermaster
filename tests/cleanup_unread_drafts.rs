//! An issue draft qm can't read as an issue (a tagged YAML value, say) is an error entry in the plan: it
//! never blocks `qm cleanup`, `qm sweep` or the GUI, and `--yes` carries the plan out in-process.

mod common;
use common::Qm;
use serde_json::Value;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};

const SOCKET: &str = "qm-test-cleanup-unread";
const TAGGED: &str = "---\ntitle: !!str Tagged\nkind: bug\n---\n\nbody\n";
const GOOD: &str = "---\ntitle: Good\nkind: feature\nnumber: 7\n---\n\nbody\n";
const UNREAD: &str = "doesn't parse: frontmatter holds a YAML construct qm doesn't read (a tag, anchor, date, float or number with a leading zero): quote the value";

fn world(state: &str) -> Qm {
    let qm = Qm::new();
    let root = qm.root.path();
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::create_dir_all(root.join("issues/fix-it")).unwrap();
    fs::write(root.join("work-items/fix-it.md"), format!("---\nv: 1\ntitle: fix-it\nstate: {state}\ncreated: '2026-01-01'\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    fs::write(root.join("issues/fix-it/01-tagged.md"), TAGGED).unwrap();
    fs::write(root.join("issues/fix-it/02-good.md"), GOOD).unwrap();
    qm
}

fn plain(s: &str) -> String {
    regex::Regex::new("\x1b\\[[0-9;]*m").unwrap().replace_all(s, "").into_owned()
}

#[test]
fn an_unread_issue_draft_is_a_warned_entry_in_the_item_plan() {
    let qm = world("resolved");
    let out = qm.run(&["cleanup", "fix-it"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let expected = format!(
        "no repo root configured for ''\nfix-it: 2 issue drafts — 1 ready, 1 needs a look\n  [ ] ⚠ issue-draft fix-it/01-tagged.md “01-tagged.md” — {UNREAD}\n  [x] issue-draft fix-it/02-good.md “Good” — #7\n--yes removes the [x] entries; --force PATH|BRANCH|SLUG/FILE adds a ⚠ one\n"
    );
    assert_eq!(plain(&out.stdout), expected);
    assert!(qm.exists("issues/fix-it/01-tagged.md"), "a plan removes nothing");
}

#[test]
fn cleanup_yes_removes_the_ticked_entries_and_the_forced_unread_one_in_process() {
    let qm = world("resolved");
    // a run's stdout is a pipe here; there is no terminal to hand the work to any more
    let out = qm.run(&["cleanup", "fix-it", "--yes"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(plain(&out.stdout).ends_with("removed fix-it/02-good.md: deleted\n"), "{}", out.stdout);
    assert!(qm.exists("issues/fix-it/01-tagged.md"), "the warned entry stays without --force");
    assert!(!qm.exists("issues/fix-it/02-good.md"));
    let out = qm.run(&["cleanup", "fix-it", "--yes", "--force", "issue:fix-it/01-tagged.md"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(plain(&out.stdout).ends_with("removed fix-it/01-tagged.md: deleted\n"), "{}", out.stdout);
    assert!(!qm.exists("issues/fix-it"), "the last file takes the directory");
}

#[test]
fn sweep_lists_and_removes_with_an_unread_draft_present() {
    let qm = world("in_progress");
    let out = qm.run(&["sweep"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let text = plain(&out.stdout);
    assert!(text.starts_with("sweep: 2 issue drafts — 0 ready, 1 needs a look\n"), "{text}");
    assert!(text.contains(&format!("  [ ] ⚠ issue-draft fix-it/01-tagged.md “01-tagged.md” — {UNREAD}; belongs to unresolved item 'fix-it'\n")), "{text}");
    let out = qm.run(&["sweep", "--yes", "--force", "issue:fix-it/01-tagged.md"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(plain(&out.stdout).ends_with("removed fix-it/01-tagged.md: deleted\n"), "{}", out.stdout);
    assert!(!qm.exists("issues/fix-it/01-tagged.md"));
    assert!(qm.exists("issues/fix-it/02-good.md"), "an unresolved item's draft is only listed");
}

#[test]
fn resolving_an_item_with_an_unread_draft_hints_at_the_cleanup() {
    let qm = world("in_progress");
    let out = qm.run(&["state", "fix-it", "resolved"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(plain(&out.stdout).contains("cleanup: 2 issue drafts — 1 ready, 1 needs a look — qm cleanup fix-it"), "{}", out.stdout);
}

struct Server {
    child: Child,
    port: u16,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = Command::new("tmux").args(["-L", SOCKET, "kill-server"]).stderr(Stdio::null()).status();
    }
}

fn gui(qm: &Qm) -> Server {
    let home = qm.root.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let child = Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("QM_ROOT", qm.root.path())
        .env("HOME", &home)
        .env("QM_GUI_PORT", port.to_string())
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_TMUX_SOCKET", SOCKET)
        .env_remove("QM_SKIP")
        .env_remove("TMUX")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let server = Server { child, port };
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return server;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("the GUI did not come up");
}

fn request(port: u16, method: &str, path: &str, body: &str) -> (String, Value) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let req = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    stream.write_all(req.as_bytes()).unwrap();
    let mut raw = vec![];
    stream.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let status = head.lines().next().unwrap().trim_start_matches("HTTP/1.1 ").to_string();
    (status, serde_json::from_slice(&raw[split + 4..]).unwrap_or(Value::Null))
}

#[test]
fn the_gui_answers_the_plan_and_the_issue_summary_with_an_unread_draft_present() {
    let qm = world("resolved");
    let server = gui(&qm);
    let (status, plan) = request(server.port, "POST", "/api/cleanup-plan", r#"{"scope":"fix-it"}"#);
    assert_eq!(status, "200 OK");
    assert_eq!(plan["ok"], true);
    let entries = plan["plan"]["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["id"], "issue:fix-it/01-tagged.md");
    assert_eq!(entries[0]["ticked"], false);
    assert_eq!(entries[1]["id"], "issue:fix-it/02-good.md");
    assert_eq!(entries[1]["ticked"], true);
    let (status, plan) = request(server.port, "POST", "/api/cleanup-plan", r#"{"scope":"sweep"}"#);
    assert_eq!(status, "200 OK");
    assert_eq!(plan["ok"], true);
    let (status, state) = request(server.port, "GET", "/api/state", "");
    assert_eq!(status, "200 OK");
    let item = state["items"].as_array().unwrap().iter().find(|i| i["slug"] == "fix-it").expect("the item").clone();
    assert_eq!(item["issues"]["count"], 2);
    assert_eq!(item["issues"]["open"], 0); // the good one is #7, already created
    assert_eq!(item["issues"]["errors"], 1);
}
