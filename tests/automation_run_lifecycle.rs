//! What a tick does with runs already started: a run whose turn ended is finished, a finished `--run-` chat
//! left alone for an hour is closed, an untouched run working past its timeout is stopped — and a run the user
//! typed into is theirs. Session states come from a prepared events.jsonl counted back from the test's one
//! clock reading; tmux is the real one on a throwaway socket.

mod common;
use chrono::{DateTime, Duration, SubsecRound, Utc};
use common::chat::*;
use quartermaster::automation_tick::{AutomationTick, Summary, Tick};
use quartermaster::run_log::RunLog;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

static ENV: Mutex<()> = Mutex::new(());

fn now() -> DateTime<Utc> {
    static NOW: OnceLock<DateTime<Utc>> = OnceLock::new();
    *NOW.get_or_init(|| Utc::now().trunc_subsecs(0))
}

fn ago(secs: i64) -> DateTime<Utc> {
    now() - Duration::seconds(secs)
}

fn automation(world: &ChatWorld, title: &str, record: Value) -> String {
    let item = WorkItem::create(title, "No project", None, None, None, None).unwrap();
    let mut base = json!({"cron": "", "name": title});
    base.as_object_mut().unwrap().extend(record.as_object().unwrap().clone());
    world.write_automation(&item.slug, base);
    item.slug
}

fn log(world: &ChatWorld, slug: &str) -> RunLog {
    RunLog::new(slug, &world.automations()).unwrap()
}

fn tick(world: &ChatWorld) -> Box<Summary> {
    match AutomationTick::new(&world.automations()).call(now()).expect("the tick ran") {
        Tick::Ran(summary) => summary,
        Tick::Locked => panic!("locked"),
    }
}

/// A started run whose session (live, this process) reported these events; `tmux`: the name it runs under (a
/// pr-review run's is the Review item's slug).
fn started_run(world: &ChatWorld, slug: &str, session: &str, turn: &[(i64, &str, Option<&str>)], ago_secs: i64, tmux: Option<&str>) -> String {
    let run_log = log(world, slug);
    let id = run_log.enqueue(&format!("k-{session}"), &Value::Null, "chat", "manual", ago(ago_secs)).unwrap();
    let name = tmux.map(String::from).unwrap_or_else(|| format!("{slug}--run-{id}"));
    run_log.started(&id, session, &name, slug, ago(ago_secs)).unwrap();
    world.session_start(session, now());
    if !turn.is_empty() {
        world.log_events(session, now(), turn);
    }
    id
}

/// A started run whose SessionStart hook never reported.
fn unreported_run(world: &ChatWorld, slug: &str, ago_secs: i64) -> String {
    let run_log = log(world, slug);
    let id = run_log.enqueue(&format!("k-{ago_secs}"), &Value::Null, "chat", "manual", ago(ago_secs)).unwrap();
    run_log.started(&id, &format!("never-{id}"), &format!("{slug}--run-{id}"), slug, ago(ago_secs)).unwrap();
    id
}

fn open_chat(world: &ChatWorld, name: &str) {
    assert!(world.tmux(&["new-session", "-d", "-s", name, "sleep", "120"]).0);
}

fn live(world: &ChatWorld, name: &str) -> bool {
    world.sessions().iter().any(|s| s == name)
}

fn status(world: &ChatWorld, slug: &str, id: &str) -> String {
    log(world, slug).run(id).unwrap().status
}

const PROMPT: &str = "UserPromptSubmit";

#[test]
fn a_run_whose_session_ended_mid_turn_fails_and_can_be_retried() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(600, PROMPT, None), (300, "PostToolUse", Some("Bash"))], 600, None);
    world.session_end("s1", now());
    let summary = tick(&world);
    let run = log(&world, &slug).run(&id).unwrap();
    assert_eq!((run.status.as_str(), run.error.as_deref()), ("failed", Some("session ended before the run finished")));
    assert!(summary.failed.contains(&(slug.clone(), id.clone())));
    assert!(log(&world, &slug).retry(&id, now()).is_ok());
}

#[test]
fn a_run_whose_session_ended_on_its_turn_is_finished() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(600, PROMPT, None), (300, "Stop", None)], 600, None);
    world.session_end("s1", now());
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "finished");
}

#[test]
fn a_typed_into_run_whose_session_ended_fails() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(600, PROMPT, None), (500, "Stop", None), (400, PROMPT, None)], 600, None);
    world.session_end("s1", now());
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "failed");
}

#[test]
fn a_run_whose_chat_died_before_its_session_started_fails_after_five_minutes() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = unreported_run(&world, &slug, 301);
    tick(&world);
    let run = log(&world, &slug).run(&id).unwrap();
    assert_eq!((run.status.as_str(), run.error.as_deref()), ("failed", Some("its chat ended before the session started")));
}

#[test]
fn a_run_without_a_session_or_chat_stays_live_within_five_minutes() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = unreported_run(&world, &slug, 240);
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "live");
}

#[test]
fn a_run_without_a_session_whose_chat_lives_stays_live() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({"timeout_minutes": 60}));
    let id = unreported_run(&world, &slug, 900);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "live");
}

#[test]
fn a_pr_review_run_whose_session_ended_fails_and_its_review_chat_stays() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Reviews", json!({"flow": "pr-review"}));
    let id = started_run(&world, &slug, "s1", &[(600, PROMPT, None)], 600, Some("review-acme-app-1"));
    world.session_end("s1", now());
    open_chat(&world, "review-acme-app-1");
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "failed");
    assert!(live(&world, "review-acme-app-1"));
}

#[test]
fn a_run_whose_turn_ended_is_finished_and_its_chat_stays_open_within_the_hour() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(600, PROMPT, None), (300, "Stop", None)], 600, None);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "finished");
    assert!(live(&world, &format!("{slug}--run-{id}")));
}

#[test]
fn a_finished_run_idle_for_an_hour_is_closed() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(7200, PROMPT, None), (3700, "Stop", None)], 7200, None);
    let name = format!("{slug}--run-{id}");
    open_chat(&world, &name);
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "finished");
    tick(&world);
    assert!(!live(&world, &name));
    assert_eq!(status(&world, &slug, &id), "closed");
}

#[test]
fn a_run_the_user_typed_into_is_never_closed() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(7200, PROMPT, None), (7000, "Stop", None), (6000, PROMPT, None), (3700, "Stop", None)], 7200, None);
    let name = format!("{slug}--run-{id}");
    open_chat(&world, &name);
    tick(&world);
    tick(&world);
    assert!(live(&world, &name));
    assert_eq!(status(&world, &slug, &id), "finished");
}

#[test]
fn a_run_working_past_its_timeout_is_stopped_noted_and_announced() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None), (60, "PostToolUse", Some("Bash"))], 1900, None);
    let name = format!("{slug}--run-{id}");
    open_chat(&world, &name);
    let summary = tick(&world);
    assert!(!live(&world, &name));
    assert_eq!(status(&world, &slug, &id), "timed_out");
    assert_eq!(pair_list(&summary.timed_out), [(slug.clone(), id.clone())]);
    let note = WorkItem::find(&slug).unwrap().notes().remove(0);
    assert_eq!((note.kind.as_str(), note.text.as_str()), ("history", format!("run {id} timed out after 30 min").as_str()));
    let sent = world.notifications().pop().unwrap();
    assert!(sent.contains(&"Nightly".to_string()) && sent.contains(&format!("Run {id} timed out after 30 min")), "{sent:?}");
}

fn pair_list(list: &[(String, String)]) -> Vec<(String, String)> {
    list.to_vec()
}

#[test]
fn a_run_within_its_timeout_keeps_working() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({"timeout_minutes": 60}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None)], 1900, None);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert!(live(&world, &format!("{slug}--run-{id}")));
    assert_eq!(status(&world, &slug, &id), "live");
}

#[test]
fn a_blocked_run_never_times_out() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None), (1800, "PermissionRequest", Some("Bash"))], 1900, None);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert!(live(&world, &format!("{slug}--run-{id}")));
    assert_eq!(status(&world, &slug, &id), "live");
}

#[test]
fn a_run_the_user_typed_into_never_times_out() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None), (1850, "Stop", None), (1800, PROMPT, None)], 1900, None);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert!(live(&world, &format!("{slug}--run-{id}")));
    assert_eq!(status(&world, &slug, &id), "live");
}

#[test]
fn a_pr_review_run_past_its_timeout_is_only_marked_and_its_review_chat_stays() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Reviews", json!({"flow": "pr-review"}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None)], 1900, Some("review-acme-app-1"));
    open_chat(&world, "review-acme-app-1");
    tick(&world);
    assert!(live(&world, "review-acme-app-1"));
    assert_eq!(status(&world, &slug, &id), "timed_out");
    assert_eq!(WorkItem::find(&slug).unwrap().notes().remove(0).text, format!("run {id} timed out after 30 min (its Review chat stays open)"));
    assert_eq!(world.notifications().len(), 1);
}

#[test]
fn a_finished_pr_review_run_is_never_closed() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    let slug = automation(&world, "Reviews", json!({"flow": "pr-review"}));
    let id = started_run(&world, &slug, "s1", &[(7200, PROMPT, None), (3700, "Stop", None)], 7200, Some("review-acme-app-1"));
    open_chat(&world, "review-acme-app-1");
    tick(&world);
    tick(&world);
    assert!(live(&world, "review-acme-app-1"));
    assert_eq!(status(&world, &slug, &id), "finished");
}

#[test]
fn lifecycle_checks_run_while_paused() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    world.config("automations:\n  local_paused: true\n");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None)], 1900, None);
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert_eq!(status(&world, &slug, &id), "timed_out");
}

#[test]
fn a_timed_out_run_frees_its_slot_in_the_same_tick() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("life");
    world.config("automations:\n  local_max_running: 1\n");
    let slug = automation(&world, "Nightly", json!({}));
    let id = started_run(&world, &slug, "s1", &[(1900, PROMPT, None)], 1900, None);
    let queued = log(&world, &slug).enqueue("next", &Value::Null, "chat", "manual", ago(60)).unwrap();
    open_chat(&world, &format!("{slug}--run-{id}"));
    tick(&world);
    assert_eq!(world.sessions(), [format!("{slug}--run-{queued}")]);
}
