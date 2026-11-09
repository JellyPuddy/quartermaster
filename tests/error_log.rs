//! The unseen errors in qm.log: `ErrorLog` (the GUI badge's count and Mark seen) and the status line's
//! `⚠ N qm errors`, which must never break the line.

mod common;
use chrono::{DateTime, Duration, FixedOffset, TimeZone};
use common::*;
use quartermaster::error_log::ErrorLog;
use serde_json::json;
use std::fs;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn now() -> DateTime<FixedOffset> {
    chrono::Utc.with_ymd_and_hms(2026, 11, 6, 12, 0, 0).unwrap().fixed_offset()
}

fn at(hours_ago: i64) -> String {
    (now() - Duration::hours(hours_ago)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

struct World {
    qm: Qm,
    _guard: std::sync::MutexGuard<'static, ()>,
}

fn world() -> World {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    std::env::set_var("QM_ROOT", qm.root.path());
    World { qm, _guard: guard }
}

impl World {
    fn log(&self) -> std::path::PathBuf {
        self.qm.root.path().join("qm.log")
    }
    fn seen(&self) -> std::path::PathBuf {
        self.qm.root.path().join("errors-seen-at")
    }
    fn write_log(&self, text: &str) {
        fs::write(self.log(), text).unwrap();
    }
    fn error_log(&self) -> ErrorLog {
        ErrorLog::new().at(now())
    }
}

#[test]
fn counts_errors_of_the_last_day_without_a_seen_marker() {
    let w = world();
    w.write_log(&format!(
        "{} [gui-client] TypeError: too old\n{} [gh-stack-sync] TypeError: no implicit conversion of Hash into String\n  src/gh_stack.rs:12\n  src/gui.rs:40\n{} [pr-inbox] transient RuntimeError: gh: error connecting to api.github.com\n{} [pr-inbox] recovered after 7 failures\n{} [hook-session-start] Errno::ENOENT: No such file or directory\n",
        at(30), at(5), at(4), at(3), at(1)
    ));
    let summary = w.error_log().summary();
    assert_eq!(summary["count"], 2);
    // newest first
    let (second, first) = (&summary["entries"][0], &summary["entries"][1]);
    assert_eq!(first["lines"], json!([format!("{} [gh-stack-sync] TypeError: no implicit conversion of Hash into String", at(5)), "  src/gh_stack.rs:12", "  src/gui.rs:40"]));
    assert_eq!(first["context"], "gh-stack-sync");
    assert_eq!(first["at"], at(5));
    assert_eq!(second["lines"], json!([format!("{} [hook-session-start] Errno::ENOENT: No such file or directory", at(1))]));
}

#[test]
fn counts_only_errors_after_the_seen_marker() {
    let w = world();
    fs::write(w.seen(), format!("{}\n", at(2))).unwrap();
    w.write_log(&format!("{} [gui-client] TypeError: seen already\n{} [gui-client] TypeError: new one\n", at(3), at(1)));
    let summary = w.error_log().summary();
    assert_eq!(summary["count"], 1);
    assert_eq!(summary["entries"][0]["lines"][0], format!("{} [gui-client] TypeError: new one", at(1)));
}

#[test]
fn an_unreadable_seen_marker_falls_back_to_the_last_day() {
    let w = world();
    fs::write(w.seen(), "garbage").unwrap();
    w.write_log(&format!("{} [x] RuntimeError: old\n{} [x] RuntimeError: new\n", at(30), at(1)));
    assert_eq!(w.error_log().count(), 1);
}

#[test]
fn mark_seen_writes_now_and_clears_the_count() {
    let w = world();
    w.write_log(&format!("{} [x] RuntimeError: boom\n", at(1)));
    w.error_log().mark_seen().unwrap();
    assert_eq!(fs::read_to_string(w.seen()).unwrap().trim(), "2026-11-06T12:00:00+00:00");
    assert_eq!(w.error_log().count(), 0);
    assert_eq!(ErrorLog::new().at(now() + Duration::hours(1)).count(), 0);
}

#[test]
fn no_log_and_an_unreadable_log_both_mean_no_errors() {
    let w = world();
    assert_eq!(w.error_log().summary(), json!({"count": 0, "entries": []}));
    fs::create_dir_all(w.log()).unwrap(); // a directory where the log goes
    assert_eq!(w.error_log().summary(), json!({"count": 0, "entries": []}));
}

#[test]
fn reads_only_the_tail_and_skips_a_cut_entry() {
    let w = world();
    let late = format!("{} [y] RuntimeError: late\n  src/y.rs:1\n", at(1));
    w.write_log(&format!("{}{late}", format!("{} [x] RuntimeError: early\n", at(2)).repeat(50)));
    let log = w.error_log().with_tail_bytes(late.len() as u64 + 10);
    assert_eq!(log.count(), 1);
    assert_eq!(log.summary()["entries"][0]["context"], "y");
}

#[test]
fn an_orphaned_continuation_at_the_tail_start_is_dropped() {
    let w = world();
    let rest = format!("  src/x.rs:1\n{} [z] RuntimeError: kept\n", at(1));
    w.write_log(&format!("{} [x] RuntimeError: cut\n{rest}", at(1)));
    let log = w.error_log().with_tail_bytes(rest.len() as u64 + 3);
    let summary = log.summary();
    assert_eq!(summary["count"], 1);
    assert_eq!(summary["entries"][0]["context"], "z");
}

#[test]
fn the_summary_lists_the_newest_twenty_newest_first() {
    let w = world();
    let text: String = (1..=25).map(|i| format!("{} [c{i}] RuntimeError: e{i}\n", (now() - Duration::hours(1) + Duration::seconds(i)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false))).collect();
    w.write_log(&text);
    let summary = w.error_log().summary();
    assert_eq!(summary["count"], 25);
    assert_eq!(summary["entries"].as_array().unwrap().len(), 20);
    assert_eq!(summary["entries"][0]["context"], "c25");
    assert_eq!(summary["entries"][19]["context"], "c6");
}

#[test]
fn the_gui_action_marks_seen_and_replies_with_the_cleared_badge() {
    let w = world();
    let recent = (chrono::Local::now() - Duration::seconds(60)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
    w.write_log(&format!("{recent} [gui-client] TypeError: boom\n"));
    let reply = quartermaster::gui_actions::dispatch(&json!({"cmd": "errors-seen"})).expect("ported");
    assert_eq!(reply, json!({"ok": true, "errors": {"count": 0, "entries": []}}));
    let marked = chrono::DateTime::parse_from_rfc3339(fs::read_to_string(w.seen()).unwrap().trim()).unwrap();
    assert!((marked.timestamp() - chrono::Utc::now().timestamp()).abs() < 5);
}

#[test]
fn mark_seen_is_not_a_local_action_so_an_origin_less_post_is_refused() {
    let server = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/gui_server.rs")).unwrap();
    let local = server.lines().find(|l| l.starts_with("const LOCAL_ACTIONS")).unwrap();
    assert!(!local.contains("errors-seen"));
}

#[test]
fn the_page_has_the_badge_its_script_in_load_order_and_the_state_carries_it() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let page = fs::read_to_string(root.join("gui/page.html")).unwrap();
    assert!(page.contains("id=\"errors-badge\""));
    let tag = |name: &str| page.find(&format!("/assets/js/{name}.js")).unwrap_or_else(|| panic!("no tag for {name}"));
    assert!(tag("limits") < tag("errors") && tag("errors") < tag("events"));
    assert!(fs::read_to_string(root.join("gui/js/errors.js")).unwrap().contains("act(\"errors-seen\")"));
    assert!(fs::read_to_string(root.join("gui/js/board.js")).unwrap().contains("renderErrorBadge()"));
    assert!(fs::read_to_string(root.join("gui/js/server.js")).unwrap().contains("qmErrors = st.errors"));
    assert!(fs::read_to_string(root.join("src/gui_state.rs")).unwrap().contains("(\"errors\", crate::error_log::ErrorLog::new().summary())"));
}

fn statusline(w: &World, env: &[(&str, &str)]) -> String {
    std::env::set_var("QM_BIN", env!("CARGO_BIN_EXE_qm"));
    let cwd = tempfile::tempdir().unwrap();
    let input = json!({"session_id": "s-1", "workspace": {"current_dir": cwd.path()}, "model": {"display_name": "Opus"}, "context_window": {"used_percentage": 31.4}, "rate_limits": {"five_hour": {"used_percentage": 42.2, "resets_at": chrono::Utc::now().timestamp() + 8100}}});
    let mut all = vec![("COLUMNS", "160"), ("TERM", "dumb"), ("TMUX", ""), ("QM_TMUX_SOCKET", "")];
    all.extend_from_slice(env);
    let o = w.qm.run_with(&["statusline"], &input.to_string(), &all);
    assert_eq!(o.code, 0, "{}", o.stderr);
    strip_ansi(&o.stdout)
}

fn ago(seconds: i64) -> String {
    (chrono::Local::now() - Duration::seconds(seconds)).to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

#[test]
fn the_status_line_counts_unseen_qm_errors_of_the_last_day() {
    let w = world();
    w.write_log(&format!(
        "{} [gui-client] TypeError: too old\n{} [gh-stack-sync] TypeError: no implicit conversion\n  src/gh_stack.rs:12\n{} [pr-inbox] transient RuntimeError: gh: error connecting to api.github.com\n{} [pr-inbox] recovered after 3 failures\n{} [hook-session-start] Errno::ENOENT: No such file\n",
        ago(30 * 3600), ago(600), ago(500), ago(400), ago(300)
    ));
    let out = statusline(&w, &[]);
    assert!(out.lines().next().unwrap().contains("⚠ 2 qm errors"), "{out}");
    assert!(regex::Regex::new(r"5h \[.*\] 42%").unwrap().is_match(&out), "{out}");
}

#[test]
fn errors_before_the_seen_marker_drop_the_segment() {
    let w = world();
    w.write_log(&format!("{} [x] RuntimeError: seen\n", ago(600)));
    fs::write(w.seen(), ago(60)).unwrap();
    assert!(!statusline(&w, &[]).contains("qm error"));
}

#[test]
fn one_error_is_singular_and_a_qm_chat_leaves_it_to_the_gui() {
    let w = world();
    w.write_log(&format!("{} [x] RuntimeError: boom\n", ago(60)));
    let out = statusline(&w, &[]);
    assert!(out.contains("⚠ 1 qm error") && !out.contains("qm errors"), "{out}");
    assert!(!statusline(&w, &[("TMUX", "/private/tmp/tmux-501/qm,4242,3")]).contains("qm error"));
}

#[test]
fn an_unreadable_log_never_breaks_the_status_line() {
    let w = world();
    fs::create_dir_all(w.log()).unwrap(); // a directory where the log goes
    fs::write(w.seen(), "garbage").unwrap();
    let out = statusline(&w, &[]);
    assert!(!out.contains("qm error"), "{out}");
    assert!(regex::Regex::new(r"5h \[.*\] 42%").unwrap().is_match(&out), "{out}");
}

#[test]
fn the_status_line_creates_no_data_dir_for_the_error_check() {
    let w = world();
    let missing = w.qm.root.path().join("no-such-root");
    let _ = statusline(&w, &[("QM_ROOT", missing.to_str().unwrap())]);
    assert!(!missing.exists());
}
