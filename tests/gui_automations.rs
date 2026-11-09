//! The ⚙ area's Automations tab, server side: `/api/automations…` through the router's own function with a
//! stand-in routines client (no keychain, no network). Network work runs as GUI jobs; each test waits for them
//! to settle. The `runner: local` part is `gui_local_automations.rs`, the HTTP rules (Origin, assets) are
//! `gui_automations_http.rs`.

mod common;
use common::chat::ChatWorld;
use common::routines::{self, client, id, Stub};
use quartermaster::automation_store::AutomationStore;
use quartermaster::automations::Automations;
use quartermaster::gui_automations::{forget, respond_with};
use quartermaster::gui_jobs;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV: Mutex<()> = Mutex::new(());
const ON: &str = "automations:\n  token_source: claude_code\n";

struct World {
    chat: ChatWorld,
    stub: Stub,
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl World {
    fn new() -> World {
        let lock = ENV.lock().unwrap_or_else(|p| p.into_inner());
        let chat = ChatWorld::new("guiauto");
        chat.config(ON);
        forget();
        gui_jobs::take_finished();
        World { chat, stub: routines::install(), _lock: lock }
    }

    fn call(&self, method: &str, route: &str, payload: Value) -> (String, Value) {
        let (status, _type, body) = respond_with(client, method, route, payload.to_string().as_bytes()).expect("an automations route");
        (status.to_string(), serde_json::from_slice(&body).unwrap_or(Value::Null))
    }

    fn get(&self, route: &str) -> Value {
        let (status, body) = self.call("GET", route, json!({}));
        assert_eq!(status, "200 OK", "{body}");
        body
    }

    fn post(&self, route: &str, payload: Value) -> (String, Value) {
        self.call("POST", route, payload)
    }

    /// The finished jobs, once every running one is done.
    fn settle(&self) -> Vec<Value> {
        let until = Instant::now() + Duration::from_secs(10);
        while !gui_jobs::running().is_empty() {
            assert!(Instant::now() < until, "jobs did not settle");
            std::thread::sleep(Duration::from_millis(20));
        }
        gui_jobs::take_finished()
    }

    fn store(&self) -> AutomationStore {
        AutomationStore::current()
    }

    fn adopt(&self) {
        Automations::new(&*client(), self.store()).adopt(&id(), "MyApp", Some("digest")).unwrap();
        self.stub.clear_calls();
    }

    fn record(&self, key: &str) -> Value {
        self.store().read("digest").unwrap().unwrap().record.get(key).cloned().unwrap_or(Value::Null)
    }

    fn history(&self) -> Vec<String> {
        WorkItem::find("digest").unwrap().notes().into_iter().filter(|n| n.kind == "history").map(|n| n.text).collect()
    }
}

fn row<'a>(payload: &'a Value, slug: &str) -> &'a Value {
    payload["rows"].as_array().unwrap().iter().find(|r| r["slug"] == slug).unwrap()
}

#[test]
fn the_list_answers_the_local_files_at_once_and_the_routines_after_one_list_call() {
    let w = World::new();
    w.adopt();
    let first = w.get("/api/automations");
    assert!(w.stub.calls().is_empty(), "the list itself never touches the network");
    assert_eq!(first["remote"]["state"], "idle");
    let r = row(&first, "digest");
    assert_eq!((&r["project"], &r["state"], &r["cron"], &r["runner"]), (&json!("MyApp"), &json!("active"), &json!("0 7 * * 1,4"), &json!("cloud")));
    assert_eq!(r["schedule"]["days"], json!([1, 4]));

    let (status, answer) = w.post("/api/automations/refresh", json!({}));
    assert_eq!((status.as_str(), &answer["background"]), ("200 OK", &json!(true)));
    assert_eq!(w.settle().iter().map(|j| j["quiet"].clone()).collect::<Vec<_>>(), [json!(true)]);
    assert_eq!(w.stub.calls(), [json!(["list"])]);

    let listed = w.get("/api/automations");
    assert_eq!(listed["remote"]["state"], "ok");
    let r = row(&listed, "digest");
    assert_eq!(r["drift"], false);
    assert_eq!(r["nextRunAt"], routines::digest()["next_run_at"]);
    assert_eq!(r["routineUrl"], format!("https://claude.ai/code/routines/{}", id()));
}

#[test]
fn routines_without_local_files_are_listed_for_adoption_and_adopt_takes_them_in() {
    let w = World::new();
    w.post("/api/automations/refresh", json!({}));
    w.settle();
    let unmanaged = w.get("/api/automations")["unmanaged"].clone();
    assert_eq!(unmanaged.as_array().unwrap().iter().map(|r| (r["id"].clone(), r["name"].clone(), r["cron"].clone())).collect::<Vec<_>>(), [(json!(id()), routines::digest()["name"].clone(), json!("0 7 * * 1,4"))]);

    let (_, answer) = w.post("/api/automations/adopt", json!({"id": id(), "project": "MyApp", "slug": "digest"}));
    assert_eq!(answer["background"], true);
    let jobs = w.settle();
    let job = jobs.iter().find(|j| j["key"] == format!("automation-adopt-{}", id())).unwrap();
    assert_eq!((&job["ok"], &job["automation"]), (&json!(true), &json!("digest")));

    let listed = w.get("/api/automations");
    assert!(listed["unmanaged"].as_array().unwrap().is_empty());
    assert_eq!((&row(&listed, "digest")["project"], &row(&listed, "digest")["state"]), (&json!("MyApp"), &json!("active")));
    assert!(WorkItem::find("digest").unwrap().automation());
    let (status, answer) = w.post("/api/automations/adopt", json!({"id": id()}));
    assert_eq!((status.as_str(), answer["error"].as_str()), ("422 Unprocessable Content", Some(format!("pick a project for {}", id()).as_str())));
}

#[test]
fn a_routine_changed_outside_qm_shows_drift_until_pulled() {
    let w = World::new();
    w.adopt();
    w.stub.touch(&id());
    w.post("/api/automations/refresh", json!({}));
    w.settle();
    assert_eq!(row(&w.get("/api/automations"), "digest")["drift"], true);
    assert_eq!(w.get("/api/automations/digest")["drift"], true);

    w.post("/api/automations/pull", json!({"slug": "digest"}));
    assert_eq!(w.settle().iter().map(|j| j["ok"].clone()).collect::<Vec<_>>(), [json!(true)]);
    assert_eq!(row(&w.get("/api/automations"), "digest")["drift"], false);
}

#[test]
fn apply_saves_the_schedule_and_prompt_locally_then_pushes() {
    let w = World::new();
    w.adopt();
    let (status, answer) = w.post("/api/automations/apply", json!({"slug": "digest", "cron": "30 6 * * 1", "prompt": "New prompt."}));
    assert_eq!((status.as_str(), &answer["background"]), ("200 OK", &json!(true)));
    let saved = w.store().read("digest").unwrap().unwrap();
    assert_eq!((saved.record["cron"].clone(), saved.prompt), (json!("30 6 * * 1"), "New prompt.".to_string()));

    let jobs = w.settle();
    let job = jobs.iter().find(|j| j["key"] == "automation-digest").unwrap();
    assert_eq!(job["ok"], true, "{job}");
    assert_eq!(w.stub.routine(&id()).unwrap()["cron_expression"], "30 6 * * 1");
    assert!(w.stub.calls_named("update")[0][2].as_object().unwrap().contains_key("prompt"));
    assert!(w.history().iter().any(|t| t.starts_with("pushed: schedule → Mon") && t.contains("prompt changed")), "{:?}", w.history());
}

#[test]
fn apply_turns_weekdays_and_a_local_time_into_the_utc_cron() {
    let w = World::new();
    w.adopt();
    w.post("/api/automations/apply", json!({"slug": "digest", "days": [1, 5], "time": "09:30"}));
    w.settle();
    // Amsterdam is UTC+1 in winter and UTC+2 in summer.
    let expected = if quartermaster::local_schedule::offset_minutes(chrono::Utc::now()) == 60 { "30 8 * * 1,5" } else { "30 7 * * 1,5" };
    assert_eq!(w.record("cron"), expected);
}

#[test]
fn apply_refuses_a_cron_that_isnt_five_fields_and_writes_nothing() {
    let w = World::new();
    w.adopt();
    let (status, answer) = w.post("/api/automations/apply", json!({"slug": "digest", "cron": "every monday"}));
    assert_eq!((status.as_str(), &answer["ok"]), ("422 Unprocessable Content", &json!(false)));
    assert!(answer["error"].as_str().unwrap().contains("five fields"), "{answer}");
    assert_eq!(w.record("cron"), "0 7 * * 1,4");
    assert!(gui_jobs::running().is_empty());
}

#[test]
fn pause_resume_run_and_delete_run_as_jobs_and_move_the_item() {
    let w = World::new();
    w.adopt();
    w.post("/api/automations/pause", json!({"slug": "digest"}));
    w.settle();
    assert_eq!((WorkItem::find("digest").unwrap().state().as_deref(), w.stub.routine(&id()).unwrap()["enabled"].clone()), (Some("fridge"), json!(false)));
    assert_eq!(row(&w.get("/api/automations"), "digest")["enabled"], false);

    w.post("/api/automations/resume", json!({"slug": "digest"}));
    w.settle();
    assert_eq!(WorkItem::find("digest").unwrap().state().as_deref(), Some("active"));

    w.post("/api/automations/run", json!({"slug": "digest"}));
    assert!(w.settle().iter().any(|j| j["message"].as_str().is_some_and(|m| m.contains("running"))));
    assert!(w.stub.calls().contains(&json!(["run", id()])));

    w.post("/api/automations/delete", json!({"slug": "digest"}));
    let jobs = w.settle();
    assert!(jobs[0]["message"].as_str().unwrap().contains("delete it on claude.ai"), "{}", jobs[0]);
    assert_eq!(WorkItem::find("digest").unwrap().state().as_deref(), Some("resolved"));
}

#[test]
fn a_stale_apply_is_refused_and_the_list_call_after_it_shows_the_drift() {
    let w = World::new();
    w.adopt();
    w.stub.touch(&id());
    w.post("/api/automations/apply", json!({"slug": "digest", "cron": "30 6 * * 1"}));
    let jobs = w.settle();
    assert_eq!(jobs[0]["ok"], false);
    assert!(w.stub.calls().contains(&json!(["list"])));
    assert_eq!(row(&w.get("/api/automations"), "digest")["drift"], true);
}

#[test]
fn a_routine_gone_from_claude_ai_shows_as_missing_even_when_none_are_left() {
    let w = World::new();
    w.adopt();
    w.stub.forget_routines();
    w.post("/api/automations/refresh", json!({}));
    w.settle();
    assert_eq!(row(&w.get("/api/automations"), "digest")["missing"], true);
}

#[test]
fn pushing_a_routine_gone_from_claude_ai_says_so_not_that_the_api_changed() {
    let w = World::new();
    w.adopt();
    w.stub.forget_routines();
    w.post("/api/automations/push", json!({"slug": "digest"}));
    let jobs = w.settle();
    assert_eq!(jobs[0]["ok"], false);
    assert_eq!(jobs[0]["error"], format!("digest: routine {} isn't on claude.ai any more — delete the automation in qm (`qm automation delete digest`) or re-create it (`qm automation push digest --recreate`)", id()));
}

#[test]
fn recreate_makes_a_new_routine_for_a_missing_one_and_the_detail_stops_showing_missing() {
    let w = World::new();
    w.adopt();
    w.stub.forget_routines();
    w.post("/api/automations/refresh", json!({}));
    w.settle();
    assert_eq!(w.get("/api/automations/digest")["missing"], true);

    let (status, _) = w.post("/api/automations/recreate", json!({"slug": "digest"}));
    assert_eq!(status, "200 OK");
    let jobs = w.settle();
    assert_eq!(jobs[0]["ok"], true, "{}", jobs[0]);
    assert_eq!(jobs[0]["message"], format!("digest: re-created routine trig_NEW (was {})", id()));
    assert_eq!((w.record("routine"), WorkItem::find("digest").unwrap().routine().as_deref().map(String::from)), (json!("trig_NEW"), Some("trig_NEW".into())));
    let detail = w.get("/api/automations/digest");
    assert_eq!((&detail["missing"], &detail["routine"]), (&json!(false), &json!("trig_NEW")));
}

#[test]
fn recreate_refuses_a_routine_that_is_still_there() {
    let w = World::new();
    w.adopt();
    w.post("/api/automations/refresh", json!({}));
    w.settle();
    assert_eq!(row(&w.get("/api/automations"), "digest")["missing"], false);

    w.post("/api/automations/recreate", json!({"slug": "digest"}));
    let jobs = w.settle();
    assert_eq!(jobs[0]["ok"], false);
    assert_eq!(jobs[0]["error"], format!("digest: routine {} is still on claude.ai — `qm automation push digest` updates it", id()));
    assert_eq!(w.record("routine"), json!(id()));
    assert!(w.stub.calls_named("create").is_empty());
}

#[test]
fn force_push_overwrites_a_drifted_routine() {
    let w = World::new();
    w.adopt();
    w.stub.touch(&id());
    let entry = w.store().read("digest").unwrap().unwrap();
    w.store().write("digest", json!({"name": "Renamed"}).as_object().unwrap(), &entry.prompt).unwrap();
    w.post("/api/automations/push", json!({"slug": "digest", "force": true}));
    let jobs = w.settle();
    assert_eq!(jobs[0]["ok"], true, "{}", jobs[0]);
    assert_eq!(w.stub.routine(&id()).unwrap()["name"], "Renamed");
}

#[test]
fn the_detail_answers_the_local_files_and_loads_the_last_runs_on_request() {
    let w = World::new();
    w.adopt();
    let detail = w.get("/api/automations/digest");
    assert_eq!((&detail["runs"], &detail["runsState"]), (&Value::Null, &json!("idle")));
    assert_eq!(detail["promptPath"], w.store().prompt_path("digest").unwrap().to_string_lossy().as_ref());
    assert_eq!(detail["item"]["project"], "MyApp");
    assert!(w.stub.calls().is_empty());

    w.post("/api/automations/runs", json!({"slug": "digest"}));
    assert_eq!(w.settle().iter().map(|j| j["quiet"].clone()).collect::<Vec<_>>(), [json!(true)]);
    let detail = w.get("/api/automations/digest");
    assert_eq!(detail["runsState"], "ok");
    assert_eq!(detail["runs"][0]["url"], "https://claude.ai/code/cse_1");
    assert_eq!(w.stub.calls(), [json!(["runs", id(), 10])], "runs alone, no GET of the routine");
}

/// Loads the runs, does `then`, and answers the runs and state the detail shows after.
fn load_runs_then(w: &World, then: impl FnOnce()) -> (Option<String>, Value) {
    w.post("/api/automations/runs", json!({"slug": "digest"}));
    w.settle();
    assert_eq!(w.get("/api/automations/digest")["runsState"], "ok");
    then();
    w.settle();
    let detail = w.get("/api/automations/digest");
    (detail["runs"][0]["id"].as_str().map(String::from), detail["runsState"].clone())
}

#[test]
fn runs_go_back_to_idle_after_an_action_on_that_automation_so_the_page_asks_again() {
    let w = World::new();
    w.adopt();
    assert_eq!(load_runs_then(&w, || { w.post("/api/automations/run", json!({"slug": "digest"})); }), (Some("cse_1".into()), json!("idle")));
}

#[test]
fn runs_go_back_to_idle_after_a_refused_action_too() {
    let w = World::new();
    w.adopt();
    w.stub.touch(&id());
    assert_eq!(load_runs_then(&w, || { w.post("/api/automations/apply", json!({"slug": "digest", "cron": "30 6 * * 1"})); }), (Some("cse_1".into()), json!("idle")));
}

#[test]
fn a_refresh_sends_the_shown_runs_back_to_idle() {
    let w = World::new();
    w.adopt();
    assert_eq!(load_runs_then(&w, || { w.post("/api/automations/refresh", json!({})); }), (Some("cse_1".into()), json!("idle")));
}

// Opening the tab asks for runs and refreshes at once: runs that arrive while that refresh is under way are
// already fresh.
#[test]
fn runs_loaded_during_a_refresh_stay_loaded() {
    let w = World::new();
    w.adopt();
    let (go, gate) = std::sync::mpsc::channel();
    w.stub.gate(gate);
    w.post("/api/automations/refresh", json!({}));
    w.post("/api/automations/runs", json!({"slug": "digest"}));
    let until = Instant::now() + Duration::from_secs(10);
    while w.get("/api/automations/digest")["runsState"] != "ok" {
        assert!(Instant::now() < until, "the runs never loaded");
        std::thread::sleep(Duration::from_millis(20));
    }
    go.send(()).unwrap();
    w.settle();
    assert_eq!(w.get("/api/automations/digest")["runsState"], "ok");
}

#[test]
fn new_creates_the_item_and_its_empty_files_for_the_chat_to_fill() {
    let w = World::new();
    let (status, answer) = w.post("/api/automations/new", json!({"title": "Weekly report", "project": "MyApp"}));
    assert_eq!((status.as_str(), &answer["ok"], &answer["slug"]), ("200 OK", &json!(true), &json!("weekly-report")));
    let item = WorkItem::find("weekly-report").unwrap();
    assert_eq!((item.automation(), item.runner().as_deref().map(String::from), item.state().as_deref().map(String::from)), (true, Some("cloud".into()), Some("in_progress".into())));
    assert_eq!(w.store().read("weekly-report").unwrap().unwrap().prompt, "");
    assert!(w.stub.calls().is_empty());
    let (status, answer) = w.post("/api/automations/new", json!({"title": "", "project": "MyApp"}));
    assert_eq!((status.as_str(), answer["error"].as_str()), ("422 Unprocessable Content", Some("an automation needs a title and a project")));
}

#[test]
fn new_with_runner_local_creates_a_disabled_local_automation() {
    let w = World::new();
    let (status, answer) = w.post("/api/automations/new", json!({"title": "Weekly report", "project": "MyApp", "runner": "local"}));
    assert_eq!((status.as_str(), &answer["slug"]), ("200 OK", &json!("weekly-report")));
    let item = WorkItem::find("weekly-report").unwrap();
    assert_eq!((item.runner().as_deref().map(String::from), item.state().as_deref().map(String::from)), (Some("local".into()), Some("in_progress".into())));
    let record = w.store().read("weekly-report").unwrap().unwrap().record;
    assert_eq!((&record["enabled"], &record["runner"]), (&json!(false), &json!("local")));
    assert!(w.stub.calls().is_empty());
}

#[test]
fn off_until_the_token_source_is_set_and_nothing_reaches_the_client() {
    let w = World::new();
    w.chat.config("");
    let remote = w.get("/api/automations")["remote"].clone();
    assert_eq!((&remote["state"], &remote["command"]), (&json!("off"), &json!("qm config set automations.token_source claude_code")));
    let (_, answer) = w.post("/api/automations/refresh", json!({}));
    assert_eq!(answer["remote"]["state"], "off");
    assert!(gui_jobs::running().is_empty());
    assert!(w.stub.calls().is_empty());
}

#[test]
fn an_expired_token_is_a_state_of_the_tab_not_an_error_toast() {
    let w = World::new();
    w.adopt();
    w.stub.fail_with(quartermaster::routines_client::TOKEN_EXPIRED, "Claude Code's login token expired — open any Claude Code session, then refresh");
    w.post("/api/automations/refresh", json!({}));
    assert_eq!(w.settle().iter().map(|j| j["quiet"].clone()).collect::<Vec<_>>(), [json!(true)]);
    let remote = w.get("/api/automations")["remote"].clone();
    assert_eq!(remote["state"], "expired");
    assert!(remote["message"].as_str().unwrap().contains("login token expired"));

    w.post("/api/automations/run", json!({"slug": "digest"}));
    let jobs = w.settle();
    assert_eq!((&jobs[0]["ok"], &jobs[0]["quiet"]), (&json!(false), &json!(true)));
}

#[test]
fn the_detail_of_an_unknown_automation_and_a_stray_verb_are_refused_or_unrouted() {
    let w = World::new();
    let (status, answer) = w.call("GET", "/api/automations/nope", json!({}));
    assert_eq!((status.as_str(), answer["error"].as_str()), ("422 Unprocessable Content", Some("no automation 'nope'")));
    assert!(respond_with(client, "POST", "/api/automations/whatever", b"{}").is_none());
    assert!(respond_with(client, "GET", "/api/other", b"").is_none());
    w.adopt();
    let (_, answer) = w.post("/api/automations/retry", json!({"slug": "digest"}));
    assert_eq!(answer["error"], "retry is for local automations");
}
