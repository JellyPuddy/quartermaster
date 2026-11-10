//! The Settings endpoints of the Rust GUI on a throwaway data root (the port of upstream's
//! gui_settings_test.rb): the form's payload, check, and save with its stale and invalid refusals.

use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

const SOCKET: &str = "qm-test-gui-settings";

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

struct World {
    _base: tempfile::TempDir,
    root: PathBuf,
    app: PathBuf,
    plain: PathBuf,
    server: Server,
}

fn executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    fs::write(path, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A GUI whose warnings stay quiet: the project folders exist and `pf` and `app-test-db` are on its PATH.
fn world() -> World {
    let base = tempfile::tempdir().unwrap();
    let (root, home, bin) = (base.path().join("root"), base.path().join("home"), base.path().join("bin"));
    let (app, plain) = (base.path().join("app"), base.path().join("plain"));
    for dir in [&root, &home, &bin, &app, &plain] {
        fs::create_dir_all(dir).unwrap();
    }
    for name in ["pf", "app-test-db"] {
        executable(&bin.join(name));
    }
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let child = Command::new(env!("CARGO_BIN_EXE_qm"))
        .arg("gui")
        .env("QM_ROOT", &root)
        .env("HOME", &home)
        .env("PATH", path)
        .env("QM_GUI_PORT", port.to_string())
        .env("QM_GUI_NO_OPEN", "1")
        .env("QM_CONFIG_STRICT", "1")
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
            return World { _base: base, root, app, plain, server };
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("the GUI did not come up");
}

struct Answer {
    status: String,
    content_type: String,
    body: String,
}

impl Answer {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }
}

fn send(port: u16, method: &str, path: &str, headers: &[(&str, String)], body: &str) -> Answer {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\n");
    for (k, v) in headers {
        req += &format!("{k}: {v}\r\n");
    }
    req += &format!("Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    stream.write_all(req.as_bytes()).unwrap();
    let mut raw = vec![];
    stream.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    Answer {
        status: head.lines().next().unwrap().trim_start_matches("HTTP/1.1 ").to_string(),
        content_type: head.lines().find_map(|l| l.strip_prefix("Content-Type: ")).unwrap_or("").to_string(),
        body: String::from_utf8_lossy(&raw[split + 4..]).into_owned(),
    }
}

impl World {
    fn file(&self) -> PathBuf {
        self.root.join("config.yml")
    }
    fn write(&self, text: &str) {
        fs::write(self.file(), text).unwrap();
    }
    fn read(&self) -> String {
        fs::read_to_string(self.file()).unwrap()
    }
    fn own_host(&self) -> Vec<(&'static str, String)> {
        vec![("Host", format!("127.0.0.1:{}", self.server.port))]
    }
    fn own_origin(&self) -> Vec<(&'static str, String)> {
        let mut h = self.own_host();
        h.push(("Origin", format!("http://127.0.0.1:{}", self.server.port)));
        h
    }
    fn get(&self, path: &str) -> Answer {
        send(self.server.port, "GET", path, &self.own_host(), "")
    }
    fn settings(&self) -> Value {
        let a = self.get("/api/settings");
        assert_eq!(a.status, "200 OK");
        assert!(a.content_type.contains("application/json"));
        a.json()
    }
    fn post(&self, route: &str, payload: Value) -> Answer {
        send(self.server.port, "POST", route, &self.own_origin(), &payload.to_string())
    }
    /// The App/Plain config the tests start from, on this world's real folders.
    fn app_config(&self) -> String {
        format!("projects:\n  Plain: {}\n  App:\n    root: {}\n    dev_server: pf\n    test_db: app-test-db\nide_command: [code, PATH]\nmy_notes: {{ keep: 1 }}\n", self.plain.display(), self.app.display())
    }
}

fn digest(text: &str) -> String {
    quartermaster::config_file::digest_of(text)
}

fn error_paths(answer: &Value) -> Vec<String> {
    answer["issues"].as_array().unwrap().iter().filter(|i| i["level"] == "error").map(|i| i["path"].as_str().unwrap().to_string()).collect()
}

#[test]
fn the_payload_carries_schema_config_digest_issues_features_counts_prices_and_path() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    for (title, project) in [("One", "App"), ("Two", "App")] {
        let o = Command::new(env!("CARGO_BIN_EXE_qm")).args(["new", title, "--project", project]).env("QM_ROOT", &w.root).output().unwrap();
        assert!(o.status.success());
    }
    let payload = w.settings();
    assert_eq!(payload["schema"], quartermaster::config_schema::payload());
    assert_eq!(payload["config"]["projects"]["Plain"], json!({"root": w.plain.to_string_lossy()}), "a shorthand opens into its mapping");
    assert_eq!(payload["config"]["projects"]["App"]["dev_server"], json!({"command": "pf"}));
    assert_eq!(payload["config"]["my_notes"], json!({"keep": 1}), "keys the schema doesn't govern come along");
    assert_eq!(payload["digest"], digest(&text));
    assert_eq!(payload["issues"], json!([]));
    assert_eq!(payload["features"]["App"]["dev_server"]["state"], "on");
    assert_eq!(payload["features"]["Plain"]["ide"]["state"], "inherit");
    assert_eq!(payload["items"]["App"], 2);
    assert_eq!(payload["priceDefaults"]["claude-opus-5-5"], json!({"input": 4, "cache_write_5m": 5, "cache_write_1h": 8, "cache_read": 0.2, "output": 20}));
    assert_eq!(payload["path"], w.file().to_string_lossy().as_ref());
}

#[test]
fn an_unparsable_file_is_an_empty_form_with_its_error() {
    let w = world();
    w.write("projects: [unclosed\n");
    let payload = w.settings();
    assert_eq!(payload["config"], json!({}));
    assert_eq!(payload["issues"][0]["level"], "error");
    assert!(payload["issues"][0]["message"].as_str().unwrap().contains("not valid YAML"));
}

#[test]
fn check_answers_issues_and_features_for_a_draft_without_writing() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    let draft = json!({"projects": {"App": {"root": w.app.to_string_lossy(), "typo": 1, "benchmark": {"database": "x"}}}, "default_project": "Nope"});
    let a = w.post("/api/settings/check", json!({"config": draft}));
    assert_eq!(a.status, "200 OK");
    let answer = a.json();
    let errors = error_paths(&answer);
    assert!(errors.contains(&"projects.App.typo".to_string()) && errors.contains(&"default_project".to_string()), "{errors:?}");
    assert_eq!(answer["features"]["App"]["benchmarks"]["state"], "error");
    assert_eq!(w.read(), text);
}

#[test]
fn save_writes_the_draft_and_answers_the_new_payload_and_a_fresh_state() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    let loaded = w.settings();
    let mut draft = loaded["config"].clone();
    draft["projects"]["App"]["review_skill"] = json!("/review-app");
    draft["default_project"] = json!("App");
    let a = w.post("/api/settings/save", json!({"config": draft, "digest": loaded["digest"]}));
    assert_eq!(a.status, "200 OK", "{}", a.body);
    let answer = a.json();
    assert_eq!(answer["ok"], true);
    let written: Value = serde_yaml::from_str(&w.read()).unwrap();
    assert_eq!(written["projects"]["App"]["review_skill"], "/review-app");
    assert_eq!(written["projects"]["Plain"], w.plain.to_string_lossy().as_ref(), "a root-only project goes back to its shorthand");
    assert_eq!(written["my_notes"], json!({"keep": 1}));
    assert_eq!(fs::read_to_string(w.root.join("config.yml.bak")).unwrap(), text);
    assert_eq!(answer["settings"]["digest"], digest(&w.read()));
    assert_eq!(answer["state"]["defaultProject"], "App");
}

#[test]
fn save_rebuilds_the_state_so_a_new_dev_server_shows_at_once() {
    let w = world();
    w.write(&format!("projects:\n  App: {}\n", w.app.display()));
    let state = |w: &World| w.get("/api/state").json();
    assert!(state(&w)["pf"]["command"].is_null());
    let loaded = w.settings();
    let mut draft = loaded["config"].clone();
    draft["projects"]["App"]["dev_server"] = json!({"command": "pf"});
    let answer = w.post("/api/settings/save", json!({"config": draft, "digest": loaded["digest"]})).json();
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["state"]["pf"]["command"], "pf", "the save's answer is a build after the write");
    assert_eq!(state(&w)["pf"]["command"], "pf");
}

#[test]
fn save_over_a_file_changed_since_it_was_loaded_is_refused_as_stale_with_the_current_payload() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    let loaded = w.settings();
    let changed = format!("{text}default_project: Plain\n");
    w.write(&changed);
    let a = w.post("/api/settings/save", json!({"config": loaded["config"], "digest": loaded["digest"]}));
    assert_eq!(a.status, "409 Conflict");
    let answer = a.json();
    assert_eq!((answer["ok"].clone(), answer["stale"].clone()), (json!(false), json!(true)));
    assert_eq!(answer["settings"]["digest"], digest(&changed));
    assert_eq!(answer["settings"]["config"]["default_project"], "Plain");
    assert_eq!(w.read(), changed);
}

#[test]
fn save_with_errors_is_refused_and_writes_nothing() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    let loaded = w.settings();
    let mut draft = loaded["config"].clone();
    draft["projects"]["App"]["ide_command"] = json!(["code"]);
    let a = w.post("/api/settings/save", json!({"config": draft, "digest": loaded["digest"]}));
    assert_eq!(a.status, "422 Unprocessable Content");
    let answer = a.json();
    assert_eq!(answer["ok"], false);
    assert_eq!(error_paths(&answer), vec!["projects.App.ide_command"]);
    assert_eq!(w.read(), text);
    assert!(!w.root.join("config.yml.bak").exists());
}

#[test]
fn save_and_check_refuse_a_foreign_or_missing_origin() {
    let w = world();
    let text = w.app_config();
    w.write(&text);
    let loaded = w.settings();
    let body = json!({"config": {"projects": {}}, "digest": loaded["digest"]}).to_string();
    let port = w.server.port;
    let mut foreign = w.own_host();
    foreign.push(("Origin", "https://evil.example.com".into()));
    for route in ["/api/settings/save", "/api/settings/check"] {
        for headers in [&foreign, &w.own_host()] {
            assert_eq!(send(port, "POST", route, headers, &body).status, "403 Forbidden", "{route} {headers:?}");
        }
    }
    assert_eq!(w.read(), text);
    assert_eq!(send(port, "GET", "/api/settings", &[("Host", "evil.example.com".into())], "").status, "403 Forbidden");
}

/// The page and the assets the Settings view adds, as the server serves them.
fn served(w: &World, route: &str) -> String {
    let a = w.get(route);
    assert_eq!(a.status, "200 OK", "{route}");
    a.body
}

/// The page draws every field through SETTINGS_WIDGETS (settings-widgets.js), one entry per line; a schema
/// type without one would render as a text box.
#[test]
fn the_page_has_a_widget_for_every_schema_type() {
    let w = world();
    let script = served(&w, "/assets/js/settings-widgets.js");
    let table = regex::Regex::new(r"(?s)const SETTINGS_WIDGETS = \{\n(.*?)\n\};").unwrap().captures(&script).expect("settings-widgets.js declares SETTINGS_WIDGETS")[1].to_string();
    let mut widgets: Vec<String> = regex::Regex::new(r"(?m)^  (\w+):").unwrap().captures_iter(&table).map(|c| c[1].to_string()).collect();
    widgets.sort();
    let mut types: Vec<String> = quartermaster::config_schema::TYPES.iter().map(|t| t.to_string()).collect();
    types.sort();
    assert_eq!(widgets, types);
}

#[test]
fn settings_opens_from_the_header_cog_not_a_mode_tab() {
    let w = world();
    let page = served(&w, "/");
    let modes = regex::Regex::new(r#"(?s)<div class="segmented" id="modes".*?</div>"#).unwrap().find(&page).expect("the mode switcher").as_str();
    assert!(!modes.contains("settings"), "the mode switcher has no Settings tab");
    assert!(page.contains(r#"<button class="btn icon" id="settings-btn" aria-pressed="false" title="Settings (,)" aria-label="Settings">"#));
    assert!(page.contains("<kbd>,</kbd><span>settings</span>"));
    assert!(served(&w, "/assets/js/events.js").contains(r#"if (e.key === ",") { e.preventDefault(); toggleSettings(); return; }"#));
}

/// Page scripts are classic tags in load order: each Settings file after the ones it calls at load time,
/// events.js last, and every tag names a file the server serves.
#[test]
fn the_settings_scripts_load_in_order_and_before_events() {
    let w = world();
    let page = served(&w, "/");
    let scripts: Vec<String> = regex::Regex::new(r#"<script src="(/assets/js/[a-z0-9-]+\.js)"></script>"#).unwrap().captures_iter(&page).map(|c| c[1].to_string()).collect();
    let at = |name: &str| scripts.iter().position(|s| s == &format!("/assets/js/{name}.js")).unwrap_or_else(|| panic!("{name}.js has no script tag"));
    assert!(at("settings-widgets") < at("settings-render") && at("settings-render") < at("settings") && at("settings") < at("events"));
    assert_eq!(scripts.last().unwrap(), "/assets/js/events.js");
    for script in &scripts {
        served(&w, script);
    }
    assert!(page.contains(r#"<link rel="stylesheet" href="/assets/css/settings.css">"#));
    served(&w, "/assets/css/settings.css");
}
