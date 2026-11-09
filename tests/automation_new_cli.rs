//! `qm automation new` and `edit`: the item and its empty files, then the chat through the running GUI's
//! `automation-chat` action (a stand-in GUI here) or, without a GUI, the line that starts it in a terminal.

mod common;
use common::*;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Mutex};

fn gui(root: &std::path::Path, reply: Value) -> (u16, Arc<Mutex<Vec<Value>>>) {
    let id = quartermaster::sha256::hex(std::fs::canonicalize(root).unwrap().to_string_lossy().as_bytes());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let posts = Arc::new(Mutex::new(vec![]));
    let seen = posts.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let mut raw = vec![];
            let mut buf = [0u8; 4096];
            loop {
                let n = s.read(&mut buf).unwrap_or(0);
                raw.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&raw).to_string();
                if let Some(at) = text.find("\r\n\r\n") {
                    let want: usize = text[..at].to_lowercase().lines().find_map(|l| l.strip_prefix("content-length:").and_then(|v| v.trim().parse().ok())).unwrap_or(0);
                    if raw.len() >= at + 4 + want || n == 0 {
                        break;
                    }
                } else if n == 0 {
                    break;
                }
            }
            let text = String::from_utf8_lossy(&raw).to_string();
            let body = if text.starts_with("GET /api/root") {
                json!({"root": id}).to_string()
            } else {
                seen.lock().unwrap().push(serde_json::from_str(text.split("\r\n\r\n").nth(1).unwrap_or("")).unwrap());
                reply.to_string()
            };
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    (port, posts)
}

struct World {
    qm: Qm,
    tools: std::path::PathBuf,
}

impl World {
    fn new() -> World {
        let qm = Qm::new();
        let tools = qm.root.path().join("tools");
        std::fs::create_dir_all(&tools).unwrap();
        for tool in ["osascript", "open"] {
            std::fs::write(tools.join(tool), format!("#!/bin/sh\necho \"{tool} $*\" >> \"$(dirname \"$0\")/tools.log\"\n")).unwrap();
            std::fs::set_permissions(tools.join(tool), std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        World { qm, tools }
    }

    fn run(&self, port: u16, args: &[&str]) -> Out {
        let path = format!("{}:{}", self.tools.display(), std::env::var("PATH").unwrap());
        self.qm.run_with(args, "", &[("PATH", &path), ("QM_GUI_PORT", &port.to_string()), ("HOME", &self.qm.root.path().to_string_lossy()), ("QM_CHAT_COMMAND", "claude")])
    }

    fn dead_port(&self) -> u16 {
        TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
    }
}

#[test]
fn new_without_a_gui_makes_the_item_and_files_and_prints_how_to_start_the_chat() {
    let w = World::new();
    let out = w.run(w.dead_port(), &["automation", "new", "Weekly digest", "--project", "MyApp", "--description", "Post it"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("weekly-digest: created (MyApp), files in "), "{}", out.stdout);
    assert!(out.stdout.contains("no qm gui running — start its chat with:\n  cd ") && out.stdout.contains("&& QM_ITEM=weekly-digest claude "), "{}", out.stdout);
    let item = w.qm.read("work-items/weekly-digest.md");
    assert!(item.contains("kind: automation") && item.contains("runner: cloud") && item.contains("state: in_progress") && item.contains("Post it"), "{item}");
    assert!(!item.contains("routine:"));
    assert_eq!(w.qm.read("automations/weekly-digest.prompt.md"), "");
    let yml = w.qm.read("automations/weekly-digest.yml");
    assert!(yml.contains("runner: cloud") && yml.contains("name: Weekly digest") && yml.contains("enabled: true"), "{yml}");
}

#[test]
fn a_local_one_is_created_disabled_and_a_bad_runner_or_a_taken_slug_is_refused() {
    let w = World::new();
    let out = w.run(w.dead_port(), &["automation", "new", "Nightly", "--project", "MyApp", "--runner", "local"]);
    assert!(out.stdout.contains("nightly: created (MyApp, runs locally), files in "), "{}", out.stdout);
    assert!(w.qm.read("automations/nightly.yml").contains("enabled: false"));
    let bad = w.run(w.dead_port(), &["automation", "new", "Other", "--project", "MyApp", "--runner", "docker"]);
    assert!(bad.code == 1 && bad.stderr.contains("qm automation new: runner is cloud or local, got docker"), "{}", bad.stderr);
    let taken = w.run(w.dead_port(), &["automation", "new", "Nightly", "--project", "MyApp"]);
    assert!(taken.code == 1 && taken.stderr.contains("qm automation new: automation files for 'nightly' already exist"), "{}", taken.stderr);
    let usage = w.run(w.dead_port(), &["automation", "new", "No project"]);
    assert!(usage.code == 1 && usage.stderr.contains("usage: qm automation"), "{}", usage.stderr);
}

#[test]
fn with_a_gui_the_action_is_posted_and_the_gui_page_is_brought_up() {
    let w = World::new();
    let (port, posts) = gui(w.qm.root.path(), json!({"ok": true, "mode": "fresh"}));
    let out = w.run(port, &["automation", "new", "Weekly digest", "--project", "MyApp"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("weekly-digest: its chat started in the qm gui"), "{}", out.stdout);
    assert_eq!(*posts.lock().unwrap(), vec![json!({"cmd": "automation-chat", "slug": "weekly-digest", "args": {}})]);
    let tools = std::fs::read_to_string(w.tools.join("tools.log")).unwrap_or_default();
    assert!(tools.contains("chat=weekly-digest"), "{tools}");
    let (port, _) = gui(w.qm.root.path(), json!({"ok": true, "mode": "resume"}));
    assert!(w.run(port, &["automation", "edit", "weekly-digest"]).stdout.contains("its chat resumed in the qm gui"));
}

#[test]
fn a_chat_that_already_runs_gets_nothing_typed_and_the_brief_is_printed() {
    let w = World::new();
    w.run(w.dead_port(), &["automation", "new", "Weekly digest", "--project", "MyApp"]);
    let (port, _) = gui(w.qm.root.path(), json!({"ok": true, "attached": true, "brief": "THE BRIEF"}));
    let out = w.run(port, &["automation", "edit", "weekly-digest"]);
    assert!(out.stdout.contains("its chat is already running in the qm gui — nothing typed; paste this brief there if it needs it:\nTHE BRIEF"), "{}", out.stdout);
}

#[test]
fn edit_of_something_that_is_not_an_automation_says_so() {
    let w = World::new();
    w.qm.ok(&["new", "Plain item", "--project", "MyApp"]);
    let out = w.run(w.dead_port(), &["automation", "edit", "plain-item"]);
    assert!(out.code == 1 && out.stderr.contains("qm automation edit: plain-item is not an automation"), "{}", out.stderr);
}
