//! Black-box characterization of the `qm` executable.
//!
//! The suite drives whichever executable `QM_BIN` names (default: the Ruby
//! launcher `./quartermaster`) against a throwaway `QM_ROOT`, so the same
//! assertions pin the Ruby behavior today and the Rust port tomorrow.

use regex::Regex;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::TempDir;

struct Qm {
    root: TempDir,
}

struct Out {
    stdout: String,
    stderr: String,
    code: i32,
}

fn bin() -> PathBuf {
    match std::env::var("QM_BIN") {
        Ok(p) => PathBuf::from(p),
        Err(_) => Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster"),
    }
}

/// Dates, timestamps and pids vary per run; everything else is compared verbatim.
fn normalize(s: &str) -> String {
    let ts = Regex::new(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:\d{2})?").unwrap();
    let date = Regex::new(r"\d{4}-\d{2}-\d{2}").unwrap();
    let pid = Regex::new(r#""pid":\d+"#).unwrap();
    let dur = Regex::new(r#""duration_s":\d+"#).unwrap();
    let s = ts.replace_all(s, "TS");
    let s = date.replace_all(&s, "DATE");
    let s = pid.replace_all(&s, r#""pid":PID"#);
    dur.replace_all(&s, r#""duration_s":N"#).into_owned()
}

impl Qm {
    fn new() -> Self {
        Qm { root: tempfile::tempdir().unwrap() }
    }

    fn run_with(&self, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> Out {
        let mut cmd = Command::new(bin());
        cmd.args(args)
            .env("QM_ROOT", self.root.path())
            .env("LANG", "C.UTF-8")
            .env("LC_ALL", "C.UTF-8")
            .env("QM_TMUX_SOCKET", "qm-test-characterization")
            .env_remove("QM_SKIP")
            .env_remove("QM_ASIDE")
            .env_remove("QM_LOOSE")
            .env_remove("QM_ITEM")
            .current_dir(self.root.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().expect("spawn qm");
        child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
        let o = child.wait_with_output().unwrap();
        Out {
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
            code: o.status.code().unwrap_or(-1),
        }
    }

    fn run(&self, args: &[&str]) -> Out {
        self.run_with(args, "", &[])
    }

    fn ok(&self, args: &[&str]) -> String {
        let o = self.run(args);
        assert_eq!(o.code, 0, "qm {args:?} failed: {}", o.stderr);
        o.stdout
    }

    fn read(&self, rel: &str) -> String {
        normalize(&std::fs::read_to_string(self.root.path().join(rel)).unwrap_or_default())
    }

    fn exists(&self, rel: &str) -> bool {
        self.root.path().join(rel).exists()
    }
}

fn strip_ansi(s: &str) -> String {
    Regex::new("\x1b\\[[0-9;]*m").unwrap().replace_all(s, "").into_owned()
}

// ---------------------------------------------------------------- work items

#[test]
fn new_prints_the_slug_and_writes_a_versioned_item() {
    let qm = Qm::new();
    assert_eq!(qm.ok(&["new", "Fix login bug", "--description", "desc here"]), "fix-login-bug\n");
    assert_eq!(
        qm.read("work-items/fix-login-bug.md"),
        "---\nv: 1\ntitle: Fix login bug\nstate: in_progress\nproject: No project\ncreated: 'DATE'\n---\n\n## Description\n\ndesc here\n\n## Notes\n\n## Snapshots\n"
    );
}

#[test]
fn new_seeds_the_data_root() {
    let qm = Qm::new();
    qm.ok(&["new", "Seed"]);
    assert!(qm.exists("config.yml"));
    assert!(qm.exists("work-items"));
}

#[test]
fn new_with_session_project_and_branch_records_them() {
    let qm = Qm::new();
    qm.ok(&["new", "Linked", "--project", "demo", "--session", "s9", "--branch", "feat/x"]);
    let item = qm.read("work-items/linked.md");
    assert!(item.contains("project: demo"), "{item}");
    assert!(item.contains("- id: s9"), "{item}");
    assert!(item.contains("feat/x"), "{item}");
}

#[test]
fn a_repeated_title_is_refused() {
    let qm = Qm::new();
    assert_eq!(qm.ok(&["new", "Same"]), "same\n");
    let again = qm.run(&["new", "Same"]);
    assert_eq!((again.code, again.stdout.as_str()), (1, ""));
    assert_eq!(again.stderr, "qm: work item 'same' already exists\n");
}

#[test]
fn note_appends_with_a_kind_and_prints_the_numbered_notes() {
    let qm = Qm::new();
    qm.ok(&["new", "Fix login bug"]);
    qm.ok(&["note", "fix-login-bug", "first note", "--kind", "decision"]);
    let out = qm.ok(&["note", "fix-login-bug", "hist", "--kind", "history"]);
    assert_eq!(normalize(&strip_ansi(&out)), "#2 [history] DATE: hist\n");
    let item = qm.read("work-items/fix-login-bug.md");
    assert!(item.contains("- DATE: first note\n- DATE [history]: hist\n"), "{item}");
}

#[test]
fn retag_changes_a_notes_kind() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    qm.ok(&["note", "t", "n"]);
    qm.ok(&["retag", "t", "1", "open"]);
    assert!(qm.read("work-items/t.md").contains("[open]"));
}

#[test]
fn state_changes_and_rejects_unknown_states() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    qm.ok(&["state", "t", "fridge"]);
    assert!(qm.read("work-items/t.md").contains("state: fridge"));
    let bad = qm.run(&["state", "t", "bogus"]);
    assert_eq!(bad.code, 1);
    assert_eq!(bad.stderr, "qm: state must be one of: in_progress, fridge, resolved\n");
}

#[test]
fn unknown_slug_is_an_error_not_a_backtrace() {
    let qm = Qm::new();
    let o = qm.run(&["show", "nope"]);
    assert_eq!(o.code, 1);
    assert_eq!(o.stderr, "qm: no work item 'nope'\n");
    assert_eq!(o.stdout, "");
}

#[test]
fn retitle_keeps_the_slug_and_move_changes_the_project() {
    let qm = Qm::new();
    qm.ok(&["new", "Fix login bug"]);
    assert_eq!(qm.ok(&["retitle", "fix-login-bug", "Fix login"]), "fix-login-bug: Fix login\n");
    qm.ok(&["move", "fix-login-bug", "other"]);
    let item = qm.read("work-items/fix-login-bug.md");
    assert!(item.contains("title: Fix login\n") && item.contains("project: other\n"), "{item}");
}

#[test]
fn describe_replaces_the_description_and_reads_stdin() {
    let qm = Qm::new();
    qm.ok(&["new", "T", "--description", "old"]);
    qm.run_with(&["describe", "t", "-"], "from stdin\n", &[]);
    let item = qm.read("work-items/t.md");
    assert!(item.contains("## Description\n\nfrom stdin\n"), "{item}");
    assert!(!item.contains("old"), "{item}");
}

#[test]
fn attach_moves_a_session_between_items_and_detach_unlinks_it() {
    let qm = Qm::new();
    qm.ok(&["new", "A", "--session", "s1"]);
    qm.ok(&["new", "B"]);
    qm.ok(&["attach", "b", "--session", "s1"]);
    assert!(qm.read("work-items/a.md").contains("sessions: []"));
    assert!(qm.read("work-items/b.md").contains("- id: s1"));
    qm.ok(&["detach", "b", "--session", "s1"]);
    assert!(qm.read("work-items/b.md").contains("sessions: []"));
}

#[test]
fn link_and_unlink_branch() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    qm.ok(&["link-branch", "t", "feat/a"]);
    assert!(qm.read("work-items/t.md").contains("feat/a"));
    qm.ok(&["unlink-branch", "t", "feat/a"]);
    assert!(!qm.read("work-items/t.md").contains("feat/a"));
}

#[test]
fn board_prints_only_the_url_and_fails_when_unset() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    let unset = qm.run(&["board", "t"]);
    assert_ne!(unset.code, 0);
    assert_eq!(unset.stdout, "");
    qm.ok(&["board", "t", "https://example.test/board"]);
    assert_eq!(qm.ok(&["board", "t"]), "https://example.test/board\n");
    qm.ok(&["board", "t", "clear"]);
    assert_ne!(qm.run(&["board", "t"]).code, 0);
}

#[test]
fn list_is_a_table_of_state_project_slug_and_counts() {
    let qm = Qm::new();
    qm.ok(&["new", "Fix login bug"]);
    qm.ok(&["note", "fix-login-bug", "n"]);
    qm.ok(&["state", "fix-login-bug", "fridge"]);
    qm.ok(&["attach", "fix-login-bug", "--session", "s1"]);
    assert_eq!(qm.ok(&["list"]), "fridge  No project  fix-login-bug  1  -\n");
}

#[test]
fn show_prints_title_notes_sessions_usage_and_the_item_body() {
    let qm = Qm::new();
    qm.ok(&["new", "Fix login", "--description", "desc here"]);
    qm.ok(&["note", "fix-login", "first note"]);
    qm.ok(&["attach", "fix-login", "--session", "s1"]);
    let out = normalize(&strip_ansi(&qm.ok(&["show", "fix-login"])));
    assert!(out.starts_with("Fix login\nin_progress · No project · created DATE\n#1 [decision] DATE: first note\n"), "{out}");
    assert!(out.contains("Sessions\ns1 ? uncaptured"), "{out}");
    assert!(out.contains("## Description\n\ndesc here\n"), "{out}");
}

// ------------------------------------------------------------- capture hooks

fn start_payload(id: &str) -> String {
    format!(r#"{{"session_id":"{id}","cwd":"/tmp","source":"startup","transcript_path":"/nonexistent/x.jsonl"}}"#)
}

#[test]
fn session_start_logs_an_event_and_prints_the_linking_protocol() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    let o = qm.run_with(&["hook-session-start"], &start_payload("abc"), &[]);
    assert_eq!(o.code, 0);
    assert!(o.stdout.starts_with("[qm] This Claude Code session (abc) is not linked to a work item. Project baseline from cwd: No project.\n\nOpen work items:\n- t — T (No project, in_progress)\n"), "{}", o.stdout);
    assert!(o.stdout.contains("qm attach <slug> --session abc"));
    let log = qm.read("sessions.jsonl");
    assert_eq!(
        log,
        "{\"v\":1,\"event\":\"start\",\"session_id\":\"abc\",\"source\":\"startup\",\"cwd\":\"/tmp\",\"transcript_path\":\"/nonexistent/x.jsonl\",\"branch\":null,\"head\":null,\"pid\":PID,\"project\":\"No project\",\"work_item\":null,\"ts\":\"TS\"}\n"
    );
}

#[test]
fn session_start_with_qm_item_attaches_the_session() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    let o = qm.run_with(&["hook-session-start"], &start_payload("abc"), &[("QM_ITEM", "t")]);
    assert_eq!(o.code, 0);
    assert!(qm.read("work-items/t.md").contains("- id: abc"));
    assert!(qm.read("sessions.jsonl").contains("\"work_item\":\"t\""));
}

#[test]
fn an_aside_is_logged_but_never_attached() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    let o = qm.run_with(&["hook-session-start"], &start_payload("as1"), &[("QM_ASIDE", "t"), ("QM_ITEM", "t")]);
    assert_eq!(o.code, 0);
    assert!(o.stdout.contains("is an aside about work item 't'"), "{}", o.stdout);
    assert!(!qm.read("work-items/t.md").contains("as1"));
    assert!(qm.read("sessions.jsonl").contains("\"aside\":\"t\""));
}

#[test]
fn a_loose_chat_is_logged_with_its_id_and_told_not_to_link() {
    let qm = Qm::new();
    let o = qm.run_with(&["hook-session-start"], &start_payload("l1"), &[("QM_LOOSE", "abc123")]);
    assert_eq!(o.code, 0);
    assert!(o.stdout.contains("is a loose chat, by intent"), "{}", o.stdout);
    assert!(qm.read("sessions.jsonl").contains("\"loose\":\"abc123\""));
}

#[test]
fn session_end_of_an_unused_session_dismisses_it() {
    let qm = Qm::new();
    qm.run_with(&["hook-session-start"], &start_payload("abc"), &[]);
    let o = qm.run_with(&["hook-session-end"], r#"{"session_id":"abc","cwd":"/tmp","reason":"exit"}"#, &[]);
    assert_eq!((o.code, o.stdout.as_str()), (0, ""));
    let log = qm.read("sessions.jsonl");
    let lines: Vec<&str> = log.lines().collect();
    assert_eq!(lines.len(), 3, "{log}");
    assert!(lines[1].starts_with(r#"{"v":1,"event":"end","session_id":"abc","reason":"exit","duration_s":N,"commits":null,"diff_stat":null,"ts":"TS","empty":true}"#), "{}", lines[1]);
    assert_eq!(lines[2], r#"{"v":1,"event":"dismissed","session_id":"abc","ts":"TS"}"#);
}

#[test]
fn hooks_swallow_bad_input_and_honor_qm_skip() {
    let qm = Qm::new();
    let bad = qm.run_with(&["hook-session-start"], r#"{"session_id":"x""#, &[]);
    assert_eq!((bad.code, bad.stdout.as_str()), (0, ""));
    let skipped = qm.run_with(&["hook-session-start"], &start_payload("abc"), &[("QM_SKIP", "1")]);
    assert_eq!((skipped.code, skipped.stdout.as_str()), (0, ""));
    assert!(!qm.exists("sessions.jsonl"));
}

#[test]
fn sessions_and_inbox_reflect_the_log() {
    let qm = Qm::new();
    assert_eq!(qm.ok(&["inbox"]), "Inbox empty — every captured session is linked to a work item or dismissed.\n");
    qm.run_with(&["hook-session-start"], &start_payload("abc"), &[]);
    let inbox = normalize(&qm.ok(&["inbox"]));
    assert!(inbox.contains("abc") && inbox.contains("/tmp"), "{inbox}");
    qm.ok(&["dismiss", "abc"]);
    assert!(qm.ok(&["inbox"]).starts_with("Inbox empty"));
}

#[test]
fn session_end_after_a_start_marks_the_session_ended() {
    let qm = Qm::new();
    qm.run_with(&["hook-session-start"], &start_payload("abc"), &[]);
    qm.run_with(&["hook-session-end"], r#"{"session_id":"abc","cwd":"/tmp","reason":"exit"}"#, &[]);
    let out = normalize(&qm.ok(&["sessions"]));
    assert_eq!(out, "  ended  abc  -  /tmp  -  TS  Ns\n".replace("Ns", "1s"));
}

// ------------------------------------------------------------------- the CLI

#[test]
fn unknown_command_prints_an_error_and_the_usage_and_exits_1() {
    let qm = Qm::new();
    let o = qm.run(&["bogus"]);
    assert_eq!(o.code, 1);
    assert_eq!(o.stderr, "qm: unknown command 'bogus'\n");
    assert!(o.stdout.starts_with("qm — Claude Code session & work-item tracker\n\nViewer:\n"), "{}", o.stdout);
}

#[test]
fn help_lists_every_documented_command() {
    let qm = Qm::new();
    let help = qm.ok(&["help"]);
    for word in [
        "qm new TITLE", "qm attach SLUG", "qm detach SLUG", "qm note SLUG", "qm retag SLUG", "qm state SLUG",
        "qm link-branch SLUG", "qm board SLUG", "qm move SLUG", "qm retitle SLUG", "qm describe SLUG",
        "qm show SLUG", "qm list", "qm attention", "qm inbox", "qm hook-session-start", "qm install-hooks",
    ] {
        assert!(help.contains(word), "help lacks {word}");
    }
}

#[test]
fn install_hooks_prints_a_settings_snippet_and_writes_nothing() {
    let qm = Qm::new();
    let home = tempfile::tempdir().unwrap();
    let o = qm.run_with(&["install-hooks"], "", &[("HOME", home.path().to_str().unwrap())]);
    assert_eq!(o.code, 0);
    assert!(o.stdout.contains("hook-session-start") && o.stdout.contains("hook-session-end"), "{}", o.stdout);
    assert!(!home.path().join(".claude").join("settings.json").exists());
}

#[test]
fn every_qm_command_appends_to_the_feature_use_log_without_arguments() {
    let qm = Qm::new();
    qm.ok(&["new", "Secret title"]);
    qm.ok(&["list"]);
    let log = qm.read("feature-use.jsonl");
    assert!(log.contains("\"kind\":\"cli\"") || log.contains("\"kind\": \"cli\""), "{log}");
    assert!(!log.contains("Secret") && !log.contains("secret-title"), "{log}");
}
