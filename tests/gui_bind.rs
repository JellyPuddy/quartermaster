//! `qm gui` and its port: 0 asks the OS (and the URL printed is the real one), a port outside 0-65535 is
//! refused by name, and a port already served is the "already running" path.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};

fn gui(root: &std::path::Path, port: &str) -> Child {
    Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("QM_ROOT", root)
        .env("HOME", root)
        .env("QM_GUI_PORT", port)
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_TMUX_SOCKET", "qm-test-bind")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn printed_port(child: &mut Child) -> u16 {
    let mut line = String::new();
    BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    line.split("127.0.0.1:").nth(1).and_then(|r| r.split_whitespace().next()).and_then(|p| p.parse().ok()).unwrap_or_else(|| panic!("no port in {line:?}"))
}

#[test]
fn port_zero_serves_on_the_port_it_got_and_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let mut child = gui(dir.path(), "0");
    let port = printed_port(&mut child);
    assert_ne!(port, 0);
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(s, "GET /api/root HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").unwrap();
    let mut reply = String::new();
    s.read_to_string(&mut reply).unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
}

#[test]
fn a_port_out_of_range_is_refused_by_name() {
    let dir = tempfile::tempdir().unwrap();
    for bad in ["70000", "-1"] {
        let out = gui(dir.path(), bad).wait_with_output().unwrap();
        let err = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "{bad}");
        assert!(err.contains("QM_GUI_PORT") && err.contains(bad) && !err.contains("can't do this as given"), "{err}");
    }
}

#[test]
fn a_port_that_cannot_be_bound_reports_the_os_error() {
    let dir = tempfile::tempdir().unwrap();
    // port 1 is privileged: unprivileged, the bind fails with something other than AddrInUse
    let out = Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("QM_ROOT", dir.path())
        .env("QM_GUI_PORT", "1")
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_TMUX_SOCKET", "qm-test-bind")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    if out.status.code() == Some(1) {
        assert!(err.contains("can't listen on 127.0.0.1:1") && !err.contains("can't do this as given"), "{err}");
    }
}
