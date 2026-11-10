//! `qm automation …` for `runner: local` automations, end to end: rows and runs from the run log with no
//! network, manual runs, pause/resume, retry, delete, the tick and its LaunchAgent. Run chats open in the real
//! tmux on a throwaway socket (claude is a stand-in), guards are real `sh -c` commands, launchctl is a stand-in
//! and the LaunchAgents directory lives under the world's HOME.

mod common;
use chrono::Utc;
use common::chat::*;
use common::*;
use quartermaster::automation_chat;
use quartermaster::automation_store::AutomationStore;
use quartermaster::run_log::RunLog;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

struct World {
    chat: ChatWorld,
    qm: Qm,
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl World {
    fn new() -> World {
        let lock = ENV.lock().unwrap_or_else(|p| p.into_inner());
        let chat = ChatWorld::new("localcli");
        let qm = Qm::at(&chat.root());
        World { chat, qm, _lock: lock }
    }

    fn run(&self, args: &[&str], stdin: &str) -> Out {
        let socket = self.chat.socket.clone();
        self.qm.run_with(args, stdin, &[("QM_TMUX_SOCKET", &socket)])
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args, "");
        assert_eq!(out.code, 0, "{args:?}: {}{}", out.stdout, out.stderr);
        out.stdout
    }

    fn automation(&self, slug: &str, record: Value) {
        let store = AutomationStore::new(self.chat.automations());
        let title = format!("{}{}", slug[..1].to_uppercase(), &slug[1..]);
        automation_chat::create(&title, "MyApp", None, "local", &store).unwrap();
        let mut full = json!({"runner": "local", "name": title, "cron": "0 8 * * *", "enabled": true, "cwd": std::env::var("HOME").unwrap()}).as_object().unwrap().clone();
        full.extend(record.as_object().unwrap().clone());
        store.write(slug, &full, "Do the thing.\n").unwrap();
        WorkItem::find(slug).unwrap().update_state(if full["enabled"] == json!(false) { "in_progress" } else { "active" }).unwrap();
    }

    fn log(&self, slug: &str) -> RunLog {
        RunLog::new(slug, &self.chat.automations()).unwrap()
    }

    fn pause_all(&self) {
        self.ok(&["config", "set", "automations.local_paused", "true"]);
    }

    fn ended(&self, slug: &str) -> String {
        let log = self.log(slug);
        let item = json!({"key": "k1"});
        let id = log.enqueue("k1", &item, "chat", "guard", Utc::now()).unwrap();
        log.started(&id, "s-1", &format!("{slug}--run-{id}"), slug, Utc::now()).unwrap();
        log.failed(&id, "boom", Utc::now()).unwrap();
        id
    }

    fn history(&self, slug: &str) -> Vec<String> {
        WorkItem::find(slug).unwrap().notes().into_iter().filter(|n| n.kind == "history").map(|n| n.text).collect()
    }

    fn state(&self, slug: &str) -> String {
        WorkItem::find(slug).unwrap().state().unwrap()
    }
}

#[test]
fn list_prints_local_rows_without_a_routines_call_when_automations_are_off() {
    let w = World::new();
    w.automation("nightly", json!({}));
    let id = w.log("nightly").enqueue("k", &Value::Null, "chat", "manual", Utc::now()).unwrap();
    w.log("nightly").started(&id, "s", "nightly--run-x", "nightly", Utc::now()).unwrap();
    w.log("nightly").finished(&id, Utc::now()).unwrap();
    let out = w.ok(&["automation", "list"]);
    assert!(out.contains("nightly  MyApp  active  every day 08:00  enabled  local"), "{out}");
    assert!(out.contains("nightly: on this machine, 0 queued, 0 live, last run finished"), "{out}");
    assert!(out.contains("tick: not installed (qm automation install-tick)"), "{out}");
}

#[test]
fn show_reads_schedule_guard_queue_and_runs_from_the_run_log() {
    let w = World::new();
    w.automation("nightly", json!({"when": "list-things", "notify": "quiet"}));
    let failed = w.ended("nightly");
    let queued = w.log("nightly").enqueue("k2", &json!({"key": "k2"}), "chat", "guard", Utc::now()).unwrap();
    w.log("nightly").waiting(&queued, "Review chat for a#1 is open", Utc::now()).unwrap();
    w.log("nightly").guard_error("guard failed: nope", None, Utc::now()).unwrap();
    let out = w.ok(&["automation", "show", "nightly"]);
    for part in ["schedule: every day 08:00  (0 8 * * * Amsterdam time)", "guard: list-things", "flow: chat  notify: quiet  timeout: 30 min", "last guard error: guard failed: nope", &format!("  {queued}  guard  k2  waiting: Review chat for a#1 is open")] {
        assert!(out.contains(part), "{part}\n{out}");
    }
    assert!(regex::Regex::new(&format!(r"  {failed}  failed  .*  k1  boom")).unwrap().is_match(&out), "{out}");
}

#[test]
fn push_pull_and_adopt_refuse_a_local_automation() {
    let w = World::new();
    w.automation("nightly", json!({}));
    for args in [vec!["automation", "push", "nightly"], vec!["automation", "pull", "nightly"], vec!["automation", "adopt", "trig_1", "--project", "MyApp", "--slug", "nightly"]] {
        let out = w.run(&args, "");
        assert_eq!(out.code, 1);
        assert!(out.stderr.contains("nightly runs locally — nothing on claude.ai"), "{args:?}: {}", out.stderr);
    }
}

#[test]
fn run_without_a_guard_queues_a_manual_run_and_ticks_it_into_its_own_chat() {
    let w = World::new();
    w.automation("nightly", json!({}));
    let out = w.ok(&["automation", "run", "nightly"]);
    let run = w.log("nightly").runs().remove(0);
    assert_eq!((run.trigger.as_deref(), run.item.is_null(), run.status.as_str()), (Some("manual"), true, "live"));
    assert_eq!(w.chat.sessions(), [format!("nightly--run-{}", run.id)]);
    assert!(out.contains(&format!("nightly: started run {}", run.id)), "{out}");
}

#[test]
fn run_of_a_disabled_automation_starts_and_a_held_one_names_the_global_pause() {
    let w = World::new();
    w.automation("nightly", json!({"enabled": false}));
    let out = w.ok(&["automation", "run", "nightly"]);
    assert!(out.contains(&format!("nightly: started run {}", w.log("nightly").runs()[0].id)), "{out}");
    w.pause_all();
    let out = w.ok(&["automation", "run", "nightly"]);
    assert!(out.contains(&format!("nightly: queued run {} — local automations are paused", w.log("nightly").queue()[0].id)), "{out}");
}

#[test]
fn run_with_a_guard_queues_its_new_items_and_says_when_there_are_none() {
    let w = World::new();
    w.automation("nightly", json!({"when": "printf 'a\\nb\\n'"}));
    w.pause_all();
    let out = w.ok(&["automation", "run", "nightly"]);
    let queue = w.log("nightly").queue();
    assert_eq!(queue.iter().map(|r| (r.key.clone().unwrap(), r.trigger.clone().unwrap())).collect::<Vec<_>>(), [("a".to_string(), "manual".to_string()), ("b".to_string(), "manual".to_string())]);
    let ids: Vec<String> = queue.iter().map(|r| r.id.clone()).collect();
    assert!(out.contains(&format!("nightly: queued 2 runs ({}) — local automations are paused", ids.join(", "))), "{out}");
    assert!(w.ok(&["automation", "run", "nightly"]).contains("nightly: the guard found nothing new"));
}

#[test]
fn pause_and_resume_move_the_item_with_a_history_note_and_never_push() {
    let w = World::new();
    w.automation("nightly", json!({}));
    w.ok(&["automation", "pause", "nightly"]);
    assert_eq!((w.state("nightly"), w.qm.read("automations/nightly.yml").contains("enabled: false")), ("fridge".to_string(), true));
    w.ok(&["automation", "resume", "nightly"]);
    assert_eq!(w.state("nightly"), "active");
    let mut history = w.history("nightly");
    history.sort();
    assert_eq!(history, ["paused", "resumed"]);
}

#[test]
fn resume_skip_existing_marks_the_guards_current_items_seen() {
    let w = World::new();
    w.automation("nightly", json!({"when": "printf 'a\\nb\\n'", "enabled": false}));
    let out = w.ok(&["automation", "resume", "nightly", "--skip-existing"]);
    let mut seen: Vec<String> = w.log("nightly").seen_keys().into_iter().collect();
    seen.sort();
    assert_eq!(seen, ["a", "b"]);
    assert!(w.log("nightly").queue().is_empty());
    assert!(out.contains("nightly: resumed, 2 existing items marked seen"), "{out}");
    assert_eq!(w.history("nightly"), ["resumed; 2 existing guard items marked seen"]);
}

#[test]
fn retry_queues_an_ended_runs_item_again() {
    let w = World::new();
    w.automation("nightly", json!({}));
    w.pause_all();
    let failed = w.ended("nightly");
    let out = w.ok(&["automation", "retry", "nightly", &failed]);
    let again = w.log("nightly").queue().remove(0);
    assert_eq!((again.trigger.as_deref(), again.item.clone()), (Some("retry"), json!({"key": "k1"})));
    assert!(out.contains(&format!("nightly: queued run {} (retry of {failed})", again.id)), "{out}");
    let err = w.run(&["automation", "retry", "nightly", &again.id], "");
    assert!(err.code == 1 && err.stderr.contains(&format!("run {} is still queued", again.id)), "{}", err.stderr);
}

#[test]
fn a_refused_pr_review_item_shows_in_runs_and_retries_only_once_its_repo_is_listed() {
    let w = World::new();
    w.automation("reviews", json!({"flow": "pr-review", "repos": ["acme/app"]}));
    w.pause_all();
    let url = "https://github.com/stranger/fork/pull/2";
    let id = w.log("reviews").refuse_item(url, &json!({"key": url, "url": url}), "pr-review", "guard", "repo stranger/fork isn't in this automation's repos", Utc::now()).unwrap().unwrap();
    let out = w.ok(&["automation", "runs", "reviews"]);
    assert!(regex::Regex::new(&format!(r"{id}  refused .*repo stranger/fork isn't in this automation's repos")).unwrap().is_match(&out), "{out}");
    let err = w.run(&["automation", "retry", "reviews", &id], "");
    assert!(err.code == 1 && err.stderr.contains("repo stranger/fork isn't in this automation's repos"), "{}", err.stderr);
    assert!(w.log("reviews").queue().is_empty());
    let store = AutomationStore::new(w.chat.automations());
    store.write("reviews", json!({"repos": ["acme/app", "Stranger/Fork"]}).as_object().unwrap(), "Review.\n").unwrap();
    w.ok(&["automation", "retry", "reviews", &id]);
    assert_eq!(w.log("reviews").queue().iter().map(|r| r.key.clone().unwrap()).collect::<Vec<_>>(), [url]);
}

#[test]
fn delete_is_refused_while_a_run_is_live_and_then_removes_files_and_runs() {
    let w = World::new();
    w.automation("nightly", json!({}));
    let id = w.log("nightly").enqueue("k", &Value::Null, "chat", "manual", Utc::now()).unwrap();
    w.log("nightly").started(&id, "s", &format!("nightly--run-{id}"), "nightly", Utc::now()).unwrap();
    let err = w.run(&["automation", "delete", "nightly", "--yes"], "");
    assert!(err.code == 1 && err.stderr.contains("nightly has a live run — stop or finish its runs first"), "{}", err.stderr);
    w.log("nightly").finished(&id, Utc::now()).unwrap();
    let out = w.run(&["automation", "delete", "nightly"], "y\n");
    assert!(out.stdout.contains("nightly: deleted") && out.stderr.contains("(its files and run log)"), "{}{}", out.stdout, out.stderr);
    assert!(!w.qm.exists("automations/nightly.yml") && !w.qm.exists("automations/nightly.runs.jsonl"));
    assert_eq!((w.state("nightly"), w.history("nightly")), ("resolved".to_string(), vec!["deleted".to_string()]));
}

#[test]
fn runs_lists_queued_and_recent_runs() {
    let w = World::new();
    w.automation("nightly", json!({}));
    let failed = w.ended("nightly");
    let queued = w.log("nightly").enqueue("k2", &Value::Null, "chat", "manual", Utc::now()).unwrap();
    let out = w.ok(&["automation", "runs", "nightly"]);
    assert!(regex::Regex::new(&format!(r"(?s)queued.*{queued}  manual  k2")).unwrap().is_match(&out), "{out}");
    assert!(regex::Regex::new(&format!(r"{failed}  failed .* k1  boom")).unwrap().is_match(&out), "{out}");
}

#[test]
fn tick_runs_one_tick_and_dry_run_writes_nothing() {
    let w = World::new();
    w.automation("nightly", json!({"when": "printf 'a\\n'"}));
    let out = w.ok(&["automation", "tick", "--dry-run", "nightly"]);
    assert!(out.contains("nightly: would queue a"), "{out}");
    assert!(!w.log("nightly").path().exists());
    w.log("nightly").enqueue("m", &Value::Null, "chat", "manual", Utc::now()).unwrap();
    let out = w.ok(&["automation", "tick"]);
    assert!(out.contains(&format!("started nightly/{}", w.log("nightly").runs()[0].id)), "{out}");
    assert_eq!(w.chat.sessions().len(), 1);
    assert!(w.qm.read("automations/tick.json").contains("last_tick_at"));
}

#[test]
fn install_tick_prints_or_installs_the_launch_agent_and_uninstall_removes_it() {
    let w = World::new();
    let bin = w.chat.dir.path().join("bin");
    let launchctl = bin.join("launchctl");
    std::fs::write(&launchctl, "#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s ' \"$@\" >> \"$d/launchctl.log\"\necho >> \"$d/launchctl.log\"\n").unwrap();
    std::fs::set_permissions(&launchctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let plist = std::path::Path::new(&std::env::var("HOME").unwrap()).join("Library/LaunchAgents/com.quartermaster.automation-tick.plist");
    assert!(w.ok(&["automation", "install-tick", "--print"]).contains("<string>tick</string>"));
    assert!(!plist.exists());
    let out = w.ok(&["automation", "install-tick"]);
    assert!(plist.exists() && out.contains("installed"), "{out}");
    let calls = std::fs::read_to_string(bin.join("launchctl.log")).unwrap();
    assert!(calls.contains(&format!("bootstrap gui/{}", unsafe { libc::getuid() })), "{calls}");
    w.automation("nightly", json!({}));
    assert!(w.ok(&["automation", "list"]).contains("tick: installed"));
    assert!(w.ok(&["automation", "uninstall-tick"]).contains("uninstalled"));
    assert!(!plist.exists());
}
