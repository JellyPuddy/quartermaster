//! The GUI's request guards against a real `qm gui`, expected answers written out (no Ruby oracle): a foreign
//! Host or Origin is refused, an Origin-less POST is taken only for the local tools' actions, and the file drop
//! and the terminal WebSocket need this start's token.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};

const SOCKET: &str = "qm-test-gui-guards";

/// The actions a tool on this machine may send without an Origin.
const LOCAL_ACTIONS: [&str; 8] = ["caffeinate", "pane-start", "pane-resume", "rotate", "issue-start", "loose-start", "automation-chat", "page-annotations"];

struct Gui {
    child: Child,
    port: u16,
    dir: tempfile::TempDir,
}

impl Drop for Gui {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = Command::new("tmux").args(["-L", SOCKET, "kill-server"]).stderr(Stdio::null()).output();
    }
}

fn start() -> Gui {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    fs::create_dir_all(&bin).unwrap();
    for tool in ["gh", "claude"] {
        use std::os::unix::fs::PermissionsExt;
        fs::write(bin.join(tool), "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(bin.join(tool), fs::Permissions::from_mode(0o755)).unwrap();
    }
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let mut child = Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("PATH", path)
        .env("QM_ROOT", dir.path().join("root"))
        .env("HOME", dir.path())
        .env("QM_GUI_PORT", "0")
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_TMUX_SOCKET", SOCKET)
        .env_remove("QM_ITEM")
        .env_remove("TMUX")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    let port = line.split("127.0.0.1:").nth(1).and_then(|r| r.split_whitespace().next()).and_then(|p| p.parse().ok()).unwrap();
    Gui { child, port, dir }
}

/// Status line and body of one request; `headers` replace the defaults (own Host, no Origin).
fn send(port: u16, method: &str, path: &str, headers: &[(&str, String)], body: &str) -> (String, String) {
    let mut all: Vec<(String, String)> = vec![("Host".into(), format!("127.0.0.1:{port}"))];
    for (k, v) in headers {
        all.retain(|(a, _)| !a.eq_ignore_ascii_case(k));
        all.push((k.to_string(), v.clone()));
    }
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let head: String = all.iter().filter(|(_, v)| !v.is_empty()).map(|(k, v)| format!("{k}: {v}\r\n")).collect();
    write!(s, "{method} {path} HTTP/1.1\r\n{head}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    let mut reply = String::new();
    s.read_to_string(&mut reply).unwrap();
    let status = reply.lines().next().unwrap_or("").trim_start_matches("HTTP/1.1 ").to_string();
    (status, reply.split("\r\n\r\n").nth(1).unwrap_or("").to_string())
}

fn own_origin(port: u16) -> (&'static str, String) {
    ("Origin", format!("http://127.0.0.1:{port}"))
}

fn action(cmd: &str) -> String {
    format!("{{\"cmd\":\"{cmd}\",\"slug\":\"x\",\"args\":{{\"mode\":\"status\"}}}}")
}

fn token(gui: &Gui) -> String {
    let (_, body) = send(gui.port, "GET", "/api/state", &[], "");
    let marker = "\"terminalToken\":\"";
    body.split(marker).nth(1).and_then(|r| r.split('"').next()).unwrap().to_string()
}

#[test]
fn a_request_for_another_host_is_refused() {
    let gui = start();
    assert_eq!(send(gui.port, "GET", "/", &[("Host", "evil.example.com".into())], "").0, "403 Forbidden");
    assert_eq!(send(gui.port, "GET", "/", &[("Host", String::new())], "").0, "403 Forbidden");
    assert_eq!(send(gui.port, "GET", "/api/pulse", &[("Host", format!("localhost:{}", gui.port))], "").0, "200 OK");
}

#[test]
fn an_action_posted_from_another_origin_is_refused_even_a_local_one() {
    let gui = start();
    for cmd in ["nope", "state", "note", "caffeinate", "rotate", "page-annotations"] {
        let (status, _) = send(gui.port, "POST", "/api/action", &[("Origin", "https://evil.example.com".into())], &action(cmd));
        assert_eq!(status, "403 Forbidden", "{cmd}");
    }
    let (status, _) = send(gui.port, "POST", "/api/action", &[("Origin", "http://evil.example.com".into())], &action("nope"));
    assert_eq!(status, "403 Forbidden");
    let (status, _) = send(gui.port, "POST", "/api/action", &[own_origin(gui.port)], &action("nope"));
    assert_eq!(status, "200 OK");
}

#[test]
fn without_an_origin_only_the_local_tools_actions_are_taken() {
    let gui = start();
    for cmd in ["set-state", "cleanup", "distill"] {
        assert_eq!(send(gui.port, "POST", "/api/action", &[], &action(cmd)).0, "403 Forbidden", "{cmd}");
    }
    for route in ["/api/drop", "/api/ask", "/api/grep"] {
        assert_eq!(send(gui.port, "POST", route, &[], "{\"query\":\"q\"}").0, "403 Forbidden", "{route}");
    }
    assert_eq!(send(gui.port, "POST", "/api/action", &[], "not json").0, "403 Forbidden");
    for cmd in LOCAL_ACTIONS {
        assert_eq!(send(gui.port, "POST", "/api/action", &[], &action(cmd)).0, "200 OK", "{cmd}");
    }
}

#[test]
fn no_other_action_the_server_knows_is_taken_without_an_origin() {
    let gui = start();
    let source = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/gui_actions.rs")).unwrap();
    let list = source.split("const KNOWN: &[&str] = &[").nth(1).and_then(|r| r.split("];").next()).unwrap();
    let known: Vec<&str> = list.split('"').skip(1).step_by(2).collect();
    assert!(known.len() > 60 && LOCAL_ACTIONS.iter().all(|c| known.contains(c)), "{known:?}");
    for cmd in known.iter().filter(|c| !LOCAL_ACTIONS.contains(c)) {
        assert_eq!(send(gui.port, "POST", "/api/action", &[], &action(cmd)).0, "403 Forbidden", "{cmd} must need an Origin");
    }
}

#[test]
fn the_file_drop_needs_this_starts_token() {
    let gui = start();
    let drops = gui.dir.path().join("root/drops");
    let own = [own_origin(gui.port)];
    for query in ["", "?token=", "?token=wrong&name=a.txt"] {
        let (status, body) = send(gui.port, "POST", &format!("/api/drop{query}"), &own, "hello");
        assert_eq!((status.as_str(), body.as_str()), ("200 OK", "{\"ok\":false,\"error\":\"bad terminal token\"}"), "{query}");
    }
    assert!(!drops.exists(), "a refused drop saves nothing");
    let good = token(&gui);
    assert!(good.len() >= 16, "{good}");
    let (status, _) = send(gui.port, "POST", &format!("/api/drop?token={good}&name=a.txt"), &[], "hello");
    assert_eq!(status, "403 Forbidden", "the token does not replace the Origin");
    let (_, body) = send(gui.port, "POST", &format!("/api/drop?token={good}&name=a.txt"), &own, "hello");
    assert!(body.starts_with("{\"ok\":true,\"path\":"), "{body}");
    assert_eq!(fs::read_dir(&drops).unwrap().count(), 1);
}

fn upgrade(gui: &Gui, query: &str, headers: &[(&str, String)]) -> String {
    let mut all = vec![("Upgrade", "websocket".to_string()), ("Connection", "Upgrade".to_string()), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==".to_string()), ("Sec-WebSocket-Version", "13".to_string())];
    all.extend(headers.iter().cloned());
    let (status, body) = send(gui.port, "GET", &format!("/ws/terminal?{query}"), &all, "");
    format!("{status}: {body}")
}

#[test]
fn the_terminal_websocket_needs_our_origin_and_this_starts_token() {
    let gui = start();
    let own = own_origin(gui.port);
    let good = token(&gui);
    let chat = "session=chat&cols=80&rows=24";
    assert_eq!(upgrade(&gui, &format!("{chat}&token={good}"), &[]), "403 Forbidden: bad origin", "no Origin");
    assert_eq!(upgrade(&gui, &format!("{chat}&token={good}"), &[("Origin", "http://evil.example.com".into())]), "403 Forbidden: bad origin");
    assert_eq!(upgrade(&gui, chat, std::slice::from_ref(&own)), "403 Forbidden: bad token", "no token");
    assert_eq!(upgrade(&gui, &format!("{chat}&token="), std::slice::from_ref(&own)), "403 Forbidden: bad token");
    assert_eq!(upgrade(&gui, &format!("{chat}&token={}x", good), std::slice::from_ref(&own)), "403 Forbidden: bad token");
    assert_eq!(upgrade(&gui, &format!("{chat}&token=wrong"), std::slice::from_ref(&own)), "403 Forbidden: bad token");
    assert_eq!(upgrade(&gui, &format!("{chat}&token={good}"), &[own.clone(), ("Host", "evil.example.com".into())]), "403 Forbidden: bad host");
    assert_eq!(upgrade(&gui, &format!("{chat}&token={good}"), std::slice::from_ref(&own)), "403 Forbidden: no such chat", "a right token still needs a live chat");
}
