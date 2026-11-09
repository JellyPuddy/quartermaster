//! The live run chats among the tmux session names, and every chat-flow run by its session id.

mod common;
use chrono::Utc;
use common::chat::*;
use quartermaster::chat_attention::ChatAttention;
use quartermaster::run_chats;
use quartermaster::run_log::RunLog;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn started_run(world: &ChatWorld, item: Value, session: &str, tmux: Option<&str>) -> String {
    let log = RunLog::new("nightly", &world.automations()).unwrap();
    let id = log.enqueue(item["key"].as_str().unwrap_or("k"), &item, "chat", "guard", Utc::now()).unwrap();
    log.started(&id, session, tmux.unwrap_or(&format!("nightly--run-{id}")), "nightly", Utc::now()).unwrap();
    id
}

#[test]
fn a_live_run_chat_is_listed_with_its_run_title_and_state() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("rchats");
    world.write_automation("nightly", json!({"name": "Nightly"}));
    let id = started_run(&world, json!({"key": "a", "title": "Thing A"}), "s-run", None);
    let panes: Vec<String> = [format!("nightly--run-{id}"), "loose--abcd1234".into(), "nightly".into(), "gone--run-x".into()].into();
    let rows = run_chats::chats(&panes, &world.automations(), &mut ChatAttention::new());
    assert_eq!(rows.len(), 1);
    assert_eq!((&rows[0]["name"], &rows[0]["run"], &rows[0]["title"], &rows[0]["state"]), (&json!(format!("nightly--run-{id}")), &json!({"slug": "nightly", "id": id, "quiet": false}), &json!("Nightly · Thing A"), &json!("none")));
}

#[test]
fn a_run_chat_carries_its_sessions_whose_move_it_is() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("rchats");
    world.write_automation("nightly", json!({"name": "Nightly"}));
    let id = started_run(&world, json!({"key": "a", "title": "Thing A"}), "s-run", None);
    world.session_start("s-run", Utc::now());
    world.log_events("s-run", Utc::now(), &[(5, "UserPromptSubmit", None), (1, "PermissionRequest", Some("Bash"))]);
    let rows = run_chats::chats(&[format!("nightly--run-{id}")], &world.automations(), &mut ChatAttention::new());
    assert_eq!((&rows[0]["session"], &rows[0]["state"], &rows[0]["tool"]), (&json!("s-run"), &json!("blocked"), &json!("Bash")));
    assert!(rows[0]["since"].as_str().unwrap().ends_with('Z'));
}

#[test]
fn a_quiet_automations_run_chat_is_listed_but_marked_quiet() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("rchats");
    world.write_automation("nightly", json!({"name": "Nightly", "notify": "quiet"}));
    let id = started_run(&world, json!({"key": "a", "title": "Thing A"}), "s-run", None);
    let rows = run_chats::chats(&[format!("nightly--run-{id}")], &world.automations(), &mut ChatAttention::new());
    assert_eq!(rows.iter().map(|r| r["run"]["quiet"].clone()).collect::<Vec<_>>(), [json!(true)]);
}

#[test]
fn by_session_names_every_chat_flow_run_and_titles_an_untitled_item_by_its_key() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("rchats");
    world.write_automation("nightly", json!({"name": "Nightly"}));
    let id = started_run(&world, json!({"key": "cron:x"}), "s-run", None);
    started_run(&world, Value::Null, "s-review", Some("review-acme-1"));
    let chats = run_chats::by_session(&world.automations());
    assert_eq!(chats.len(), 1, "a pr-review run lives in its Review item's chat, not a --run- one");
    let (session, chat) = &chats[0];
    assert_eq!((session.as_str(), chat.tmux.as_str(), chat.title.as_str(), chat.quiet), ("s-run", format!("nightly--run-{id}").as_str(), "Nightly · cron:x", false));
}

#[test]
fn a_run_without_an_item_is_titled_by_its_run_id() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("rchats");
    world.write_automation("nightly", json!({"name": "Nightly"}));
    let id = started_run(&world, Value::Null, "s-run", None);
    assert_eq!(run_chats::by_session(&world.automations())[0].1.title, format!("Nightly · run {id}"));
}
