//! A `notify: quiet` local automation's run sessions stay out of attention: no chat-list row state and no
//! turn notification. A run of a loud one (or any other session) still counts. A pr-review run lives in its
//! Review item's own chat, so that is where it would otherwise show.

mod common;
use chrono::{DateTime, SubsecRound, Utc};
use common::chat::*;
use quartermaster::chat_attention::ChatAttention;
use quartermaster::run_log::RunLog;
use quartermaster::turn_notifier;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0)
}

/// An item with a live chat: the session started in this process and is attached.
fn live_item(world: &ChatWorld, title: &str, session: &str) -> WorkItem {
    let mut item = WorkItem::create(title, "MyApp", None, None, None, None).unwrap();
    item.attach_session(session).unwrap();
    world.session_start(session, now());
    item
}

fn run_in(world: &ChatWorld, slug: &str, session: &str, notify: &str) {
    world.write_automation(slug, json!({"notify": notify, "flow": "pr-review"}));
    let log = RunLog::new(slug, &world.automations()).unwrap();
    let id = log.enqueue("k", &json!({"key": "k", "url": "u"}), "pr-review", "guard", now()).unwrap();
    log.started(&id, session, "review-x", "review-x", now()).unwrap();
}

fn state_of(item: &WorkItem) -> String {
    ChatAttention::new().entries().unwrap().into_iter().find(|e| e.slug == item.slug).unwrap().state
}

#[test]
fn a_quiet_automations_run_session_is_left_out_of_its_items_attention_row() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("quiet");
    let item = live_item(&world, "Review acme#1", "s-run");
    run_in(&world, "reviews", "s-run", "quiet");
    world.log_events("s-run", now(), &[(120, "UserPromptSubmit", None), (60, "Stop", None)]);
    assert_eq!(state_of(&item), "none");
}

#[test]
fn a_loud_automations_run_session_shows_like_any_chat() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("quiet");
    let item = live_item(&world, "Review acme#1", "s-run");
    run_in(&world, "reviews", "s-run", "attention");
    world.log_events("s-run", now(), &[(120, "UserPromptSubmit", None), (60, "Stop", None)]);
    assert_eq!(state_of(&item), "your_turn");
}

#[test]
fn a_quiet_automations_run_raises_no_notification_and_a_loud_session_does() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("quiet");
    live_item(&world, "Review acme#1", "s-run");
    live_item(&world, "Other work", "s-other");
    run_in(&world, "reviews", "s-run", "quiet");
    world.log_events("s-run", now(), &[(300, "UserPromptSubmit", None)]);
    world.log_events("s-other", now(), &[(300, "UserPromptSubmit", None)]);
    turn_notifier::check(); // takes stock
    world.log_events("s-run", now(), &[(10, "PermissionRequest", Some("Bash"))]);
    world.log_events("s-other", now(), &[(10, "PermissionRequest", Some("Bash"))]);
    turn_notifier::check();
    let sent = world.notifications();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(sent[0].contains(&"Other work".to_string()), "{:?}", sent[0]);
}

#[test]
fn the_event_fold_counts_a_sessions_prompts() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("quiet");
    world.log_events("s1", now(), &[(300, "UserPromptSubmit", None), (200, "Stop", None), (100, "UserPromptSubmit", None)]);
    let turns = quartermaster::event_log::turns();
    assert_eq!(turns["s1"]["prompts"], Value::from(2));
}
