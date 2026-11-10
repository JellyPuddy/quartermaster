//! A local automation's chat-flow run (its own `<slug>--run-<id>` tmux) has no item row in attention (its item
//! is the automation), so it gets a row of its own in the Runs group, and a turn notification for it opens its
//! tmux.

mod common;
use chrono::{DateTime, SubsecRound, Utc};
use common::chat::*;
use quartermaster::chat_attention::ChatAttention;
use quartermaster::run_chats;
use quartermaster::run_log::RunLog;
use quartermaster::turn_notifier;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::io::Write;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0)
}

fn automation(world: &ChatWorld, slug: &str, notify: &str, flow: &str) {
    let mut item = WorkItem::create(&format!("{}{}", slug[..1].to_uppercase(), &slug[1..]), "No project", None, None, None, None).unwrap();
    item.make_automation("local").unwrap();
    world.write_automation(slug, json!({"name": format!("{}{}", slug[..1].to_uppercase(), &slug[1..]), "notify": notify, "flow": flow}));
}

/// A started run whose session is live (this process's pid) unless told otherwise.
fn run_of(world: &ChatWorld, slug: &str, session: &str, tmux: Option<&str>, item: Value, pid: u32) -> String {
    let log = RunLog::new(slug, &world.automations()).unwrap();
    let id = log.enqueue(item["key"].as_str().unwrap_or("k"), &item, "chat", "guard", now()).unwrap();
    log.started(&id, session, tmux.map(String::from).unwrap_or_else(|| format!("{slug}--run-{id}")).as_str(), slug, now()).unwrap();
    let event = json!({"v": 1, "event": "start", "session_id": session, "cwd": "/", "pid": pid, "ts": now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)});
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(world.root().join("sessions.jsonl")).unwrap();
    writeln!(file, "{event}").unwrap();
    WorkItem::find(slug).unwrap().attach_session(session).unwrap();
    id
}

fn thing_a() -> Value {
    json!({"key": "a", "title": "Thing A"})
}

#[test]
fn a_live_runs_turn_is_a_row_in_the_runs_group() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "nightly", "attention", "chat");
    let id = run_of(&world, "nightly", "s-run", None, thing_a(), std::process::id());
    world.log_events("s-run", now(), &[(120, "UserPromptSubmit", None), (60, "Stop", None)]);
    let mut attention = ChatAttention::new();
    let runs = attention.runs();
    let seen: Vec<(String, Option<String>, String, String, String)> = runs.iter().map(|e| (e.slug.clone(), e.session_id.clone(), e.state.clone(), e.run.as_ref().unwrap().slug.clone(), e.run.as_ref().unwrap().title.clone())).collect();
    assert_eq!(seen, [(format!("nightly--run-{id}"), Some("s-run".into()), "your_turn".into(), "nightly".into(), "Nightly · Thing A".into())]);
    assert!(attention.entries().unwrap().is_empty(), "the automation item itself still has no row");
}

#[test]
fn quiet_ended_and_pr_review_runs_have_no_row() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "hush", "quiet", "chat");
    run_of(&world, "hush", "s-quiet", None, thing_a(), std::process::id());
    automation(&world, "nightly", "attention", "chat");
    run_of(&world, "nightly", "s-gone", None, thing_a(), 999_999_999);
    automation(&world, "reviews", "attention", "pr-review");
    run_of(&world, "reviews", "s-review", Some("review-acme-1"), thing_a(), std::process::id());
    assert!(ChatAttention::new().runs().is_empty());
}

#[test]
fn a_run_without_an_item_title_is_titled_by_its_key() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "nightly", "attention", "chat");
    let id = run_of(&world, "nightly", "s-run", None, json!({"key": "cron:x"}), std::process::id());
    let titles: Vec<String> = ChatAttention::new().runs().iter().map(|e| e.run.as_ref().unwrap().title.clone()).collect();
    assert_eq!(titles, ["Nightly · cron:x"]);
    let chats = run_chats::by_session(&world.automations());
    assert_eq!(chats.iter().find(|(s, _)| s == "s-run").unwrap().1.tmux, format!("nightly--run-{id}"));
}

#[test]
fn a_blocked_run_notifies_naming_and_opening_its_tmux() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "nightly", "attention", "chat");
    let id = run_of(&world, "nightly", "s-run", None, thing_a(), std::process::id());
    world.log_events("s-run", now(), &[(30, "UserPromptSubmit", None)]);
    turn_notifier::check(); // takes stock
    world.log_events("s-run", now(), &[(1, "PermissionRequest", Some("Bash"))]);
    turn_notifier::check();
    let tmux = format!("nightly--run-{id}");
    let raised = turn_notifier::recent().into_iter().rev().find(|n| n["session"] == "s-run").expect("a notification for the run");
    assert_eq!((&raised["slug"], &raised["run"], &raised["title"]), (&Value::Null, &json!(tmux), &json!("Nightly · Thing A")));
    let argv = world.notifications().pop().unwrap();
    let after = |flag: &str| argv[argv.iter().position(|a| a == flag).unwrap() + 1].clone();
    assert_eq!(after("-group"), format!("qm-{tmux}"));
    assert!(after("-execute").ends_with(&format!("open-chat {tmux}")), "{}", after("-execute"));
}

#[test]
fn the_gui_serves_a_live_run_chat_with_its_state_and_opens_a_run_notification_in_it() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "nightly", "attention", "chat");
    let id = run_of(&world, "nightly", "s-run", None, thing_a(), std::process::id());
    world.log_events("s-run", now(), &[(5, "UserPromptSubmit", None), (1, "PermissionRequest", Some("Bash"))]);
    let tmux = format!("nightly--run-{id}");
    world.tmux(&["new-session", "-d", "-s", &tmux, "sleep 60"]);
    world.tmux(&["new-session", "-d", "-s", "nightly", "sleep 60"]);
    let payload = quartermaster::gui_state::attention_payload();
    let rows: Vec<Vec<Value>> = payload["loose"].as_array().unwrap().iter().map(|c| ["name", "session", "state", "title"].iter().map(|k| c[*k].clone()).collect()).collect();
    assert_eq!(rows, [vec![json!(tmux), json!("s-run"), json!("blocked"), json!("Nightly · Thing A")]]);
    assert!(payload["attention"].as_array().unwrap().is_empty(), "the automation item has no row of its own");
    assert!(include_str!("../gui/js/notify.js").contains("looseOf(n.run || n.loose)"));
}

#[test]
fn qm_attention_lists_a_runs_row() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("runatt");
    automation(&world, "nightly", "attention", "chat");
    let id = run_of(&world, "nightly", "s-run", None, thing_a(), std::process::id());
    world.log_events("s-run", now(), &[(5, "UserPromptSubmit", None), (1, "PermissionRequest", Some("Bash"))]);
    let out = std::process::Command::new(common::bin()).arg("attention").output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let plain = regex::Regex::new(r"\x1b\[\d+m").unwrap().replace_all(&text, "").to_string();
    let wanted = regex::Regex::new(&format!(r"🔴 blocked\s+nightly--run-{id}\s+\d+s · Bash\s+Nightly · Thing A")).unwrap();
    assert!(wanted.is_match(&plain), "{plain}");
}
