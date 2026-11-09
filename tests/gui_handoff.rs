//! The CLI hands an action to the running GUI only when that GUI serves the CLI's own data root: `GET
//! /api/root` answers a digest of its realpath'd root, never the path. A stand-in server plays the GUI; the
//! real GUI is checked for what it answers.

mod common;
use common::*;
use quartermaster::sha256;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

fn root_id(path: &std::path::Path) -> String {
    sha256::hex(std::fs::canonicalize(path).unwrap().to_string_lossy().as_bytes())
}

/// Answers `GET /api/root` with `root_reply` (status `code`) and every POST with an ok; records the POST bodies.
fn stand_in_gui(code: u16, root_reply: String) -> (u16, Arc<Mutex<Vec<Value>>>) {
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
            let (status, reply) = if text.starts_with("GET /api/root") {
                (code, root_reply.clone())
            } else {
                seen.lock().unwrap().push(serde_json::from_str(text.split("\r\n\r\n").nth(1).unwrap_or("")).unwrap());
                (200, json!({"ok": true, "caffeinate": {"mode": "off"}}).to_string())
            };
            let _ = write!(s, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len());
        }
    });
    (port, posts)
}

fn run(qm: &Qm, port: u16, args: &[&str]) -> Out {
    qm.run_with(args, "", &[("QM_GUI_PORT", &port.to_string()), ("HOME", &qm.root.path().to_string_lossy())])
}

#[test]
fn a_gui_on_this_root_gets_the_action() {
    let qm = Qm::new();
    let (port, posts) = stand_in_gui(200, json!({"root": root_id(qm.root.path())}).to_string());
    let out = run(&qm, port, &["caffeinate", "off"]);
    assert_eq!((out.code, out.stdout.as_str()), (0, "caffeinate off\n"), "{}", out.stderr);
    assert_eq!(*posts.lock().unwrap(), vec![json!({"cmd": "caffeinate", "args": {"mode": "off"}})]);
}

#[test]
fn a_gui_on_another_root_is_no_gui_and_gets_nothing() {
    let qm = Qm::new();
    let (port, posts) = stand_in_gui(200, json!({"root": sha256::hex(b"/Users/someone/.claude/quartermaster")}).to_string());
    let out = run(&qm, port, &["caffeinate", "on"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("is not a qm gui on this data root") && out.stderr.contains("nothing done"), "{}", out.stderr);
    assert!(posts.lock().unwrap().is_empty());
}

#[test]
fn a_server_that_names_no_root_is_no_gui_and_an_optional_handoff_falls_back() {
    let qm = Qm::new();
    let repo = qm.root.path().join("widget");
    common::repo(&repo, "main");
    std::fs::write(qm.root.path().join("config.yml"), format!("projects:\n  Widget: {}\n", std::fs::canonicalize(&repo).unwrap().display())).unwrap();
    let (port, posts) = stand_in_gui(404, "not found".into());
    let out = run(&qm, port, &["loose", "--project", "Widget", "Why is CI red?"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.stdout.contains("no qm gui running — start the loose chat with:"), "{}", out.stdout);
    assert!(posts.lock().unwrap().is_empty());
}

#[test]
fn a_reply_without_a_root_field_is_no_gui() {
    let qm = Qm::new();
    let (port, posts) = stand_in_gui(200, json!({"ok": true}).to_string());
    let out = run(&qm, port, &["caffeinate", "status"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("is not a qm gui on this data root"), "{}", out.stderr);
    assert!(posts.lock().unwrap().is_empty());
}

#[test]
fn the_real_gui_answers_its_root_id_on_get_without_an_origin() {
    let base = tempfile::tempdir().unwrap();
    let (root, home) = (base.path().join("root"), base.path().join("home"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut child = Command::new(common::bin())
        .arg("gui")
        .env("QM_ROOT", &root)
        .env("HOME", &home)
        .env("QM_GUI_PORT", port.to_string())
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_TMUX_SOCKET", "qm-test-handoff")
        .env_remove("QM_SKIP")
        .env_remove("TMUX")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut up = None;
    for _ in 0..100 {
        if let Ok(s) = TcpStream::connect(("127.0.0.1", port)) {
            up = Some(s);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let mut stream = up.expect("the GUI came up");
    stream.write_all(format!("GET /api/root HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").as_bytes()).unwrap();
    let mut raw = String::new();
    stream.read_to_string(&mut raw).unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert!(raw.starts_with("HTTP/1.1 200 OK"), "{raw}");
    let body: Value = serde_json::from_str(raw.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(body, json!({"root": root_id(&root)}));
    assert!(!raw.contains(&root.to_string_lossy().to_string()), "never the path");
}

#[test]
fn a_root_reached_through_a_symlink_is_the_same_root() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir(&real).unwrap();
    std::os::unix::fs::symlink(&real, dir.path().join("link")).unwrap();
    assert_eq!(root_id(&real).len(), 64);
    assert_ne!(root_id(&real), root_id(dir.path()));
    let (port, posts) = stand_in_gui(200, json!({"root": root_id(&real)}).to_string());
    let out = run(&Qm::at(&dir.path().join("link")), port, &["caffeinate", "off"]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(posts.lock().unwrap().len(), 1);
}
