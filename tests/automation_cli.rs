//! `qm automation …` for cloud routines, end to end: a stand-in `security` hands out a login, a stand-in `curl`
//! answers each request from a file named for its method and path and logs the config it was given. No test
//! reaches the keychain or the network.

mod common;
use common::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

const GET: &str = include_str!("fixtures/routine-get-response.json");
const LIST: &str = include_str!("fixtures/routines-list-response.json");
const TOKEN: &str = "sk-ant-oat01-SECRET-TOKEN";
const ID: &str = "trig_01AAAAAAAAAAAAAAAAAAAAAAAA";

struct World {
    qm: Qm,
    dir: tempfile::TempDir,
}

fn script(path: &PathBuf, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

impl World {
    fn new() -> World {
        let w = World { qm: Qm::new(), dir: tempfile::tempdir().unwrap() };
        for sub in ["bin", "answers", "home"] {
            fs::create_dir_all(w.dir.path().join(sub)).unwrap();
        }
        script(&w.dir.path().join("bin/curl"), "#!/bin/sh\ncfg=$(cat)\nprintf '%s\\n%s\\n---\\n' \"$*\" \"$cfg\" >> \"$FAKE_DIR/curl.log\"\nurl=$(printf '%s\\n' \"$cfg\" | sed -n 's/^url = \"\\(.*\\)\"$/\\1/p')\nmethod=$(printf '%s\\n' \"$cfg\" | sed -n 's/^request = \"\\(.*\\)\"$/\\1/p')\nkey=$(printf '%s %s' \"$method\" \"${url#https://api.anthropic.com}\" | tr -c 'A-Za-z0-9' '_')\n[ -f \"$FAKE_DIR/answers/$key\" ] && { cat \"$FAKE_DIR/answers/$key\"; exit 0; }\nprintf '{}\\n404'\n");
        script(&w.dir.path().join("bin/security"), "#!/bin/sh\necho x >> \"$FAKE_DIR/security.log\"\ncat \"$FAKE_DIR/credentials\"\n");
        fs::write(w.dir.path().join("credentials"), format!(r#"{{"claudeAiOauth":{{"accessToken":"{TOKEN}","expiresAt":{}}}}}"#, (chrono::Utc::now().timestamp() + 3600) * 1000)).unwrap();
        fs::write(w.dir.path().join("home/.claude.json"), r#"{"oauthAccount":{"organizationUuid":"org-1"}}"#).unwrap();
        w
    }

    fn answer(&self, method: &str, path: &str, status: u16, body: &str) {
        let key: String = format!("{method} {path}").chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
        fs::write(self.dir.path().join("answers").join(key), format!("{body}\n{status}")).unwrap();
    }

    fn on(&self) {
        self.qm.ok(&["config", "set", "automations.token_source", "claude_code"]);
    }

    fn run(&self, args: &[&str], stdin: &str) -> Out {
        let base = self.dir.path().to_string_lossy().to_string();
        let path = format!("{base}/bin:{}", std::env::var("PATH").unwrap());
        let home = format!("{base}/home");
        self.qm.run_with(args, stdin, &[("PATH", &path), ("HOME", &home), ("FAKE_DIR", &base)])
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args, "");
        assert_eq!(out.code, 0, "{args:?}: {}{}", out.stdout, out.stderr);
        out.stdout
    }

    fn log(&self, name: &str) -> String {
        fs::read_to_string(self.dir.path().join(name)).unwrap_or_default()
    }

    fn adopt(&self) {
        self.on();
        self.answer("GET", &format!("/v1/code/triggers/{ID}"), 200, GET);
        self.ok(&["automation", "adopt", ID, "--project", "MyApp", "--slug", "digest"]);
    }
}

#[test]
fn off_by_default_nothing_reads_the_keychain_and_the_command_says_how_to_turn_it_on() {
    let w = World::new();
    let out = w.run(&["automation", "list"], "");
    assert_eq!(out.code, 1);
    assert!(out.stdout.contains("no automations yet"), "{}", out.stdout);
    assert!(out.stderr.contains("qm config set automations.token_source claude_code"), "{}", out.stderr);
    assert_eq!((w.log("security.log"), w.log("curl.log")), (String::new(), String::new()));
}

#[test]
fn adopt_show_and_list_go_through_curl_and_the_token_never_leaves_its_stdin() {
    let w = World::new();
    w.adopt();
    assert!(w.log("curl.log").contains(&format!("Authorization: Bearer {TOKEN}")));
    for (n, call) in w.log("curl.log").split("---\n").filter(|c| !c.is_empty()).enumerate() {
        assert_eq!(call.lines().next().unwrap(), "-K -", "call {n}: the arguments are only -K -");
    }
    w.answer("GET", "/v1/code/sessions?trigger_id=trig_01AAAAAAAAAAAAAAAAAAAAAAAA&limit=10", 200, r#"{"data":[{"id":"cse_1","title":"Digest run","status":"completed","created_at":"2026-11-05T07:10:10Z"}]}"#);
    let shown = w.ok(&["automation", "show", "digest"]);
    for part in ["Shipped digest (DM)", "schedule: Mon, Thu", "(0 7 * * 1,4 UTC)", "repos: https://github.com/example-org/example-app", "connectors: Slack", &format!("routine: https://claude.ai/code/routines/{ID}"), "completed  2026-11-05 07:10 UTC  Digest run  https://claude.ai/code/cse_1"] {
        assert!(shown.contains(part), "{part}\n{shown}");
    }
    w.answer("GET", "/v1/code/triggers", 200, LIST);
    let listed = w.ok(&["automation", "list"]);
    assert!(regex::Regex::new(r"(?m)^digest  MyApp  active  Mon, Thu (08|09):00  enabled  cloud$").unwrap().is_match(&listed), "{listed}");
    assert!(listed.contains("digest: last run succeeded 2026-11-05 07:10 UTC, next 2026-11-09 07:06 UTC"), "{listed}");
    let everything = format!("{shown}{listed}{}{}", w.qm.read("qm.log"), w.log("curl.log").replace(&format!("Bearer {TOKEN}"), ""));
    assert!(!everything.contains(TOKEN));
}

#[test]
fn push_with_nothing_changed_says_so_and_writes_no_note() {
    let w = World::new();
    w.adopt();
    assert_eq!(w.ok(&["automation", "push", "digest"]), "digest: nothing to push\n");
    assert!(!w.qm.read("work-items/digest.md").contains("pushed:"));
}

#[test]
fn run_prints_the_routines_link_and_delete_asks_first() {
    let w = World::new();
    w.adopt();
    w.answer("POST", &format!("/v1/code/triggers/{ID}/run"), 200, r#"{"session_id":"cse_RUN"}"#);
    assert_eq!(w.ok(&["automation", "run", "digest"]), format!("digest: running — https://claude.ai/code/routines/{ID}\n"));
    let refused = w.run(&["automation", "delete", "digest"], "n\n");
    assert_eq!(refused.code, 1);
    assert!(refused.stderr.contains("Delete Shipped digest (DM) on claude.ai and resolve digest? [y/N] ") && refused.stderr.contains("qm automation: not deleted"), "{}", refused.stderr);
    w.answer("DELETE", &format!("/v1/code/triggers/{ID}"), 200, "{}");
    assert_eq!(w.run(&["automation", "delete", "digest", "--yes"], "").stdout, "digest: deleted\n");
    assert!(w.qm.read("work-items/digest.md").contains("state: resolved"));
}

#[test]
fn client_errors_print_their_message_and_exit_non_zero() {
    let w = World::new();
    w.adopt();
    w.answer("GET", &format!("/v1/code/triggers/{ID}"), 401, "{}");
    let out = w.run(&["automation", "push", "digest"], "");
    assert_eq!(out.code, 1);
    assert!(out.stderr.contains("qm: Claude Code's login token expired"), "{}", out.stderr);
    w.answer("GET", &format!("/v1/code/triggers/{ID}"), 404, "{}");
    assert!(w.run(&["automation", "push", "digest"], "").stderr.contains("isn't on claude.ai any more"));
}

#[test]
fn unknown_subcommands_and_stray_words_print_the_usage_and_do_nothing() {
    let w = World::new();
    w.adopt();
    let bad = w.run(&["automation", "frobnicate"], "");
    assert_eq!(bad.code, 1);
    assert!(bad.stderr.contains("usage: qm automation"));
    let stray = w.run(&["automation", "delete", "digest", "extra", "--yes"], "");
    assert!(stray.code == 1 && stray.stderr.contains("usage: qm automation"));
    assert!(w.qm.read("work-items/digest.md").contains("state: active"));
    assert!(w.run(&["automation"], "").stderr.contains("usage: qm automation"));
}
