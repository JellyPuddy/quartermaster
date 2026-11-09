//! A local automation's runs attach to its item through QM_ITEM, but are never its chat: every resume path
//! (the launcher's resume and chat plans, the GUI's pane, the edit chat) skips them (docs/areas/linking.md).

mod common;
use chrono::Utc;
use common::chat::*;
use quartermaster::automation_chat;
use quartermaster::automation_store::AutomationStore;
use quartermaster::gui_actions;
use quartermaster::launcher::{self, Mode, Resume};
use quartermaster::run_log::RunLog;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

struct Scene {
    world: ChatWorld,
    slug: String,
    cwd: String,
}

fn scene() -> Scene {
    let world = ChatWorld::new("resume");
    let cwd = world.dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    std::fs::write(world.dir.path().join("t.jsonl"), "").unwrap();
    let item = automation_chat::create("Shipped digest", "MyApp", None, "local", &AutomationStore::current()).unwrap();
    Scene { world, slug: item.slug, cwd: std::fs::canonicalize(cwd).unwrap().to_string_lossy().into_owned() }
}

impl Scene {
    fn log_session(&self, id: &str, ended: bool, pid: u32) {
        let transcript = self.world.dir.path().join("t.jsonl");
        let start = json!({"v": 1, "event": "start", "session_id": id, "cwd": self.cwd, "transcript_path": transcript, "pid": pid, "ts": Utc::now().to_rfc3339()});
        let mut lines = vec![start.to_string()];
        if ended {
            lines.push(json!({"v": 1, "event": "end", "session_id": id, "ts": Utc::now().to_rfc3339()}).to_string());
        }
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(self.world.root().join("sessions.jsonl")).unwrap();
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
    }

    /// A run of the automation, started and attached to its item as QM_ITEM does; live (this process's pid)
    /// unless ended.
    fn start_run(&self, session: &str, ended: bool) {
        self.log_session(session, ended, std::process::id());
        self.item().attach_session(session).unwrap();
        let runs = RunLog::new(&self.slug, &self.world.automations()).unwrap();
        let id = runs.enqueue(&format!("cron:{session}"), &Value::Null, "chat", "manual", Utc::now()).unwrap();
        runs.started(&id, session, &format!("{}--run-{id}", self.slug), &self.slug, Utc::now()).unwrap();
    }

    fn author(&self) {
        self.log_session("s-author", true, 999_999_999);
        self.item().attach_session("s-author").unwrap();
    }

    fn item(&self) -> WorkItem {
        WorkItem::find(&self.slug).unwrap()
    }
}

#[test]
fn resume_plan_skips_a_live_run_and_resumes_the_authoring_session() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.author();
    s.start_run("s-run", false);
    match launcher::resume_plan(&s.item(), None) {
        Resume::Resume { session_id, cwd } => assert_eq!((session_id.as_str(), cwd.as_str()), ("s-author", s.cwd.as_str())),
        _ => panic!("expected a resume"),
    }
}

#[test]
fn resume_plan_never_resumes_an_ended_run_and_is_not_refused_by_a_live_one() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.start_run("s-old", true);
    assert!(matches!(launcher::resume_plan(&s.item(), None), Resume::Rehydrate { .. }));
    s.start_run("s-run", false);
    assert!(matches!(launcher::resume_plan(&s.item(), None), Resume::Rehydrate { .. }), "a live run doesn't refuse it");
}

/// A session picked by id (the ^X view, a session row) is the user's own choice, a run's included.
#[test]
fn resume_plan_still_resumes_a_run_picked_by_id() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.start_run("s-run", true);
    match launcher::resume_plan(&s.item(), Some("s-run")) {
        Resume::Resume { session_id, cwd } => assert_eq!((session_id.as_str(), cwd.as_str()), ("s-run", s.cwd.as_str())),
        _ => panic!("expected a resume"),
    }
}

#[test]
fn the_gui_pane_starts_beside_a_live_run_instead_of_refusing() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.start_run("s-run", false);
    let reply = gui_actions::dispatch(&json!({"cmd": "pane-resume", "slug": s.slug})).unwrap();
    assert_eq!(reply, json!({"ok": true, "mode": "start"}));
    assert_eq!(s.world.sessions(), [s.slug.clone()]);
}

#[test]
fn the_gui_pane_resumes_the_authoring_session_past_a_live_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.author();
    s.start_run("s-run", false);
    let reply = gui_actions::dispatch(&json!({"cmd": "pane-resume", "slug": s.slug})).unwrap();
    assert_eq!(reply, json!({"ok": true, "mode": "resume"}));
    assert_eq!(s.world.wait_started(1)[0].args, ["--resume", "s-author"]);
}

/// Only a local automation's runs are skipped: a plain item's live session still refuses.
#[test]
fn a_plain_items_live_session_still_refuses() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    let mut plain = WorkItem::create("Plain work", "MyApp", None, None, None, None).unwrap();
    s.log_session("s-live", false, std::process::id());
    plain.attach_session("s-live").unwrap();
    assert!(matches!(launcher::chat_plan(&plain, false, None, None).unwrap().mode, Mode::Live));
}

#[test]
fn run_session_ids_names_only_a_local_automations_runs() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let s = scene();
    s.start_run("s-run", false);
    let plain = WorkItem::create("Plain work", "MyApp", None, None, None, None).unwrap();
    assert_eq!(RunLog::session_ids_for(&s.item(), &s.world.automations()), ["s-run"]);
    assert!(RunLog::session_ids_for(&plain, &s.world.automations()).is_empty());
}
