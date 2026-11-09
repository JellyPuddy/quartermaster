//! A terminal WebSocket that sends nothing (the user is watching a long turn) must outlive the request
//! timeout: the tmux attach client stays until the socket closes.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const SOCKET: &str = "qm-test-gui-idle";

fn tmux(args: &[&str]) -> String {
    let out = Command::new("tmux").args(["-L", SOCKET]).args(args).stderr(Stdio::null()).output().unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

struct Gui(Child);

impl Drop for Gui {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
        tmux(&["kill-server"]);
    }
}

fn get(port: u16, path: &str) -> String {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(s, "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").unwrap();
    let mut reply = String::new();
    s.read_to_string(&mut reply).unwrap();
    reply
}

#[test]
fn an_idle_terminal_websocket_survives_the_request_timeout() {
    let dir = tempfile::tempdir().unwrap();
    tmux(&["kill-server"]);
    for _ in 0..50 {
        tmux(&["new-session", "-d", "-s", "chat", "-x", "80", "-y", "24", "sh -c 'exec cat'"]);
        if tmux(&["list-sessions", "-F", "#{session_name}"]).contains("chat") {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let child = Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("QM_ROOT", dir.path())
        .env("HOME", dir.path())
        .env("QM_GUI_PORT", "0")
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_GUI_REQUEST_TIMEOUT_MS", "400")
        .env("QM_TMUX_SOCKET", SOCKET)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut gui = Gui(child);
    let mut line = String::new();
    BufReader::new(gui.0.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    let port: u16 = line.split("127.0.0.1:").nth(1).and_then(|r| r.split_whitespace().next()).and_then(|p| p.parse().ok()).unwrap();
    let state = get(port, "/api/state");
    let token = state.split("\"terminalToken\":\"").nth(1).and_then(|r| r.split('"').next()).unwrap().to_string();

    let mut ws = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(ws, "GET /ws/terminal?token={token}&session=chat&cols=80&rows=24 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").unwrap();
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    ws.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    while !head.ends_with(b"\r\n\r\n") {
        assert_eq!(ws.read(&mut byte).unwrap(), 1);
        head.push(byte[0]);
    }
    assert!(String::from_utf8_lossy(&head).starts_with("HTTP/1.1 101"));
    let attached = || tmux(&["list-clients", "-F", "#{client_session}"]).contains("chat");
    let mut waited = 0;
    while !attached() && waited < 50 {
        std::thread::sleep(Duration::from_millis(100));
        waited += 1;
    }
    assert!(attached(), "the bridge never attached");
    std::thread::sleep(Duration::from_millis(1500)); // several request timeouts with nothing sent
    assert!(attached(), "the idle terminal was dropped after the request timeout");
}
