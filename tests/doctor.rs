//! `qm doctor`: one line per check of qm's wiring and capture, writing nothing. The error count it shares
//! with the badge is tested in error_log.rs.

mod common;
use common::*;
use quartermaster::doctor::{Check, Doctor};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const RECORD_EVENTS: [&str; 6] = ["UserPromptSubmit", "PermissionRequest", "Stop", "StopFailure", "PostToolUseFailure", "PostToolUse"];

struct World {
    qm: Qm,
    dir: tempfile::TempDir,
    settings: PathBuf,
    launcher: PathBuf,
    record: PathBuf,
    _guard: std::sync::MutexGuard<'static, ()>,
}

fn world() -> World {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    let dir = tempfile::tempdir().unwrap();
    let (launcher, record) = (dir.path().join("bin/quartermaster"), dir.path().join("hooks/record-event.sh"));
    for path in [&launcher, &record] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "#!/bin/sh\n").unwrap();
    }
    let settings = dir.path().join("settings.json");
    std::env::set_var("QM_ROOT", qm.root.path());
    std::env::set_var("QM_CLAUDE_SETTINGS", &settings);
    std::env::set_var("QM_BIN", env!("CARGO_BIN_EXE_qm"));
    World { qm, dir, settings, launcher, record, _guard: guard }
}

fn command(cmd: &str) -> Value {
    json!([{"hooks": [{"type": "command", "command": cmd}]}])
}

impl World {
    fn write_settings(&self, overrides: &[(&str, Option<Value>)]) {
        let mut hooks = serde_json::Map::new();
        hooks.insert("SessionStart".into(), command(&format!("{} hook-session-start", self.launcher.display())));
        hooks.insert("SessionEnd".into(), command(&format!("{} hook-session-end", self.launcher.display())));
        for event in RECORD_EVENTS {
            hooks.insert(event.into(), command(&self.record.to_string_lossy()));
        }
        for (k, v) in overrides {
            match v {
                Some(v) => hooks.insert((*k).into(), v.clone()),
                None => hooks.remove(*k),
            };
        }
        fs::write(&self.settings, json!({"hooks": hooks}).to_string()).unwrap();
    }

    fn captured(&self, seconds_ago: i64) {
        let ts = (chrono::Local::now() - chrono::Duration::seconds(seconds_ago)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
        let line = json!({"v": 1, "event": "start", "session_id": "s1", "ts": ts});
        fs::write(self.qm.root.path().join("sessions.jsonl"), format!("{line}\n")).unwrap();
    }

    fn checks(&self) -> Vec<Check> {
        Doctor::new().checks()
    }

    fn check(&self, name: &str) -> Check {
        self.checks().into_iter().find(|c| c.name == name).unwrap_or_else(|| panic!("no check {name}"))
    }

    /// `qm doctor` as a child; the root may not exist, so the child runs from the test's own dir.
    fn cli(&self, root: &std::path::Path) -> Out {
        let o = std::process::Command::new(bin())
            .arg("doctor")
            .env("QM_ROOT", root)
            .env("QM_CLAUDE_SETTINGS", &self.settings)
            .env("QM_BIN", env!("CARGO_BIN_EXE_qm"))
            .env_remove("QM_SKIP")
            .current_dir(self.dir.path())
            .output()
            .unwrap();
        Out { stdout: String::from_utf8_lossy(&o.stdout).into_owned(), stderr: String::from_utf8_lossy(&o.stderr).into_owned(), code: o.status.code().unwrap_or(-1) }
    }
}

#[test]
fn a_healthy_setup_passes_every_check() {
    let w = world();
    w.write_settings(&[]);
    w.captured(60);
    let marks: Vec<(&str, &str)> = w.checks().iter().map(|c| (c.name, c.mark)).collect::<Vec<_>>().into_iter().collect();
    assert_eq!(marks, [("SessionStart hook", "✓"), ("SessionEnd hook", "✓"), ("record-event.sh hook", "✓"), ("qm binary", "✓"), ("Data root", "✓"), ("qm.log errors", "✓"), ("Capture", "✓")]);
}

#[test]
fn the_snippet_qm_install_hooks_prints_passes_every_hook_check() {
    let w = world();
    let out = w.qm.ok(&["install-hooks"]);
    fs::write(&w.settings, out.lines().filter(|l| !l.starts_with('#')).collect::<Vec<_>>().join("\n")).unwrap();
    let marks: Vec<&str> = ["SessionStart hook", "SessionEnd hook", "record-event.sh hook"].iter().map(|n| w.check(n).mark).collect();
    assert_eq!(marks, ["✓", "✓", "✓"]);
}

#[test]
fn a_missing_session_start_hook_fails_with_the_install_hint() {
    let w = world();
    w.write_settings(&[("SessionStart", None)]);
    let check = w.check("SessionStart hook");
    assert_eq!(check.mark, "✗");
    assert!(check.line().contains("qm install-hooks"));
    assert!(w.checks().iter().any(|c| c.mark == "✗"));
}

#[test]
fn a_hook_pointing_at_a_missing_file_fails() {
    let w = world();
    w.write_settings(&[("SessionEnd", Some(command("/nowhere/quartermaster hook-session-end")))]);
    let check = w.check("SessionEnd hook");
    assert_eq!(check.mark, "✗");
    assert!(check.line().contains("/nowhere/quartermaster"));
}

#[test]
fn record_event_missing_from_one_event_fails_naming_it() {
    let w = world();
    w.write_settings(&[("Stop", None)]);
    let check = w.check("record-event.sh hook");
    assert_eq!(check.mark, "✗");
    assert!(check.line().contains("Stop"));
}

#[test]
fn unreadable_settings_fail_every_hook_check() {
    let w = world();
    fs::write(&w.settings, "{ not json").unwrap();
    let marks: Vec<&str> = ["SessionStart hook", "SessionEnd hook", "record-event.sh hook"].iter().map(|n| w.check(n).mark).collect();
    assert_eq!(marks, ["✗", "✗", "✗"]);
}

#[test]
fn a_launcher_without_a_built_binary_fails() {
    let w = world();
    w.write_settings(&[]);
    std::env::set_var("QM_BIN", w.dir.path().join("no-such-qm"));
    let check = w.check("qm binary");
    assert_eq!(check.mark, "✗");
    assert!(check.line().contains("cargo build --release"));
    // without QM_BIN the binary is the one beside the launcher the hook runs
    std::env::remove_var("QM_BIN");
    assert!(w.check("qm binary").detail.contains("bin/target/release/qm"));
    std::env::set_var("QM_BIN", env!("CARGO_BIN_EXE_qm"));
}

#[test]
fn an_unwritable_root_fails() {
    use std::os::unix::fs::PermissionsExt;
    let w = world();
    fs::set_permissions(w.qm.root.path(), fs::Permissions::from_mode(0o500)).unwrap();
    let mark = w.check("Data root").mark;
    fs::set_permissions(w.qm.root.path(), fs::Permissions::from_mode(0o700)).unwrap();
    // root can write anywhere: only a regular user sees the failure
    if unsafe { libc::geteuid() } != 0 {
        assert_eq!(mark, "✗");
    }
}

#[test]
fn errors_since_the_marker_warn_with_the_last_one() {
    let w = world();
    let ts = (chrono::Local::now() - chrono::Duration::seconds(60)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
    fs::write(w.qm.root.path().join("qm.log"), format!("{ts} [gui] RuntimeError: boom\n")).unwrap();
    let check = w.check("qm.log errors");
    assert_eq!(check.mark, "!");
    assert!(regex::Regex::new(r"1 error.*RuntimeError: boom").unwrap().is_match(&check.line()), "{}", check.line());
}

#[test]
fn nothing_captured_in_a_day_warns() {
    let w = world();
    w.captured(2 * 24 * 3600);
    let check = w.check("Capture");
    assert_eq!(check.mark, "!");
    assert!(check.line().contains("cargo build --release"));
}

#[test]
fn a_recent_tool_call_event_counts_as_capture() {
    let w = world();
    w.captured(2 * 24 * 3600);
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    fs::write(w.qm.root.path().join("events.jsonl"), format!("{}\n", json!({"v": 1, "ts": ts, "session_id": "s1", "event": "Stop"}))).unwrap();
    assert_eq!(w.check("Capture").mark, "✓");
}

#[test]
fn doctor_writes_nothing() {
    let w = world();
    w.write_settings(&[]);
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    fs::write(w.qm.root.path().join("events.jsonl"), format!("{}\n", json!({"v": 1, "ts": ts, "session_id": "s1", "event": "Stop"}))).unwrap();
    let names = || {
        let mut n: Vec<String> = fs::read_dir(w.qm.root.path()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        n.sort();
        n
    };
    let before = names();
    w.checks();
    assert_eq!(names(), before);
}

#[test]
fn qm_doctor_on_a_missing_root_fails_and_leaves_it_missing() {
    let w = world();
    w.write_settings(&[]);
    let root = w.dir.path().join("no-root");
    let out = w.cli(&root);
    assert_eq!(out.code, 1, "{}", out.stderr);
    assert!(out.stdout.lines().any(|l| l.starts_with(&format!("✗ Data root: {} is missing", root.display()))), "{}", out.stdout);
    assert!(!root.exists(), "doctor records no feature use and creates nothing");
}

#[test]
fn qm_doctor_prints_a_line_per_check_and_exits_one_on_a_failure() {
    let w = world();
    // no settings written: every hook check fails
    let out = w.cli(w.qm.root.path());
    assert_eq!(out.code, 1);
    assert_eq!(out.stdout.lines().count(), 7);
    assert!(out.stdout.lines().all(|l| l.starts_with("✓ ") || l.starts_with("✗ ") || l.starts_with("! ")), "{}", out.stdout);
    assert!(out.stdout.contains(&format!("can't read {}", w.settings.display())));
    // a healthy run exits 0
    w.write_settings(&[]);
    w.captured(60);
    let out = w.cli(w.qm.root.path());
    assert_eq!(out.code, 0, "{}", out.stdout);
}

#[test]
fn qm_doctor_is_never_a_feature_use_so_it_cannot_count_as_unused() {
    let w = world();
    w.write_settings(&[]);
    w.cli(w.qm.root.path());
    assert!(!w.qm.root.path().join("feature-use.jsonl").exists());
    let report = w.qm.ok(&["feature-use"]);
    assert!(!report.contains("doctor"), "{report}");
}
