//! The local automations' tick, at its `call` seam: guards are real `sh -c` commands printing what the test
//! says, chats open in the real tmux on a throwaway socket (claude is a stand-in), session states come from a
//! prepared events.jsonl and usage from a prepared rate-limits.json.

mod common;
use chrono::{DateTime, Duration, TimeZone, Utc};
use common::chat::*;
use quartermaster::automation_tick::{self, AutomationTick, Summary, Tick};
use quartermaster::run_log::RunLog;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

/// 11:00 or 12:00 in Amsterdam, a minute every */5 cron lists; today, so the events written for it stay in the
/// fold's 30 days.
fn now() -> DateTime<Utc> {
    let today = Utc::now().date_naive();
    Utc.from_utc_datetime(&today.and_hms_opt(10, 0, 0).unwrap())
}

fn ago(secs: i64) -> DateTime<Utc> {
    now() - Duration::seconds(secs)
}

fn log(world: &ChatWorld, slug: &str) -> RunLog {
    RunLog::new(slug, &world.automations()).unwrap()
}

fn events(world: &ChatWorld, slug: &str) -> Vec<Value> {
    std::fs::read_to_string(log(world, slug).path()).unwrap_or_default().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
}

fn tick(world: &ChatWorld, at: DateTime<Utc>) -> Box<Summary> {
    match AutomationTick::new(&world.automations()).call(at).expect("the tick ran") {
        Tick::Ran(summary) => summary,
        Tick::Locked => panic!("locked"),
    }
}

fn queue(world: &ChatWorld, slug: &str, key: &str, trigger: &str, at: i64) -> String {
    log(world, slug).enqueue(key, &Value::Null, "chat", trigger, ago(at)).unwrap()
}

fn queue_item(world: &ChatWorld, slug: &str, key: &str, item: Value, flow: &str, at: i64) -> String {
    log(world, slug).enqueue(key, &item, flow, "guard", ago(at)).unwrap()
}

/// A guard that prints these lines.
fn prints(lines: &[&str]) -> String {
    let args: Vec<String> = lines.iter().map(|l| format!("'{l}'")).collect();
    format!("printf '%s\\n' {}", args.join(" "))
}

/// A run already going: queued, started, its session live (this process).
fn live_run(world: &ChatWorld, slug: &str, session: &str, turn: &[(i64, &str, Option<&str>)]) -> String {
    let run_log = log(world, slug);
    let id = run_log.enqueue(&format!("k-{session}"), &Value::Null, "chat", "manual", ago(900)).unwrap();
    run_log.started(&id, session, &format!("{slug}--run-{id}"), slug, ago(900)).unwrap();
    world.session_start(session, now());
    if !turn.is_empty() {
        world.log_events(session, now(), turn);
    }
    id
}

fn pr(number: u32, repo: &str) -> Value {
    json!({"url": format!("https://github.com/{repo}/pull/{number}"), "number": number, "title": format!("Change {number}"), "repo": repo, "author": "someone", "head": format!("feature-{number}"), "base": "main"})
}

fn pr_lines() -> String {
    prints(&[r#"{"key":"a","url":"https://github.com/acme/WebApp/pull/1"}"#, r#"{"key":"b","url":"https://github.com/stranger/fork/pull/2"}"#])
}

fn keys(runs: Vec<quartermaster::run_log::Run>) -> Vec<String> {
    runs.into_iter().map(|r| r.key.unwrap()).collect()
}

fn pairs(list: &[(String, String)]) -> Vec<(&str, &str)> {
    list.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect()
}

#[test]
fn a_due_cron_without_a_guard_queues_one_run_and_starts_it_in_its_own_chat() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    let summary = tick(&world, now());
    let lines = events(&world, "nightly");
    let id = lines[0]["run_id"].as_str().unwrap().to_string();
    assert_eq!((lines[0]["event"].clone(), lines[0]["key"].clone(), lines[0]["trigger"].clone(), lines[0]["item"].clone()), (json!("queued"), json!(format!("cron:{}", now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true))), json!("cron"), Value::Null));
    assert_eq!(lines[1]["event"], "checked");
    assert_eq!((&lines[2]["event"], &lines[2]["run_id"], &lines[2]["tmux"]), (&json!("started"), &json!(id), &json!(format!("nightly--run-{id}"))));
    assert_eq!(world.sessions(), [format!("nightly--run-{id}")]);
    assert_eq!(world.wait_started(1)[0].args.last().unwrap(), "Do the thing.\n");
    assert_eq!(pairs(&summary.started), [("nightly", id.as_str())]);
    let state = automation_tick::state(&world.automations());
    assert_eq!((&state["v"], &state["last_tick_at"], &state["running"], &state["max_running"]), (&json!(1), &json!(now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)), &json!(1), &json!(2)));
}

#[test]
fn a_cron_that_is_not_due_queues_nothing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({"cron": "30 3 * * *"}));
    tick(&world, now());
    assert!(events(&world, "nightly").is_empty());
}

#[test]
fn missed_cron_minutes_coalesce_into_one_queued_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    world.rate_limits(now(), 95.0, 10.0, 7200);
    tick(&world, now());
    tick(&world, now() + Duration::seconds(600));
    tick(&world, now() + Duration::seconds(3600));
    assert_eq!(log(&world, "nightly").queue().len(), 1);
    assert_eq!(events(&world, "nightly").iter().filter(|e| e["event"] == "checked").count(), 3);
}

#[test]
fn a_guard_queues_one_run_per_line_and_refuses_a_json_line_without_a_key() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 0\n");
    let when = prints(&[r#"{"key":"pr-1","url":"https://x/1"}"#, "plain line", "", r#"{"url":"no key"}"#]);
    world.write_automation("triage", json!({"when": when}));
    tick(&world, now());
    let queue = log(&world, "triage").queue();
    assert_eq!(queue.iter().map(|r| r.item.clone()).collect::<Vec<_>>(), [json!({"key": "pr-1", "url": "https://x/1"}), json!({"key": "plain line", "line": "plain line"})]);
    assert!(queue.iter().all(|r| r.trigger.as_deref() == Some("guard")));
    assert_eq!(log(&world, "triage").last_guard_error().unwrap()["error"], "a guard's JSON item needs a string key");
}

#[test]
fn a_guard_item_already_seen_is_not_queued_again() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 0\n");
    world.write_automation("triage", json!({"when": prints(&["a", "b"])}));
    tick(&world, now());
    world.write_automation("triage", json!({"when": prints(&["b", "c"])}));
    let summary = tick(&world, now() + Duration::seconds(300));
    assert_eq!(keys(log(&world, "triage").queue()), ["a", "b", "c"]);
    assert_eq!(summary.queued.len(), 1);
}

#[test]
fn a_failing_guard_queues_nothing_and_records_the_error() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("triage", json!({"when": "echo x; echo boom >&2; exit 1"}));
    let summary = tick(&world, now());
    assert!(log(&world, "triage").queue().is_empty() && summary.queued.is_empty());
    assert_eq!(log(&world, "triage").last_guard_error().unwrap()["error"], "guard failed: boom");
}

#[test]
fn an_item_lacking_a_field_its_flow_needs_is_a_guard_error() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("reviews", json!({"when": prints(&["not a url"]), "flow": "pr-review"}));
    tick(&world, now());
    assert!(log(&world, "reviews").queue().is_empty());
    assert!(log(&world, "reviews").last_guard_error().unwrap()["error"].as_str().unwrap().contains("lacks url"));
}

#[test]
fn a_pr_review_guard_queues_listed_repos_and_refuses_the_rest_once() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 0\n");
    world.write_automation("reviews", json!({"when": pr_lines(), "flow": "pr-review", "repos": ["acme/webapp"]}));
    tick(&world, now());
    tick(&world, now() + Duration::seconds(300));
    assert_eq!(keys(log(&world, "reviews").queue()), ["a"]);
    let evs = events(&world, "reviews");
    let refused: Vec<&Value> = evs.iter().filter(|e| e["event"] == "refused").collect();
    assert_eq!(refused.len(), 1);
    assert_eq!((&refused[0]["key"], &refused[0]["reason"]), (&json!("b"), &json!("repo stranger/fork isn't in this automation's repos")));
    assert_eq!(refused[0]["item"]["url"], "https://github.com/stranger/fork/pull/2");
    let run = log(&world, "reviews").recent(20).remove(0);
    assert_eq!((run.status.as_str(), run.key.as_deref()), ("refused", Some("b")));
}

#[test]
fn a_pr_review_automation_without_repos_queues_nothing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("reviews", json!({"when": pr_lines(), "flow": "pr-review"}));
    tick(&world, now());
    assert!(log(&world, "reviews").queue().is_empty() && world.sessions().is_empty());
    let refused: Vec<String> = events(&world, "reviews").iter().filter(|e| e["event"] == "refused").map(|e| e["key"].as_str().unwrap().to_string()).collect();
    assert_eq!(refused, ["a", "b"]);
    assert!(log(&world, "reviews").recent(20)[0].error.as_deref().unwrap().contains("no repos list"));
}

#[test]
fn a_queued_pr_review_run_whose_repo_left_the_list_is_refused_at_start() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("reviews", json!({"flow": "pr-review", "repos": ["acme/other"], "cron": ""}));
    let id = log(&world, "reviews").enqueue("a", &json!({"key": "a", "url": "https://github.com/acme/WebApp/pull/1"}), "pr-review", "manual", ago(60)).unwrap();
    let summary = tick(&world, now());
    assert!(world.sessions().is_empty() && summary.started.is_empty());
    let run = log(&world, "reviews").run(&id).unwrap();
    assert_eq!((run.status.as_str(), run.error.as_deref()), ("refused", Some("repo acme/WebApp isn't in this automation's repos")));
}

#[test]
fn paused_runs_no_guard_and_starts_nothing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_paused: true\n");
    let marker = world.dir.path().join("guard-ran");
    world.write_automation("triage", json!({"when": format!("touch {}; echo a", marker.display())}));
    queue(&world, "triage", "old", "manual", 60);
    let summary = tick(&world, now());
    assert!(!marker.exists() && world.sessions().is_empty());
    assert!(summary.paused);
    assert_eq!(automation_tick::state(&world.automations())["paused"], true);
}

/// The user's hand edit of `<slug>.yml`: Psych read `no`, `off` and the like as booleans.
fn hand_edit_enabled(world: &ChatWorld, slug: &str, spelling: &str) {
    let path = world.automations().join(format!("{slug}.yml"));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("enabled: true"), "{text}");
    std::fs::write(&path, text.replace("enabled: true", &format!("enabled: {spelling}"))).unwrap();
}

#[test]
fn enabled_spelled_the_yaml_1_1_way_or_not_a_boolean_turns_the_automation_off() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    for spelling in ["no", "No", "off", "OFF", "maybe"] {
        let world = ChatWorld::new("tick");
        let marker = world.dir.path().join("guard-ran");
        world.write_automation("triage", json!({"when": format!("touch {}; echo a", marker.display())}));
        hand_edit_enabled(&world, "triage", spelling);
        tick(&world, now());
        assert!(!marker.exists(), "enabled: {spelling} ran its guard");
    }
    let world = ChatWorld::new("tick");
    let marker = world.dir.path().join("guard-ran");
    world.write_automation("triage", json!({"when": format!("touch {}; echo a", marker.display())}));
    hand_edit_enabled(&world, "triage", "yes");
    tick(&world, now());
    assert!(marker.exists(), "enabled: yes should still run");
}

#[test]
fn local_paused_spelled_the_yaml_1_1_way_or_not_a_boolean_pauses() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    for (spelling, paused) in [("yes", true), ("On", true), ("maybe", true), ("no", false), ("off", false)] {
        let world = ChatWorld::new("tick");
        world.config(&format!("automations:\n  local_paused: {spelling}\n"));
        let marker = world.dir.path().join("guard-ran");
        world.write_automation("triage", json!({"when": format!("touch {}; echo a", marker.display())}));
        let summary = tick(&world, now());
        assert_eq!((summary.paused, marker.exists()), (paused, !paused), "local_paused: {spelling}");
    }
}

#[test]
fn a_disabled_automation_runs_no_guard_and_starts_only_its_manual_and_retry_runs() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 5\n");
    let marker = world.dir.path().join("guard-ran");
    world.write_automation("triage", json!({"when": format!("touch {}; echo a", marker.display()), "enabled": false}));
    queue(&world, "triage", "cron:2026-11-06T09:55:00Z", "cron", 240);
    queue(&world, "triage", "from-guard", "guard", 180);
    let manual = queue(&world, "triage", "by-hand", "manual", 120);
    let retried = queue(&world, "triage", "again", "retry", 60);
    let summary = tick(&world, now());
    assert!(!marker.exists());
    assert_eq!(pairs(&summary.started), [("triage", manual.as_str()), ("triage", retried.as_str())]);
    assert_eq!(world.sessions(), [format!("triage--run-{manual}"), format!("triage--run-{retried}")].iter().cloned().collect::<std::collections::BTreeSet<_>>().into_iter().collect::<Vec<_>>());
    assert_eq!(keys(log(&world, "triage").queue()), ["cron:2026-11-06T09:55:00Z", "from-guard"]);
}

#[test]
fn a_manual_run_of_a_disabled_automation_still_waits_while_paused_or_held() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("triage", json!({"enabled": false}));
    queue(&world, "triage", "by-hand", "manual", 60);
    world.config("automations:\n  local_paused: true\n");
    tick(&world, now());
    world.config("automations:\n  local_paused: false\n");
    world.rate_limits(now(), 99.0, 10.0, 3600);
    tick(&world, now() + Duration::seconds(300));
    assert!(world.sessions().is_empty());
    assert_eq!(keys(log(&world, "triage").queue()), ["by-hand"]);
}

#[test]
fn a_usage_limit_over_its_hold_starts_nothing_but_guards_still_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("triage", json!({"when": prints(&["a"])}));
    world.rate_limits(now(), 84.0, 10.0, 3600);
    let summary = tick(&world, now());
    assert_eq!(summary.held.as_deref(), Some("5h at 84%"));
    assert_eq!(keys(log(&world, "triage").queue()), ["a"]);
    assert!(world.sessions().is_empty());
}

#[test]
fn the_weekly_limit_holds_too() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    world.rate_limits(now(), 10.0, 91.0, 3600);
    assert_eq!(tick(&world, now()).held.as_deref(), Some("7d at 91%"));
}

#[test]
fn a_snapshot_whose_five_hour_window_has_reset_holds_nothing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    world.rate_limits(now(), 99.0, 99.0, -60);
    let summary = tick(&world, now());
    assert!(summary.held.is_none());
    assert_eq!(summary.started.len(), 1);
}

#[test]
fn the_cap_counts_runs_whose_session_works() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 1\n");
    world.write_automation("nightly", json!({}));
    live_run(&world, "nightly", "s-working", &[(60, "UserPromptSubmit", None)]);
    let summary = tick(&world, now());
    assert!(world.sessions().is_empty());
    assert_eq!(summary.running, 1);
    assert_eq!(log(&world, "nightly").queue().len(), 1);
}

#[test]
fn a_run_whose_turn_ended_frees_its_slot() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 1\n");
    world.write_automation("nightly", json!({}));
    live_run(&world, "nightly", "s-done", &[(120, "UserPromptSubmit", None), (60, "Stop", None)]);
    tick(&world, now());
    assert_eq!(world.sessions().len(), 1);
}

#[test]
fn a_run_whose_session_has_not_reported_yet_holds_its_slot_while_its_tmux_lives() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 1\n");
    world.write_automation("nightly", json!({}));
    let run_log = log(&world, "nightly");
    let id = run_log.enqueue("k", &Value::Null, "chat", "manual", ago(60)).unwrap();
    let name = format!("nightly--run-{id}");
    run_log.started(&id, "s-unseen", &name, "nightly", ago(60)).unwrap();
    assert!(world.tmux(&["new-session", "-d", "-s", &name, "sleep", "60"]).0);
    tick(&world, now());
    assert_eq!(world.sessions(), [name.clone()], "nothing new opened");
    world.tmux(&["kill-session", "-t", &name]);
    tick(&world, now() + Duration::seconds(300));
    assert_eq!(world.sessions().len(), 1, "the dead run's slot is free again");
}

#[test]
fn guard_items_queued_in_one_tick_start_in_the_order_the_guard_printed_them() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 1\n");
    let letters: Vec<String> = ('a'..='t').map(String::from).collect();
    let refs: Vec<&str> = letters.iter().map(String::as_str).collect();
    world.write_automation("triage", json!({"when": prints(&refs)}));
    tick(&world, now());
    assert_eq!(keys(log(&world, "triage").queue()), letters[1..]);
    assert_eq!(world.wait_started(1)[0].args.last().unwrap(), "Do the thing.\n\n## Item\n\na");
}

#[test]
fn queued_runs_start_oldest_first_across_automations() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.config("automations:\n  local_max_running: 1\n");
    world.write_automation("alpha", json!({"cron": ""}));
    world.write_automation("beta", json!({"cron": ""}));
    queue(&world, "alpha", "newer", "manual", 60);
    let older = queue(&world, "beta", "older", "manual", 120);
    tick(&world, now());
    assert_eq!(world.sessions(), [format!("beta--run-{older}")]);
    assert_eq!(keys(log(&world, "alpha").queue()), ["newer"]);
}

/// A flow that can't start yet (a Review chat already open) leaves the run queued with its reason and uses no
/// slot.
#[test]
fn a_run_its_flow_holds_back_stays_queued_with_its_reason_and_uses_no_slot() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("tick");
    world.config(&format!("{}automations:\n  local_max_running: 1\n", std::fs::read_to_string(world.root().join("config.yml")).unwrap()));
    std::fs::write(world.root().join("pr-inbox.json"), json!({"prs": [pr(1, "acme/WebApp"), pr(2, "acme/WebApp")], "ts": Utc::now().timestamp()}).to_string()).unwrap();
    world.write_automation("reviews", json!({"flow": "pr-review", "repos": ["acme/WebApp"], "cron": ""}));
    let item = |n: u32| json!({"key": format!("pr-{n}"), "url": format!("https://github.com/acme/WebApp/pull/{n}")});
    let waiting = queue_item(&world, "reviews", "pr-1", item(1), "pr-review", 120);
    let other = queue_item(&world, "reviews", "pr-2", item(2), "pr-review", 60);
    let slug = quartermaster::pr_review_start::item_for(&pr(1, "acme/WebApp")).unwrap().slug;
    assert!(world.tmux(&["new-session", "-d", "-s", &slug, "sleep", "60"]).0);
    tick(&world, now());
    tick(&world, now() + Duration::seconds(300));
    let (w, o) = (log(&world, "reviews").run(&waiting).unwrap(), log(&world, "reviews").run(&other).unwrap());
    assert_eq!(w.waiting.as_deref(), Some("Review chat for WebApp#1 is open"));
    assert!(w.queued() && o.live());
    assert_eq!(events(&world, "reviews").iter().filter(|e| e["event"] == "waiting").count(), 1);
}

#[test]
fn a_run_that_fails_to_start_is_marked_failed_and_the_tick_goes_on() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({"cron": ""}));
    let id = queue(&world, "nightly", "k", "manual", 60);
    assert!(world.tmux(&["new-session", "-d", "-s", &format!("nightly--run-{id}"), "sleep", "60"]).0);
    let summary = tick(&world, now());
    let run = log(&world, "nightly").run(&id).unwrap();
    assert_eq!(run.status, "failed");
    assert!(run.error.unwrap().contains("already running"));
    assert_eq!(pairs(&summary.failed), [("nightly", id.as_str())]);
}

#[test]
fn a_tick_while_another_holds_the_lock_does_nothing() {
    use std::os::unix::io::AsRawFd;
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    let lock = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).open(world.automations().join("tick.lock")).unwrap();
    // SAFETY: flock on a descriptor this test owns.
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
    assert!(matches!(AutomationTick::new(&world.automations()).call(now()), Some(Tick::Locked)));
    assert!(events(&world, "nightly").is_empty());
}

#[test]
fn a_tick_never_raises() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    let blocked = world.dir.path().join("not-a-dir");
    std::fs::write(&blocked, "a file where the automations directory should be").unwrap();
    assert!(AutomationTick::new(&blocked).call(now()).is_none());
    assert!(std::fs::read_to_string(world.root().join("qm.log")).unwrap().contains("automation-tick"));
}

#[test]
fn a_bad_cron_goes_in_the_problems_and_the_others_go_on() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("broken", json!({"cron": "60 * * * *"}));
    world.write_automation("fine", json!({}));
    let summary = tick(&world, now());
    assert_eq!(summary.problems["broken"], "cron \"60 * * * *\": minute: \"60\" is outside 0-59");
    assert_eq!(summary.started.len(), 1);
    assert_eq!(automation_tick::state(&world.automations())["problems"]["broken"], summary.problems["broken"]);
}

#[test]
fn a_dry_run_lists_what_the_guard_would_queue_and_writes_nothing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("triage", json!({"when": prints(&["a", "b", r#"{"x":1}"#, "b"])}));
    log(&world, "triage").mark_seen(&["a".to_string()], now()).unwrap();
    let before = events(&world, "triage");
    let dry = AutomationTick::new(&world.automations()).dry_run("triage").unwrap();
    assert_eq!(dry.items, [json!({"key": "b", "line": "b"})]);
    assert_eq!(dry.seen, [json!({"key": "a", "line": "a"}), json!({"key": "b", "line": "b"})]);
    assert_eq!(dry.problems.iter().map(|p| p["error"].clone()).collect::<Vec<_>>(), [json!("a guard's JSON item needs a string key")]);
    assert_eq!(events(&world, "triage"), before);
}

#[test]
fn a_dry_run_of_an_automation_without_a_guard_says_so() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("nightly", json!({}));
    assert!(AutomationTick::new(&world.automations()).dry_run("nightly").unwrap_err().contains("has no guard"));
    assert!(AutomationTick::new(&world.automations()).dry_run("nope").unwrap_err().contains("no automation nope"));
}

#[test]
fn queue_guard_queues_new_items_as_a_manual_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("triage", json!({"when": prints(&["a"])}));
    let ids = AutomationTick::new(&world.automations()).queue_guard("triage", "manual", now()).unwrap();
    assert_eq!(ids.iter().map(|id| log(&world, "triage").run(id).unwrap().trigger.unwrap()).collect::<Vec<_>>(), ["manual"]);
    world.write_automation("bad", json!({"when": "echo no >&2; exit 1"}));
    assert_eq!(AutomationTick::new(&world.automations()).queue_guard("bad", "manual", now()).unwrap_err(), "guard failed: no");
    assert_eq!(log(&world, "bad").last_guard_error().unwrap()["error"], "guard failed: no");
}

#[test]
fn a_cloud_automation_is_not_a_local_one() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("tick");
    world.write_automation("digest", json!({"runner": "cloud"}));
    let tick = AutomationTick::new(&world.automations());
    assert!(tick.dry_run("digest").unwrap_err().contains("runs on claude.ai, not locally"));
}
