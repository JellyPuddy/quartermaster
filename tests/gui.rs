//! The Rust GUI server (`QM_RUST_GUI=1 qm gui`) next to Ruby's, both on one data root: the same
//! request goes to each and the status, content type and body must agree, route by route. Only what
//! is ported is compared; the rest answers 501 here.

mod common;
use common::git;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

struct Server {
    child: Child,
    port: u16,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn start(rust: bool, root: &Path, home: &Path) -> Server {
    let port = free_port();
    let bin: PathBuf = if rust { Path::new(env!("CARGO_BIN_EXE_qm")).into() } else { Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster") };
    let mut cmd = Command::new(bin);
    cmd.arg("gui").env("QM_ROOT", root).env("HOME", home).env("QM_GUI_PORT", port.to_string()).env("QM_GUI_NO_OPEN", "1").env("LANG", "C.UTF-8").env("LC_ALL", "C.UTF-8").env("QM_TMUX_SOCKET", "qm-test-gui").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if rust {
        cmd.env("QM_RUST_GUI", "1");
    }
    let child = cmd.spawn().unwrap();
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Server { child, port };
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("the GUI did not come up");
}

struct Answer {
    status: String,
    content_type: String,
    body: Vec<u8>,
}

fn request(port: u16, method: &str, path: &str, headers: &[(&str, String)], body: &str, own_host: bool) -> Answer {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\n");
    if own_host {
        req += &format!("Host: 127.0.0.1:{port}\r\n");
    }
    for (k, v) in headers {
        req += &format!("{k}: {}\r\n", v.replace("PORT", &port.to_string()));
    }
    req += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    stream.write_all(req.as_bytes()).unwrap();
    let mut raw = vec![];
    stream.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let status = head.lines().next().unwrap().trim_start_matches("HTTP/1.1 ").to_string();
    let content_type = head.lines().find_map(|l| l.strip_prefix("Content-Type: ")).unwrap_or("").to_string();
    Answer { status, content_type, body: raw[split + 4..].to_vec() }
}

fn shown(a: &Answer, port: u16) -> String {
    let body = String::from_utf8_lossy(&a.body).replace(&port.to_string(), "PORT");
    let body = regex::Regex::new(r"let terminalToken = \x22[0-9a-f]{48}\x22").unwrap().replace_all(&body, "let terminalToken = TOKEN").into_owned();
    format!("{} | {} | {body}", a.status, a.content_type)
}

fn world(base: &Path) -> (PathBuf, PathBuf, String) {
    let (root, home, repo) = (base.join("root"), base.join("home"), base.join("repo"));
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("a.txt"), "one\ntwo\r\nthree\n\nlast without newline").unwrap();
    fs::write(repo.join("bytes.bin"), b"ok \xff\xfe bad\nnext \xe2\x82 line\n").unwrap();
    fs::write(repo.join("big.txt"), "x".repeat(70) + "\n").unwrap();
    let many: String = (0..25_000).map(|i| format!("line {i}\n")).collect();
    fs::write(repo.join("many.txt"), many).unwrap();
    let wide: String = (0..30_000).map(|i| format!("{i:030}\n")).collect();
    fs::write(repo.join("wide.txt"), wide).unwrap();
    fs::write(repo.join("empty.txt"), "").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "commit", "-q", "-m", "one"]);
    let sha = git(&repo, &["rev-parse", "HEAD"]);
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    for (slug, project) in [("demo-item", "demo"), ("orphan", "elsewhere")] {
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    }
    fs::write(root.join("sessions.jsonl"), "{\"v\":1,\"event\":\"start\",\"session_id\":\"s1\",\"ts\":\"2026-03-01T00:00:00+00:00\"}\n").unwrap();
    fs::write(root.join("events.jsonl"), "{\"v\":1}\n").unwrap();
    fs::create_dir_all(root.join("drafts")).unwrap();
    fs::write(root.join("drafts/demo-item.json"), "{\"v\":1,\"entries\":[]}").unwrap();
    fs::write(root.join("drafts/.demo-item.lock"), "").unwrap();
    fs::create_dir_all(root.join("issues/demo-item/.prev")).unwrap();
    fs::write(root.join("issues/demo-item/01-a.md"), "---\ntitle: A\nkind: bug\n---\n").unwrap();
    fs::write(root.join("issues/demo-item/.prev/01-a.md.json"), "{}").unwrap();
    fs::create_dir_all(root.join("issues/a-b")).unwrap();
    fs::write(root.join("issues/a-b/x.md"), "x").unwrap();
    fs::create_dir_all(root.join("issues/a")).unwrap();
    fs::write(root.join("issues/a/x.md"), "x").unwrap();
    (root, home, sha)
}

#[test]
fn the_rust_server_answers_the_ported_routes_as_ruby_does() {
    let base = tempfile::tempdir().unwrap();
    let (root, home, sha) = world(base.path());
    let ruby = start(false, &root, &home);
    let rust = start(true, &root, &home);
    let mut log = String::new();
    let mut check = |label: &str, method: &str, path: &str, headers: &[(&str, String)], body: &str, own_host: bool| {
        let (a, b) = (request(ruby.port, method, path, headers, body, own_host), request(rust.port, method, path, headers, body, own_host));
        let (ra, rb) = (shown(&a, ruby.port), shown(&b, rust.port));
        assert_eq!(rb, ra, "{label}: {method} {path}");
        log += &format!("{label}: {}\n", ra.chars().take(160).collect::<String>().replace('\n', "↵"));
    };
    check("page", "GET", "/", &[], "", true);
    for asset in ["css/base.css", "js/core.js", "js/events.js", "css/diff.css"] {
        check("asset", "GET", &format!("/assets/{asset}"), &[], "", true);
    }
    for bad in ["/assets/css/nope.css", "/assets/js/../../page.html", "/assets/css/Base.css", "/assets/js/core.js.map", "/assets/"] {
        check("bad asset", "GET", bad, &[], "", true);
    }
    check("pulse", "GET", "/api/pulse", &[], "", true);
    check("pulse with query", "GET", "/api/pulse?visible=1&focused=1&chat=demo-item", &[], "", true);
    fs::write(root.join("events.jsonl"), "{\"v\":1}\n{\"v\":2}\n").unwrap();
    fs::write(root.join("drafts/other.json"), "{\"v\":1,\"entries\":[{\"id\":\"x\"}]}").unwrap();
    fs::create_dir_all(root.join("issues/zz")).unwrap();
    fs::write(root.join("issues/zz/y.md"), "y").unwrap();
    check("pulse after changes", "GET", "/api/pulse", &[], "", true);
    let slug = "demo-item";
    for (label, query) in [
        ("file", format!("rev={sha}&path=a.txt")),
        ("short sha", format!("rev={}&path=a.txt", &sha[..7])),
        ("upper sha", format!("rev={}&path=a.txt", sha.to_uppercase())),
        ("bytes", format!("rev={sha}&path=bytes.bin")),
        ("empty file", format!("rev={sha}&path=empty.txt")),
        ("many lines", format!("rev={sha}&path=many.txt")),
        ("many bytes", format!("rev={sha}&path=wide.txt")),
        ("missing", format!("rev={sha}&path=nope.txt")),
        ("tree not blob", format!("rev={sha}&path=")),
        ("no path", format!("rev={sha}")),
        ("no rev", "path=a.txt".to_string()),
        ("bad rev", "rev=zzzz&path=a.txt".to_string()),
        ("quoted rev", "rev=a%22b%0A%23%7Bx%7D&path=a.txt".to_string()),
        ("too short", "rev=abc&path=a.txt".to_string()),
        ("plus path", format!("rev={sha}&path=a%20.txt")),
        ("nul path", format!("rev={sha}&path=a.txt%00x")),
        ("option-like path", format!("rev={sha}&path=--help")),
        ("repeated key", format!("rev=zzz&rev={sha}&path=a.txt")),
    ] {
        check(label, "GET", &format!("/api/diff-file/{slug}?{query}"), &[], "", true);
    }
    check("unknown item", "GET", &format!("/api/diff-file/nosuch?rev={sha}&path=a.txt"), &[], "", true);
    check("no project root", "GET", &format!("/api/diff-file/orphan?rev={sha}&path=a.txt"), &[], "", true);
    check("encoded slug", "GET", &format!("/api/diff-file/demo%2Ditem?rev={sha}&path=a.txt"), &[], "", true);
    check("bad host", "GET", "/api/pulse", &[("Host", "evil.test".into())], "", false);
    check("no host", "GET", "/api/pulse", &[], "", false);
    check("localhost host", "GET", "/api/pulse", &[("Host", "localhost:PORT".into())], "", false);
    check("foreign origin", "POST", "/api/action", &[("Origin", "http://evil.test".into())], "{}", true);
    check("no origin, not local", "POST", "/api/action", &[], "{\"cmd\":\"state\"}", true);
    check("no origin, junk", "POST", "/api/action", &[], "not json", true);
    check("no origin, other route", "POST", "/api/grep", &[], "{}", true);
    // the use log: what each server recorded, by kind and name only
    let uses = fs::read_to_string(root.join("feature-use.jsonl")).unwrap_or_default();
    let names: Vec<String> = uses.lines().map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()).map(|v| format!("{} {}", v["kind"], v["name"])).collect();
    let mut counts = std::collections::BTreeMap::new();
    for n in names.iter().filter(|n| !n.starts_with("\"cli\"")) {
        *counts.entry(n.clone()).or_insert(0) += 1;
    }
    assert!(counts.contains_key("\"get\" \"/api/diff-file\"") && counts.contains_key("\"action\" \"state\"") == false);
    for (name, n) in &counts {
        assert_eq!(n % 2, 0, "{name} is recorded once by each server: {counts:?}");
    }
    assert!(log.lines().count() > 40, "{log}");
}
