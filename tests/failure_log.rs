//! qm.log's line format and the once-per-outage rule for transient failures of success-reporting contexts.

mod common;
use common::*;
use quartermaster::failure_log as log;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const OFFLINE: &str = "gh api graphql failed: Post \"https://api.github.com/graphql\": read tcp 10.0.0.2:5000->10.0.0.9:443: read: connection reset by peer";

struct World {
    qm: Qm,
    _guard: std::sync::MutexGuard<'static, ()>,
}

fn world() -> World {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    std::env::set_var("QM_ROOT", qm.root.path());
    log::reset();
    World { qm, _guard: guard }
}

impl World {
    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(self.qm.root.path().join("qm.log")).unwrap_or_default().lines().map(String::from).collect()
    }
}

#[test]
fn a_multi_line_message_stays_on_the_header_line() {
    let w = world();
    log::failure("pr-deployment", "RuntimeError", "gh pr view failed: boom\ncheck this\n");
    assert_eq!(w.lines().len(), 1);
    assert!(w.lines()[0].ends_with("] RuntimeError: gh pr view failed: boom check this"), "{:?}", w.lines());
}

#[test]
fn a_transient_failure_is_logged_once_per_outage_and_its_end_once() {
    let w = world();
    for _ in 0..3 {
        log::failure("pr-inbox", "RuntimeError", OFFLINE);
    }
    log::success("pr-inbox");
    log::success("pr-inbox");
    log::failure("pr-inbox", "RuntimeError", OFFLINE);
    let lines = w.lines();
    assert_eq!(lines.len(), 3, "{lines:?}");
    assert!(lines[0].contains("[pr-inbox] transient RuntimeError: gh api graphql failed"));
    assert!(lines[1].ends_with("[pr-inbox] recovered after 3 failures"));
    assert!(lines[2].contains("] transient RuntimeError"));
}

#[test]
fn a_context_that_never_reports_success_logs_every_transient_failure() {
    let w = world();
    for _ in 0..3 {
        log::failure("gui-prs", "RuntimeError", OFFLINE);
    }
    log::success("gui-prs");
    assert_eq!(w.lines().len(), 3);
    assert!(w.lines().iter().all(|l| l.contains("[gui-prs] transient RuntimeError: gh api graphql failed")));
}

#[test]
fn the_success_reporting_contexts_are_exactly_those_with_a_success_call_site() {
    let mut found = std::collections::BTreeSet::new();
    let literal = regex::Regex::new(r#"(?:failure_log::|[ {(])success\("([^"]+)"\)"#).unwrap();
    let other = regex::Regex::new(r#"failure_log::success\([^"]"#).unwrap();
    for entry in std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/src")).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!other.is_match(&text), "success takes a literal context: {}", path.display());
        found.extend(literal.captures_iter(&text).map(|c| c[1].to_string()));
    }
    let mut named: Vec<String> = log::SUCCESS_REPORTING.iter().map(|s| s.to_string()).collect();
    named.sort();
    assert_eq!(found.into_iter().collect::<Vec<_>>(), named);
}

#[test]
fn a_single_failure_outage_recovers_in_the_singular() {
    let w = world();
    log::failure("pr-inbox", "RuntimeError", OFFLINE);
    log::success("pr-inbox");
    assert!(w.lines().last().unwrap().ends_with("] recovered after 1 failure"));
}

#[test]
fn success_without_an_outage_logs_nothing() {
    let w = world();
    log::success("pr-inbox");
    assert!(!w.qm.root.path().join("qm.log").exists());
}

#[test]
fn outages_are_kept_per_context() {
    let w = world();
    log::failure("pr-inbox", "RuntimeError", OFFLINE);
    log::failure("pr-deployment", "RuntimeError", OFFLINE);
    log::success("pr-deployment");
    assert_eq!(w.lines().len(), 3);
    assert!(w.lines().last().unwrap().contains("[pr-deployment] recovered"));
}

#[test]
fn a_non_transient_failure_during_an_outage_is_logged_in_full() {
    let w = world();
    log::failure("pr-inbox", "RuntimeError", OFFLINE);
    log::failure("pr-inbox", "TypeError", "no implicit conversion");
    log::failure("pr-inbox", "TypeError", "no implicit conversion");
    assert_eq!(w.lines().len(), 3);
}

#[test]
fn network_failures_seen_from_gh_count_as_transient() {
    for message in [
        "gh pr view failed: error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
        "gh api repos/acme/webshop/releases/latest failed: Get \"https://api.github.com/x\": dial tcp 10.0.0.9:443: i/o timeout",
        "gh api graphql failed: Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout",
        "gh api graphql failed: read tcp 10.0.0.2:5000->10.0.0.9:443: read: operation timed out",
        "gh api graphql failed: Post \"https://api.github.com/graphql\": EOF",
    ] {
        assert!(log::transient("RuntimeError", message), "{message}");
    }
    assert!(!log::transient("TypeError", "no implicit conversion of Hash into String"));
    assert!(!log::transient("RuntimeError", "gh pr view failed: no pull requests found for branch \"x\""));
    assert!(!log::transient("EOFError", "end of file reached"));
}

#[test]
fn a_browser_tab_closing_mid_write_is_transient_and_a_served_response_ends_the_outage() {
    let w = world();
    assert!(log::transient("Errno::EPIPE", "Broken pipe"));
    assert!(log::transient("Errno::ECONNRESET", "reset"));
    let closed = || Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe));
    log::client_write(closed());
    log::client_write(closed());
    log::client_write(Ok(()));
    let lines = w.lines();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(lines[0].contains("[gui-client] transient Errno::EPIPE"));
    assert!(lines[1].ends_with("[gui-client] recovered after 2 failures"));
}
