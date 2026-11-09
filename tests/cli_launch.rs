//! The fzf viewer and its pickers, `open-chat`, `start-issue` and `loose`: against a fake `fzf` that
//! logs what it was given and answers from a file, fake `osascript`/`open`/`gh`, a local origin and a
//! stand-in GUI server. Transcripts generated from Ruby.

mod common;
use common::*;
use regex::Regex;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};

fn script(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn fake_gui(log: std::path::PathBuf, refuse: Arc<AtomicBool>, root: &Path) -> u16 {
    let root_id = quartermaster::sha256::hex(fs::canonicalize(root).unwrap().to_string_lossy().as_bytes());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
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
            if text.starts_with("GET /api/root") {
                let reply = format!("{{\"root\":\"{root_id}\"}}");
                let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len());
                continue;
            }
            let body = text.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
            let mut f = fs::OpenOptions::new().create(true).append(true).open(&log).unwrap();
            writeln!(f, "{body}").unwrap();
            let reply = if refuse.load(Ordering::SeqCst) {
                r#"{"ok":false,"error":"nope"}"#
            } else if body.contains("loose-start") {
                r#"{"ok":true,"id":"ab12cd34","name":"loose--ab12cd34"}"#
            } else if body.contains("\"number\":12") {
                r#"{"ok":true,"slug":"fix-12","existing":true}"#
            } else {
                r#"{"ok":true,"slug":"fix-the-thing-13","existing":false}"#
            };
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len());
        }
    });
    port
}

#[test]
fn viewer_pickers_and_launch_commands() {
    let qm = Qm::new();
    let root = qm.root.path().to_path_buf();
    let tools = root.join("tools");
    let origin = root.join("acme/widgets.git");
    let repo = root.join("repo");
    fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare", "-b", "main"]);
    common::repo(&repo, "main");
    git(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&repo, &["push", "-q", "origin", "main"]);
    git(&repo, &["remote", "set-head", "origin", "main"]);
    script(&tools.join("fzf"), "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$FAKE_LOG\"\ncat >> \"$FAKE_LOG.stdin\"\necho >> \"$FAKE_LOG.stdin\"\n[ -f \"$FAKE_LOG.answer\" ] && { cat \"$FAKE_LOG.answer\"; exit 0; }\nexit 130\n");
    script(&tools.join("osascript"), "#!/bin/sh\necho \"osascript $(echo \"$*\" | tail -c 120 | tr '\\n' ' ')\" >> \"$FAKE_LOG\"\n[ -f \"$FAKE_LOG.arc\" ] && echo found\nexit 0\n");
    script(&tools.join("open"), "#!/bin/sh\necho \"open $*\" >> \"$FAKE_LOG\"\nexit 0\n");
    script(&tools.join("gh"), "#!/bin/sh\necho \"gh $*\" >> \"$FAKE_LOG\"\ncase \"$1 $2 $3\" in\n\"issue view 12\"|\"issue view 13\"|\"issue view 14\") echo \"{\\\"number\\\":$3,\\\"title\\\":\\\"Fix the thing\\\",\\\"state\\\":\\\"OPEN\\\",\\\"url\\\":\\\"https://github.com/acme/widgets/issues/$3\\\"}\"; exit 0;;\n\"issue view 15\") echo '{\"number\":15,\"title\":\"Old\",\"state\":\"CLOSED\",\"url\":\"https://github.com/acme/widgets/issues/15\"}'; exit 0;;\n\"pr view feat-b\") exit 0;;\nesac\necho \"no such thing\" >&2\nexit 1\n");
    fs::write(root.join("config.yml"), format!("default_project: demo\nloose_starters:\n  dev:\n    label: Dev docs\n    prompt: Load the dev docs.\nprojects:\n  demo:\n    root: {}\n", repo.display())).unwrap();
    qm.ok(&["list"]);
    fs::create_dir_all(root.join("work-items")).unwrap();
    let item = |slug: &str, state: &str, extra: &str, desc: &str| fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug} title\nstate: {state}\nproject: demo\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\n{desc}\n\n## Notes\n\n## Snapshots\n")).unwrap();
    item("v-one", "in_progress", "branches:\n- feat-a\n- feat-b\n", "d");
    item("v-two", "fridge", "", "d");
    item("v-res", "resolved", "", "d");
    item("fix-12", "in_progress", "", "https://github.com/acme/widgets/issues/12\n\nFix the thing");
    fs::write(root.join("sessions.jsonl"), format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"s-newone-1\",\"cwd\":\"{}\",\"branch\":\"feat-x\",\"project\":\"demo\",\"pid\":999999,\"transcript_path\":\"/nowhere\",\"ts\":\"2026-03-01T00:00:00+00:00\"}}\n", repo.display())).unwrap();
    let gui_log = root.join("gui.log");
    let refuse = Arc::new(AtomicBool::new(false));
    let live_port = fake_gui(gui_log.clone(), refuse.clone(), &root);
    let dead_port = { let l = TcpListener::bind("127.0.0.1:0").unwrap(); l.local_addr().unwrap().port() };
    fs::create_dir_all(root.join("home")).unwrap();
    let fake_log = root.join("tool.log");
    let env_for = |port: u16| -> Vec<(&'static str, String)> {
        vec![
            ("PATH", format!("{}:{}", tools.display(), std::env::var("PATH").unwrap())),
            ("HOME", root.join("home").display().to_string()),
            ("FAKE_LOG", fake_log.display().to_string()),
            ("QM_GUI_PORT", port.to_string()),
        ]
    };
    let answer = |text: Option<&str>| {
        let p = root.join("tool.log.answer");
        match text { Some(t) => fs::write(p, t).unwrap(), None => { let _ = fs::remove_file(p); } }
    };
    let mut out = String::new();
    let mut run = |port: u16, args: &[&str], stdin: &str| {
        let env = env_for(port);
        let refs: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
        out += &transcript_env(&qm, "none", &[(args, stdin)], &refs);
    };
    // pickers
    answer(Some("fridge\n"));
    run(dead_port, &["choose-state", "v-two"], "");
    answer(None);
    run(dead_port, &["choose-state", "v-two"], "");
    run(dead_port, &["choose-state"], "");
    run(dead_port, &["choose-state", "nowhere"], "");
    answer(Some("No project\n"));
    run(dead_port, &["choose-project", "v-two"], "");
    answer(Some("7d\n"));
    run(dead_port, &["choose-snooze", "v-two"], "");
    run(dead_port, &["choose-snooze"], "");
    answer(Some("v-two\tv-two title\n"));
    run(dead_port, &["attach-session", "s-newone-1"], "");
    run(dead_port, &["attach-session"], "");
    answer(Some("feat-b\n"));
    run(dead_port, &["pr", "v-one"], "");
    answer(None);
    run(dead_port, &["pr", "v-one"], "");
    answer(Some("v-res\n"));
    run(dead_port, &["viewer"], "");
    run(dead_port, &["sessions-view", "v-one"], "");
    run(dead_port, &["sessions-view"], "");
    run(dead_port, &["inbox-view"], "");
    run(dead_port, &["item-from-session", "nope"], "");
    run(dead_port, &["item-from-session", "s-newone-1"], "  A fresh item  \nignored\n");
    run(dead_port, &["item-from-session", "s-newone-1"], "\n");
    run(dead_port, &["item-from-session"], "");
    // open-chat
    run(dead_port, &["open-chat"], "");
    run(dead_port, &["open-chat", "v-one"], "");
    run(live_port, &["open-chat", "v-one", "--benchmark", "feat a/b"], "");
    fs::write(root.join("tool.log.arc"), "").unwrap();
    run(live_port, &["open-chat", "--benchmark=x", "v-one"], "");
    // start-issue
    run(dead_port, &["start-issue"], "");
    run(dead_port, &["start-issue", "abc"], "");
    run(dead_port, &["start-issue", "99"], "");
    run(dead_port, &["start-issue", "15"], "");
    run(live_port, &["start-issue", "12"], "");
    run(live_port, &["start-issue", "#13", "--project", "demo"], "");
    refuse.store(true, Ordering::SeqCst);
    run(live_port, &["start-issue", "13"], "");
    refuse.store(false, Ordering::SeqCst);
    run(live_port, &["start-issue", "13", "--project", "nowhere"], "");
    run(dead_port, &["start-issue", "14"], "");
    run(dead_port, &["start-issue", "14"], "");
    // loose
    run(dead_port, &["loose"], "");
    run(dead_port, &["loose", "what is this?"], "");
    run(dead_port, &["loose", "--model", "opus", "--project", "demo", "a question"], "");
    run(dead_port, &["loose", "--starter", "dev", "a question"], "");
    run(dead_port, &["loose", "--starter", "nope"], "");
    run(dead_port, &["loose", "--model", "gpt"], "");
    run(dead_port, &["loose", "a", "b"], "");
    run(live_port, &["loose", "--starter", "dev", "--model", "haiku", "q"], "");
    refuse.store(true, Ordering::SeqCst);
    run(live_port, &["loose", "q"], "");
    let mut text = format!("{out}tool log:\n{}fzf stdin:\n{}gui log:\n{}view filter:\n{}", fs::read_to_string(&fake_log).unwrap_or_default(), fs::read_to_string(root.join("tool.log.stdin")).unwrap_or_default(), fs::read_to_string(&gui_log).unwrap_or_default(), fs::read_to_string(root.join("viewer-filter")).unwrap_or_default());
    text = scrub(&qm, &text);
    let bin = bin().to_string_lossy().into_owned();
    text = text.replace(&bin, "QM").replace(&live_port.to_string(), "LIVEPORT").replace(&dead_port.to_string(), "DEADPORT");
    text = Regex::new(r"QM_LOOSE=[0-9a-f]{8}").unwrap().replace_all(&text, "QM_LOOSE=ID").into_owned();
    golden("cli_launch.txt", &text);
}
