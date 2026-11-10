//! The Review service without a GUI: what the pr-review automation flow calls. tmux is the real one on a
//! throwaway socket and claude a stand-in that records how it was started; the PR is a JSON object, as the
//! inbox cache holds it.

mod common;
use common::chat::*;
use quartermaster::pr_review_start;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const URL: &str = "https://github.com/acme/WebApp/pull/42";

fn pr() -> Value {
    json!({"url": URL, "number": 42, "title": "Add the thing", "repo": "acme/WebApp", "author": "someone", "head": "feature-x", "base": "main"})
}

fn argv_of(started: &Started) -> &[String] {
    &started.args
}

#[test]
fn start_puts_extra_argv_before_the_kickoff_and_appends_the_suffix() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, repo) = with_webapp("prstart");
    let extra: Vec<String> = ["--session-id", "abc", "--model", "opus"].iter().map(|s| s.to_string()).collect();
    let reply = pr_review_start::start(&pr(), &extra, Some("Focus on the migrations.")).unwrap();
    let slug = "review-webapp-42-add-the-thing";
    assert_eq!(reply, json!({"slug": slug, "mode": "start"}));
    let started = &world.wait_started(1)[0];
    assert_eq!(started.item, slug);
    let args = argv_of(started);
    assert_eq!(&args[..4], ["--session-id", "abc", "--model", "opus"]);
    assert_eq!(args.len(), 5);
    let parts: Vec<&str> = args[4].split("\n\n").collect();
    assert_eq!(parts[0], format!("/review-app-pr {URL}"));
    assert!(parts[1].contains(&format!("qm draft add {slug}")));
    assert_eq!(parts[2], "Focus on the migrations.");
    assert_eq!(std::fs::canonicalize(&started.cwd).unwrap(), std::fs::canonicalize(&repo).unwrap());
    assert_eq!(world.sessions(), [slug]);
}

#[test]
fn a_blank_suffix_leaves_the_kickoff_as_the_review_button_sends_it() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("prstart");
    pr_review_start::start(&pr(), &[], Some("  ")).unwrap();
    let started = &world.wait_started(1)[0];
    assert_eq!(started.args.len(), 1);
    assert_eq!(started.args[0].split("\n\n").count(), 2);
}

#[test]
fn live_reports_the_review_chat_without_starting_or_creating_anything() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("prstart");
    assert!(!pr_review_start::live(&pr()).unwrap());
    assert!(WorkItem::all().unwrap().is_empty(), "asking must not create the Review item");
    let slug = pr_review_start::item_for(&pr()).unwrap().slug;
    assert!(!pr_review_start::live(&pr()).unwrap());
    assert!(world.tmux(&["new-session", "-d", "-s", &slug, "sleep", "60"]).0);
    assert!(pr_review_start::live(&pr()).unwrap(), "a live pane is a live chat");
    assert!(world.started().is_empty());
}

#[test]
fn a_session_running_outside_a_pane_is_live_and_refuses_a_start() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("prstart");
    let mut item = pr_review_start::item_for(&pr()).unwrap();
    item.attach_session("s-outside").unwrap();
    let start = json!({"v": 1, "event": "start", "session_id": "s-outside", "cwd": "/", "pid": std::process::id(), "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)});
    std::fs::write(world.root().join("sessions.jsonl"), format!("{start}\n")).unwrap();
    assert!(pr_review_start::live(&pr()).unwrap());
    let error = pr_review_start::start(&pr(), &[], None).unwrap_err();
    assert!(error.contains("has a chat running outside the GUI"), "{error}");
    assert!(world.sessions().is_empty());
}

#[test]
fn a_live_pane_is_attached_not_restarted() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("prstart");
    let slug = pr_review_start::item_for(&pr()).unwrap().slug;
    assert!(world.tmux(&["new-session", "-d", "-s", &slug, "sleep", "60"]).0);
    let extra = vec!["--session-id".to_string(), "x".to_string()];
    assert_eq!(pr_review_start::start(&pr(), &extra, None).unwrap(), json!({"slug": slug, "attached": true}));
    assert!(world.started().is_empty());
}

#[test]
fn a_resolved_review_item_is_reopened() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("prstart");
    let mut item = pr_review_start::item_for(&pr()).unwrap();
    item.update_state("resolved").unwrap();
    pr_review_start::start(&pr(), &[], None).unwrap();
    world.wait_started(1);
    assert_eq!(WorkItem::find(&item.slug).unwrap().state().as_deref(), Some("in_progress"));
}
