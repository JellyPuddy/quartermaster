//! The curl transport against a local server: what curl reads from its stdin config (quoting, headers, body,
//! the status line it appends) and how a failure to connect reads. The real network is never touched.

use quartermaster::routines_client::{CurlTransport, Transport};
use std::io::{Read, Write};
use std::net::TcpListener;

fn serve(status: &str, body: &'static str) -> (u16, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let status = status.to_string();
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut raw = vec![];
        let mut buf = [0u8; 4096];
        loop {
            let n = stream.read(&mut buf).unwrap_or(0);
            raw.extend_from_slice(&buf[..n]);
            let text = String::from_utf8_lossy(&raw).to_string();
            if let Some(at) = text.find("\r\n\r\n") {
                let want: usize = text[..at].to_lowercase().lines().find_map(|l| l.strip_prefix("content-length:").and_then(|v| v.trim().parse().ok())).unwrap_or(0);
                if raw.len() >= at + 4 + want {
                    break;
                }
            }
            if n == 0 {
                break;
            }
        }
        let _ = write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        String::from_utf8_lossy(&raw).into_owned()
    });
    (port, handle)
}

fn has_curl() -> bool {
    std::process::Command::new("curl").arg("--version").output().is_ok()
}

#[test]
fn a_request_goes_through_curls_stdin_config_and_its_answer_comes_back_with_the_status() {
    if !has_curl() {
        eprintln!("skipped: no curl");
        return;
    }
    let (port, server) = serve("201 Created", "{\"ok\":true}\n");
    let body = "{\"prompt\":\"say \\\"hi\\\"\\nand a backslash \\\\ done\"}";
    let headers = vec![("Authorization".to_string(), "Bearer sk-secret".to_string()), ("x-organization-uuid".to_string(), "org".to_string())];
    let (status, text) = CurlTransport.call("POST", &format!("http://127.0.0.1:{port}/v1/code/triggers"), &headers, Some(body)).unwrap();
    assert_eq!((status, text.as_str()), (201, "{\"ok\":true}\n"));
    let raw = server.join().unwrap();
    assert!(raw.starts_with("POST /v1/code/triggers HTTP/1.1\r\n"), "{raw}");
    assert!(raw.to_lowercase().contains("authorization: bearer sk-secret\r\n") && raw.contains("x-organization-uuid: org\r\n"), "{raw}");
    assert!(raw.ends_with(body), "the body arrives byte for byte: {raw}");
}

#[test]
fn a_get_sends_no_body_and_a_refused_connection_is_an_error_without_a_status() {
    if !has_curl() {
        return;
    }
    let (port, server) = serve("404 Not Found", "{}");
    let (status, text) = CurlTransport.call("GET", &format!("http://127.0.0.1:{port}/x"), &[], None).unwrap();
    assert_eq!((status, text.as_str()), (404, "{}"));
    let raw = server.join().unwrap();
    assert!(raw.starts_with("GET /x HTTP/1.1") && !raw.to_lowercase().contains("content-length"), "{raw}");

    let free = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let error = CurlTransport.call("GET", &format!("http://127.0.0.1:{free}/x"), &[], None).unwrap_err();
    assert!(error.contains("curl"), "{error}");
}
