//! The Automations tab's `runner: local` part: rows, detail and actions from the store and run logs, never the
//! routines client. Runs open in a tmux on a throwaway `qm-test-…` socket with a stand-in for claude, the guard
//! is a harmless `printf`, launchctl is a stand-in on PATH and the LaunchAgents folder lives under a temp HOME.

mod common;
use chrono::{DateTime, SubsecRound, Utc};
use common::chat::ChatWorld;
use common::routines::client;
use quartermaster::automation_store::AutomationStore;
use quartermaster::gui_automations::{forget, respond_with};
use quartermaster::gui_jobs;
use quartermaster::run_log::RunLog;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV: Mutex<()> = Mutex::new(());
const ON: &str = "automations:\n  token_source: claude_code\n";

struct World {
    chat: ChatWorld,
    _lock: std::sync::MutexGuard<'static, ()>,
}

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0)
}

impl World {
    fn new() -> World {
        let lock = ENV.lock().unwrap_or_else(|p| p.into_inner());
        let chat = ChatWorld::new("guilocal");
        chat.config(ON);
        forget();
        gui_jobs::take_finished();
        let launchctl = chat.dir.path().join("bin/launchctl");
        std::fs::write(&launchctl, "#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s ' \"$@\" >> \"$d/launchctl.log\"\necho >> \"$d/launchctl.log\"\n").unwrap();
        std::fs::set_permissions(&launchctl, std::fs::Permissions::from_mode(0o755)).unwrap();
        World { chat, _lock: lock }
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

    fn settle(&self) -> Vec<Value> {
        let until = Instant::now() + Duration::from_secs(20);
        while !gui_jobs::running().is_empty() {
            assert!(Instant::now() < until, "jobs did not settle");
            std::thread::sleep(Duration::from_millis(20));
        }
        gui_jobs::take_finished()
    }

    fn store(&self) -> AutomationStore {
        AutomationStore::current()
    }

    fn log(&self) -> RunLog {
        RunLog::new("nightly", &self.chat.automations()).unwrap()
    }

    fn automation(&self, record: Value) {
        let mut item = WorkItem::create("Nightly", "MyApp", None, None, None, None).unwrap();
        item.make_automation("local").unwrap();
        let mut full = json!({"name": "Nightly", "cron": "0 8 * * 1,4"});
        full.as_object_mut().unwrap().extend(record.as_object().unwrap().clone());
        self.chat.write_automation("nightly", full);
    }

    /// A run that started (session sess-<id>) in its own --run- chat.
    fn started_run(&self, key: &str, item: Value) -> String {
        let log = self.log();
        let id = log.enqueue(key, &item, "chat", "guard", now()).unwrap();
        log.started(&id, &format!("sess-{id}"), &format!("nightly--run-{id}"), "nightly", now()).unwrap();
        id
    }

    fn launchctl_calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.chat.dir.path().join("bin/launchctl.log")).unwrap_or_default().lines().map(|l| l.trim().to_string()).collect()
    }
}

fn thing(key: &str, title: &str) -> Value {
    json!({"key": key, "title": title})
}

#[test]
fn a_local_row_reads_its_cron_in_local_time_and_its_last_run_from_the_run_log() {
    let w = World::new();
    w.automation(json!({}));
    let id = w.started_run("a", thing("a", "Thing A"));
    w.log().finished(&id, now()).unwrap();
    let list = w.get("/api/automations");
    let row = &list["rows"][0];
    let schedule = &row["schedule"];
    assert_eq!((&row["runner"], &schedule["label"], &schedule["days"], &schedule["time"], &schedule["raw"]), (&json!("local"), &json!("Mon, Thu 08:00"), &json!([1, 4]), &json!("08:00"), &json!(false)));
    assert_eq!(row["lastRun"]["status"], "finished");
    let next = row["nextRunAt"].as_str().unwrap();
    assert!(next.ends_with("T06:00:00Z") || next.ends_with("T07:00:00Z"), "08:00 Amsterdam is 06:00 or 07:00 UTC: {next}");
    let header = &list["local"];
    assert_eq!((&header["count"], &header["installed"], &header["lastTickAt"], &header["stale"], &header["paused"], &header["maxRunning"]), (&json!(1), &json!(false), &Value::Null, &json!(true), &json!(false), &json!(2)));
}

#[test]
fn the_local_detail_has_its_guard_queue_runs_and_last_guard_error() {
    let w = World::new();
    w.automation(json!({"when": "printf 'a\\nb\\n'"}));
    let live = w.started_run("a", thing("a", "Thing A"));
    w.chat.tmux(&["new-session", "-d", "-s", &format!("nightly--run-{live}"), "sleep 60"]);
    let ended = w.started_run("b", json!({"key": "b"}));
    w.log().failed(&ended, "boom", now()).unwrap();
    let waiting = w.log().enqueue("c", &json!({"key": "c"}), "chat", "guard", now()).unwrap();
    w.log().waiting(&waiting, "Review chat for o/r#1 is open", now()).unwrap();
    w.log().guard_error("guard failed: exit 2", None, now()).unwrap();
    let refused = w.log().refuse_item("d", &json!({"key": "d", "url": "u"}), "chat", "guard", "repo o/r isn't in this automation's repos", now()).unwrap().unwrap();

    let d = w.get("/api/automations/nightly");
    assert_eq!((&d["guard"], &d["flow"], &d["notify"], &d["timeoutMinutes"], &d["runsState"]), (&json!("printf 'a\\nb\\n'"), &json!("chat"), &json!("attention"), &json!(30), &json!("ok")));
    assert_eq!(d["guardError"]["error"], "guard failed: exit 2");
    assert_eq!((&d["queue"][0]["id"], &d["queue"][0]["subject"], &d["queue"][0]["waiting"]), (&json!(waiting), &json!("c"), &json!("Review chat for o/r#1 is open")));
    let runs = d["runs"].as_array().unwrap();
    let run = |id: &str| runs.iter().find(|r| r["id"] == id).unwrap();
    let pick = |r: &Value, keys: &[&str]| keys.iter().map(|k| r[*k].clone()).collect::<Vec<_>>();
    assert_eq!(pick(run(&live), &["status", "subject", "chat", "resumable", "retryable"]), [json!("live"), json!("Thing A"), json!(format!("nightly--run-{live}")), json!(false), json!(false)]);
    assert_eq!(pick(run(&ended), &["status", "error", "chat", "resumable", "retryable"]), [json!("failed"), json!("boom"), Value::Null, json!(true), json!(true)]);
    assert_eq!(pick(run(&refused), &["status", "error", "resumable", "retryable"]), [json!("refused"), json!("repo o/r isn't in this automation's repos"), json!(false), json!(true)]);
    assert_eq!(d["item"]["title"], "Nightly");
}

#[test]
fn apply_saves_a_local_cron_unshifted_and_pushes_nothing() {
    let w = World::new();
    w.automation(json!({}));
    let (status, answer) = w.post("/api/automations/apply", json!({"slug": "nightly", "days": [1, 4], "time": "06:30", "prompt": "New.\n"}));
    assert_eq!((status.as_str(), &answer["ok"], &answer["background"]), ("200 OK", &json!(true), &Value::Null));
    let saved = w.store().read("nightly").unwrap().unwrap();
    assert_eq!((saved.record["cron"].clone(), saved.prompt), (json!("30 6 * * 1,4"), "New.\n".to_string()));

    let (status, answer) = w.post("/api/automations/apply", json!({"slug": "nightly", "cron": "61 * * * *"}));
    assert_eq!(status, "422 Unprocessable Content");
    assert!(answer["error"].as_str().unwrap().contains("minute"), "{answer}");
    assert_eq!(w.store().read("nightly").unwrap().unwrap().record["cron"], "30 6 * * 1,4");
}

#[test]
fn claude_ai_verbs_are_refused_for_a_local_automation() {
    let w = World::new();
    w.automation(json!({}));
    for verb in ["push", "pull", "recreate"] {
        let (status, answer) = w.post(&format!("/api/automations/{verb}"), json!({"slug": "nightly"}));
        assert_eq!((status.as_str(), answer["error"].as_str()), ("422 Unprocessable Content", Some("nightly runs locally — nothing on claude.ai")));
    }
    assert!(gui_jobs::running().is_empty());
}

#[test]
fn run_now_queues_a_manual_run_and_one_tick_starts_it_in_its_own_chat() {
    let w = World::new();
    w.automation(json!({}));
    let (_, answer) = w.post("/api/automations/run", json!({"slug": "nightly"}));
    assert_eq!(answer["background"], true);
    let jobs = w.settle();
    assert_eq!((&jobs[0]["ok"], &jobs[0]["message"], &jobs[0]["key"]), (&json!(true), &json!("nightly: started 1 run"), &json!("automation-nightly")));
    let run = w.log().recent(1).remove(0);
    assert_eq!((run.trigger.as_deref(), run.status.as_str()), (Some("manual"), "live"));
    assert_eq!(w.chat.sessions(), [format!("nightly--run-{}", run.id)]);
}

// A tick that holds the run back says why; Run now repeats it.
#[test]
fn run_now_names_why_a_run_stays_queued() {
    let w = World::new();
    w.automation(json!({}));
    w.chat.config(&format!("{ON}  local_paused: true\n"));
    w.post("/api/automations/run", json!({"slug": "nightly"}));
    assert_eq!(w.settle()[0]["message"], "nightly: queued 1 (local automations are paused)");
    assert!(w.chat.sessions().is_empty());
}

#[test]
fn enable_with_mark_existing_as_seen_records_the_guards_keys_without_queuing() {
    let w = World::new();
    w.automation(json!({"when": "printf 'a\\nb\\n'", "enabled": false}));
    w.post("/api/automations/resume", json!({"slug": "nightly", "skipExisting": true}));
    let jobs = w.settle();
    assert_eq!(jobs[0]["message"], "nightly: enabled, 2 existing items marked seen");
    assert_eq!(w.store().read("nightly").unwrap().unwrap().record["enabled"], true);
    let mut seen: Vec<String> = w.log().seen_keys().into_iter().collect();
    seen.sort();
    assert_eq!((seen, w.log().queue().len()), (vec!["a".to_string(), "b".to_string()], 0));
    assert_eq!(WorkItem::find("nightly").unwrap().state().as_deref(), Some("active"));

    let (_, answer) = w.post("/api/automations/pause", json!({"slug": "nightly"}));
    assert_eq!((&answer["ok"], &answer["message"]), (&json!(true), &json!("nightly: paused")));
    assert_eq!((w.store().read("nightly").unwrap().unwrap().record["enabled"].clone(), WorkItem::find("nightly").unwrap().state()), (json!(false), Some("fridge".to_string())));
}

#[test]
fn retry_queues_an_ended_runs_item_again_and_resume_reopens_its_session() {
    let w = World::new();
    w.automation(json!({}));
    let id = w.started_run("a", thing("a", "Thing A"));
    w.log().closed(&id, now()).unwrap();
    w.post("/api/automations/retry", json!({"slug": "nightly", "run": id}));
    assert_eq!(w.settle()[0]["message"], "nightly: started 1 retry");
    let retried = w.log().run(&id).unwrap().retried_as.unwrap();
    let again = w.log().run(&retried).unwrap();
    assert_eq!((again.item, again.trigger.as_deref()), (thing("a", "Thing A"), Some("retry")));
    w.chat.reset_chats();

    let (_, answer) = w.post("/api/automations/resume-run", json!({"slug": "nightly", "run": id}));
    assert_eq!((&answer["ok"], &answer["name"]), (&json!(true), &json!(format!("nightly--run-{id}"))));
    let started = w.chat.wait_started(1).remove(0);
    assert_eq!((started.item.as_str(), started.args), ("nightly", vec!["--resume".to_string(), format!("sess-{id}")]));
    let (_, answer) = w.post("/api/automations/resume-run", json!({"slug": "nightly", "run": id}));
    assert_eq!(answer["error"], format!("run {id}'s chat is already open"));
}

#[test]
fn install_and_uninstall_tick_drive_launchctl_as_jobs() {
    let w = World::new();
    w.automation(json!({}));
    let (_, answer) = w.post("/api/automations/install-tick", json!({}));
    assert_eq!(answer["background"], true);
    assert_eq!(w.settle()[0]["ok"], true);
    let plist = std::path::PathBuf::from(std::env::var("HOME").unwrap()).join("Library/LaunchAgents/com.quartermaster.automation-tick.plist");
    assert!(plist.exists());
    let calls = w.launchctl_calls();
    assert!(calls.iter().any(|c| c.starts_with("bootstrap gui/") && c.ends_with(&plist.to_string_lossy().to_string())), "{calls:?}");
    assert_eq!(w.get("/api/automations")["local"]["installed"], true);

    w.post("/api/automations/uninstall-tick", json!({}));
    assert_eq!(w.settle()[0]["ok"], true);
    assert!(!plist.exists());
    assert!(w.launchctl_calls().iter().any(|c| c.starts_with("bootout gui/") && c.ends_with("/com.quartermaster.automation-tick")));
}

#[test]
fn the_pause_toggle_writes_config() {
    let w = World::new();
    w.automation(json!({}));
    let (_, answer) = w.post("/api/automations/local-pause", json!({"paused": true}));
    assert_eq!((&answer["ok"], &answer["paused"]), (&json!(true), &json!(true)));
    assert_eq!(w.get("/api/automations")["local"]["paused"], true);
    assert!(std::fs::read_to_string(w.chat.root().join("config.yml")).unwrap().contains("local_paused: true"));
}

#[test]
fn delete_and_pause_of_a_local_automation_answer_at_once() {
    let w = World::new();
    w.automation(json!({}));
    let (_, answer) = w.post("/api/automations/delete", json!({"slug": "nightly"}));
    assert_eq!((&answer["ok"], &answer["message"]), (&json!(true), &json!("nightly: deleted")));
    assert!(!w.store().exists("nightly"));
    assert_eq!(WorkItem::find("nightly").unwrap().state().as_deref(), Some("resolved"));
}
