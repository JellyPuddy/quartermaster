//! The Automations tab over a real `qm gui` on a throwaway data root: the page's tab strip and assets in load
//! order, the Origin rules of its POSTs and of the `automation-chat` action (a local action, so the CLI may send
//! it without an Origin), and one refresh end to end through the real routines client with a stand-in `curl` and
//! `security` on PATH. Nothing reaches the keychain, the network, launchd or a real claude.

use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const SOCKET: &str = "qm-test-gui-automations";

const LIST: &str = include_str!("fixtures/routines-list-response.json");

struct World {
    base: tempfile::TempDir,
    child: Child,
    port: u16,
    socket: String,
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = Command::new("tmux").args(["-L", &self.socket, "kill-server"]).stderr(Stdio::null()).status();
    }
}

fn script(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

impl World {
    fn new(config: &str) -> World {
        let base = tempfile::tempdir().unwrap();
        let (root, home, bin, answers) = (base.path().join("root"), base.path().join("home"), base.path().join("bin"), base.path().join("answers"));
        for dir in [&root, &home, &bin, &answers] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(root.join("config.yml"), config).unwrap();
        fs::write(home.join(".claude.json"), r#"{"oauthAccount":{"organizationUuid":"org-1"}}"#).unwrap();
        fs::write(base.path().join("credentials"), format!(r#"{{"claudeAiOauth":{{"accessToken":"sk-ant-oat01-TEST","expiresAt":{}}}}}"#, (chrono::Utc::now().timestamp() + 3600) * 1000)).unwrap();
        script(&bin.join("curl"), "#!/bin/sh\ncfg=$(cat)\nprintf '%s\\n---\\n' \"$cfg\" >> \"$FAKE_DIR/curl.log\"\nurl=$(printf '%s\\n' \"$cfg\" | sed -n 's/^url = \"\\(.*\\)\"$/\\1/p')\nmethod=$(printf '%s\\n' \"$cfg\" | sed -n 's/^request = \"\\(.*\\)\"$/\\1/p')\nkey=$(printf '%s %s' \"$method\" \"${url#https://api.anthropic.com}\" | tr -c 'A-Za-z0-9' '_')\n[ -f \"$FAKE_DIR/answers/$key\" ] && { cat \"$FAKE_DIR/answers/$key\"; exit 0; }\nprintf '{}\\n404'\n");
        script(&bin.join("security"), "#!/bin/sh\ncat \"$FAKE_DIR/credentials\"\n");
        script(&bin.join("launchctl"), "#!/bin/sh\nexit 1\n");
        script(&bin.join("claude"), "#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s\\0' \"$QM_ITEM\" \"$@\" > \"$d/chat.log\"\nexec sleep 120\n");
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        let socket = format!("{SOCKET}-{port}");
        let child = Command::new(env!("CARGO_BIN_EXE_qm"))
            .arg("gui")
            .env("QM_ROOT", &root)
            .env("HOME", &home)
            .env("PATH", path)
            .env("FAKE_DIR", base.path())
            .env("QM_GUI_PORT", port.to_string())
            .env("QM_GUI_NO_OPEN", "1")
            .env("QM_CONFIG_STRICT", "1")
            .env("QM_TMUX_SOCKET", &socket)
            .env("QM_CHAT_COMMAND", bin.join("claude"))
            .env_remove("QM_SKIP")
            .env_remove("TMUX")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let world = World { base, child, port, socket };
        for _ in 0..100 {
            if TcpStream::connect(("127.0.0.1", port)).is_ok() {
                return world;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("the GUI did not come up");
    }

    fn send(&self, method: &str, path: &str, extra: &[(&str, String)], body: &str) -> (String, String) {
        let mut stream = TcpStream::connect(("127.0.0.1", self.port)).unwrap();
        let mut req = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n", self.port);
        for (k, v) in extra {
            req += &format!("{k}: {v}\r\n");
        }
        req += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        stream.write_all(req.as_bytes()).unwrap();
        let mut raw = vec![];
        stream.read_to_end(&mut raw).unwrap();
        let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
        let head = String::from_utf8_lossy(&raw[..split]).into_owned();
        (head.lines().next().unwrap().trim_start_matches("HTTP/1.1 ").to_string(), String::from_utf8_lossy(&raw[split + 4..]).into_owned())
    }

    fn own(&self) -> Vec<(&'static str, String)> {
        vec![("Origin", format!("http://127.0.0.1:{}", self.port))]
    }

    fn get(&self, path: &str) -> String {
        let (status, body) = self.send("GET", path, &[], "");
        assert_eq!(status, "200 OK", "{path}: {body}");
        body
    }

    fn json(&self, path: &str) -> Value {
        serde_json::from_str(&self.get(path)).unwrap()
    }

    fn post(&self, route: &str, payload: Value, headers: &[(&str, String)]) -> (String, Value) {
        let (status, body) = self.send("POST", route, headers, &payload.to_string());
        (status, serde_json::from_str(&body).unwrap_or(Value::String(body)))
    }

    fn answer(&self, method: &str, path: &str, status: u16, body: &str) {
        let key: String = format!("{method} {path}").chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
        fs::write(self.base.path().join("answers").join(key), format!("{body}\n{status}")).unwrap();
    }

    fn sessions(&self) -> Vec<String> {
        let out = Command::new("tmux").args(["-L", &self.socket, "list-sessions", "-F", "#{session_name}"]).env_remove("TMUX").output().unwrap();
        String::from_utf8_lossy(&out.stdout).lines().map(String::from).collect()
    }

    fn chat_log(&self) -> PathBuf {
        self.base.path().join("bin/chat.log")
    }
}

fn foreign() -> Vec<(&'static str, String)> {
    vec![("Origin", "http://evil.example".to_string())]
}

#[test]
fn the_page_has_the_settings_automations_tab_strip_and_loads_its_scripts_before_events() {
    let w = World::new("");
    let page = w.get("/");
    for wanted in [r#"data-st-tab="automations""#, r#"id="au-body""#, r#"href="/assets/css/automations.css""#] {
        assert!(page.contains(wanted), "{wanted}");
    }
    let at = |s: &str| page.find(&format!(r#"<script src="/assets/js/{s}.js">"#)).unwrap_or_else(|| panic!("no tag for {s}"));
    assert!(at("settings") < at("automations-render") && at("automations-render") < at("automations") && at("automations") < at("events"));
    let asset = |name: &str| w.get(&format!("/assets/{name}"));
    let (automations, render, jobs) = (asset("js/automations.js"), asset("js/automations-render.js"), asset("js/long-actions.js"));
    assert!(automations.contains(r#"fetch("/api/automations")"#) && jobs.contains("if (automationJobFinished(r)) return;"));
    assert!(automations.contains(r#"case "recreate": run("recreate")"#) && automations.contains(r#"case "install-tick": automationJob("install-tick", {}, "automation-tick")"#));
    assert!(automations.contains(r#"case "resume-run": resumeRun(slug, node.dataset.run)"#) && automations.contains(r#"act("describe", { slug, args: { text } })"#));
    assert!(render.contains("automationsTickBar(a.list.local)") && render.contains(r#"if (d.runner === "local") return automationLocalDetail(d);"#));
    assert!(render.contains(r#"data-au="local-pause""#) && render.contains(r#"data-au="mark-seen""#) && render.contains(r#"id="au-new-runner""#));
    let button = regex::Regex::new(r#"(?s)d\.missing \? [^:]{0,300}data-au="recreate">Re-create on claude\.ai<"#).unwrap();
    assert!(button.is_match(&render), "the Re-create button sits in the missing branch");
    let loose = asset("js/loose.js");
    assert!(loose.contains(r#"renderLooseRows(list, "Runs ", looseChats.filter(lc => lc.run))"#) && loose.contains("showAutomation(lc.run.slug)"));
    assert!(asset("js/notify.js").contains("...looseChats.filter(lc => !(lc.run && lc.run.quiet))"));
}

#[test]
fn the_tabs_posts_need_our_origin_and_the_describe_action_too() {
    let w = World::new("automations:\n  token_source: claude_code\n");
    for route in ["/api/automations/refresh", "/api/automations/recreate", "/api/automations/local-pause", "/api/automations/adopt", "/api/automations/install-tick"] {
        for headers in [foreign(), vec![]] {
            let (status, _) = w.post(route, json!({"slug": "digest"}), &headers);
            assert_eq!(status, "403 Forbidden", "{route} {headers:?}");
        }
    }
    let describe = json!({"cmd": "describe", "slug": "weekly-report", "args": {"text": "What shipped.\n"}});
    for headers in [foreign(), vec![]] {
        assert_eq!(w.post("/api/action", describe.clone(), &headers).0, "403 Forbidden");
    }
    assert!(w.json("/api/automations")["rows"].as_array().unwrap().is_empty());
    let (status, answer) = w.post("/api/automations/new", json!({"title": "Weekly report", "project": "MyApp"}), &w.own());
    assert_eq!((status.as_str(), &answer["slug"]), ("200 OK", &json!("weekly-report")));
    let (status, answer) = w.post("/api/action", describe, &w.own());
    assert_eq!((status.as_str(), &answer["ok"]), ("200 OK", &json!(true)));
    assert_eq!(w.json("/api/automations/weekly-report")["item"]["description"], "What shipped.");
}

#[test]
fn automation_chat_is_a_local_action_with_no_origin_and_refused_from_another_origin() {
    let w = World::new("");
    w.post("/api/automations/new", json!({"title": "Weekly report", "project": "MyApp", "description": "Summarise the week."}), &w.own());
    let chat = json!({"cmd": "automation-chat", "slug": "weekly-report"});
    assert_eq!(w.post("/api/action", chat.clone(), &foreign()).0, "403 Forbidden");
    assert!(w.sessions().is_empty(), "a refused action starts nothing");

    let (status, answer) = w.post("/api/action", chat.clone(), &[]);
    assert_eq!((status.as_str(), &answer["ok"]), ("200 OK", &json!(true)), "{answer}");
    let until = Instant::now() + Duration::from_secs(10);
    while !w.chat_log().exists() {
        assert!(Instant::now() < until, "the chat never started");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(w.sessions(), ["weekly-report"]);
    let started = fs::read_to_string(w.chat_log()).unwrap();
    assert!(started.starts_with("weekly-report\0") && started.contains("Summarise the week."), "QM_ITEM, then the brief as claude's argument: {started}");

    let (_, again) = w.post("/api/action", chat, &[]);
    assert_eq!((&again["ok"], &again["attached"]), (&json!(true), &json!(true)), "a live chat is only shown again");
    assert!(again["brief"].as_str().unwrap().contains("weekly-report"));
}

#[test]
fn a_refresh_goes_through_the_real_client_and_lists_the_routines_for_adoption() {
    let w = World::new("automations:\n  token_source: claude_code\n");
    w.answer("GET", "/v1/code/triggers", 200, LIST.trim());
    assert_eq!(w.json("/api/automations")["remote"]["state"], "idle");
    let (status, answer) = w.post("/api/automations/refresh", json!({}), &w.own());
    assert_eq!((status.as_str(), &answer["background"]), ("200 OK", &json!(true)));
    let until = Instant::now() + Duration::from_secs(15);
    let listed = loop {
        let listed = w.json("/api/automations");
        if listed["remote"]["state"] == "ok" {
            break listed;
        }
        assert!(Instant::now() < until, "the list never arrived: {listed}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(listed["unmanaged"][0]["id"], "trig_01AAAAAAAAAAAAAAAAAAAAAAAA");
    let curl = fs::read_to_string(w.base.path().join("curl.log")).unwrap();
    assert!(curl.contains("Authorization: Bearer sk-ant-oat01-TEST"), "the token goes in curl's stdin config");
    let state = w.json("/api/state");
    assert!(state["finished"].as_array().unwrap().iter().any(|j| j["key"] == "automations" && j["quiet"] == true), "the job's end reaches the page through the state: {state}");
}
