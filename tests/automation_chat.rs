//! An automation's item and local files, and its chat started with the brief qm writes
//! (docs/areas/local-automations.md and automations.md).

mod common;
use chrono::Utc;
use common::chat::*;
use quartermaster::automation_chat;
use quartermaster::automation_store::AutomationStore;
use quartermaster::run_log::RunLog;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const HOUSE_RULES: &str = include_str!("../docs/automations-house-rules.md");

fn store() -> AutomationStore {
    AutomationStore::current()
}

fn new_automation(world: &ChatWorld) -> WorkItem {
    let _ = world;
    let mut item = automation_chat::create("Shipped digest", "MyApp", Some("DM me what shipped."), "cloud", &store()).unwrap();
    item.add_note("posts to the DM channel only", "decision").unwrap();
    WorkItem::find(&item.slug).unwrap()
}

fn yml(world: &ChatWorld, slug: &str) -> Value {
    serde_yaml::from_str(&std::fs::read_to_string(world.automations().join(format!("{slug}.yml"))).unwrap()).unwrap()
}

#[test]
fn create_makes_an_in_progress_automation_item_and_empty_local_files() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = automation_chat::create("Shipped digest", "MyApp", None, "cloud", &store()).unwrap();
    let found = WorkItem::find("shipped-digest").unwrap();
    assert_eq!(found.slug, item.slug);
    assert_eq!((found.kind(), found.runner(), found.routine(), found.state(), found.project()), (Some("automation".into()), Some("cloud".into()), None, Some("in_progress".into()), Some("MyApp".into())));
    assert_eq!(std::fs::read_to_string(world.automations().join("shipped-digest.prompt.md")).unwrap(), "");
    assert_eq!(yml(&world, "shipped-digest"), json!({"v": 1, "runner": "cloud", "name": "Shipped digest", "enabled": true}));
}

#[test]
fn create_with_runner_local_makes_a_disabled_local_automation() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    automation_chat::create("Shipped digest", "MyApp", None, "local", &store()).unwrap();
    let found = WorkItem::find("shipped-digest").unwrap();
    assert_eq!((found.kind(), found.runner(), found.state()), (Some("automation".into()), Some("local".into()), Some("in_progress".into())));
    assert_eq!(yml(&world, "shipped-digest"), json!({"v": 1, "runner": "local", "name": "Shipped digest", "enabled": false}));
}

#[test]
fn create_refuses_an_unknown_runner() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _world = ChatWorld::new("achat");
    let error = automation_chat::create("Shipped digest", "MyApp", None, "moon", &store()).err().unwrap();
    assert_eq!(error.message, "runner is cloud or local, got moon");
    assert!(WorkItem::find("shipped-digest").is_err());
}

#[test]
fn create_refuses_a_slug_whose_files_already_exist() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _world = ChatWorld::new("achat");
    store().write("shipped-digest", json!({"name": "Old"}).as_object().unwrap(), "keep me").unwrap();
    let error = automation_chat::create("Shipped digest", "MyApp", None, "cloud", &store()).err().unwrap();
    assert!(error.message.contains("already"), "{}", error.message);
    assert!(WorkItem::find("shipped-digest").is_err());
    assert_eq!(store().read("shipped-digest").unwrap().unwrap().prompt, "keep me");
}

/// The local snapshot, hand-written: local cron, the dry-run loop, no push or RemoteTrigger, house rules verbatim.
#[test]
fn local_brief_snapshot() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = automation_chat::create("Shipped digest", "MyApp", Some("Draft what shipped."), "local", &store()).unwrap();
    let dir = world.automations().display().to_string();
    let expected = format!(
        "You are working on the qm automation \"Shipped digest\" (work item shipped-digest, project MyApp): a local automation, a Claude Code run that qm starts on this machine on a schedule. It runs unattended, with the user's own permissions. It was created disabled: its cron and guard don't run until it is enabled with `qm automation resume shipped-digest`.

## Its files

- Prompt: {dir}/shipped-digest.prompt.md (the run's prompt, nothing else; each guard item is appended to it as a final `## Item` section)
- Settings: {dir}/shipped-digest.yml (name, cron in Europe/Amsterdam local time, enabled, when (the guard command), flow, repos (required for flow pr-review: the owner/name repos it may review; an unattended review reads PR text others wrote, so a PR in any other repo is refused), cwd, model, allowed_tools, permission_mode, timeout_minutes, notify; keep `v:` and any key you don't know)

## The loop

1. Edit the two files.
2. `qm automation tick --dry-run shipped-digest` runs the guard and prints the items a run would be queued for; it writes nothing.
3. `qm automation run shipped-digest` queues a run now; a tick starts it.
4. Read the run: `qm automation runs shipped-digest` lists its runs with their session ids; `qm show-session SESSION_ID` shows one, and its transcript is `~/.claude/projects/*/SESSION_ID.jsonl`.
5. Refine and repeat.

Nothing to push: qm reads the two files on every tick.
Record each decision as a note on the item: `qm note shipped-digest --kind decision \"...\"`.

## House rules

{rules}

## Description

Draft what shipped.

## Notes

_none yet_
",
        rules = HOUSE_RULES.trim()
    );
    let brief = automation_chat::brief(&WorkItem::find(&item.slug).unwrap(), &store()).unwrap();
    assert_eq!(brief, expected);
    assert!(!brief.contains("RemoteTrigger") && !brief.contains("qm automation push"));
}

/// The snapshot, hand-written: house rules verbatim, both absolute paths, the loop, the push-only rule and
/// decisions as notes.
#[test]
fn brief_snapshot() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = new_automation(&world);
    let stamp = item.notes()[0].stamp.clone();
    let dir = world.automations().display().to_string();
    let expected = format!(
        "You are working on the qm automation \"Shipped digest\" (work item shipped-digest, project MyApp): a claude.ai cloud routine that qm manages. It has no routine yet: the first push creates it.

## Its files

- Prompt: {dir}/shipped-digest.prompt.md (the routine's prompt, nothing else)
- Settings: {dir}/shipped-digest.yml (name, cron in UTC, model, sources, connectors, allowed_tools, environment_id, enabled; keep `v:` and any key you don't know)

## The loop

1. Edit the two files.
2. `qm automation push shipped-digest` sends them to the routine (the first push creates it).
3. `qm automation run shipped-digest` runs it now.
4. Read the run: its claude.ai link (`qm automation show shipped-digest`) or RemoteTrigger get_run_log.
5. Refine and repeat.

Never call RemoteTrigger create or update yourself: push is the only way a change reaches the routine.
Record each decision as a note on the item: `qm note shipped-digest --kind decision \"...\"`.

## House rules

{rules}

## Description

DM me what shipped.

## Notes

- {stamp} [decision]: posts to the DM channel only
",
        rules = HOUSE_RULES.trim()
    );
    assert_eq!(automation_chat::brief(&item, &store()).unwrap(), expected);
}

#[test]
fn brief_names_the_routine_once_there_is_one() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = new_automation(&world);
    let path = world.root().join("work-items/shipped-digest.md");
    let text = std::fs::read_to_string(&path).unwrap().replacen("runner: cloud\n", "runner: cloud\nroutine: trig_01JJ\n", 1);
    std::fs::write(&path, text).unwrap();
    let brief = automation_chat::brief(&WorkItem::find(&item.slug).unwrap(), &store()).unwrap();
    assert!(brief.contains("Its routine is trig_01JJ (https://claude.ai/code/routines/trig_01JJ)."));
    assert!(!brief.contains("no routine yet"));
}

#[test]
fn brief_of_an_item_without_a_description_says_so_instead_of_the_placeholder() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _world = ChatWorld::new("achat");
    let item = automation_chat::create("Shipped digest", "MyApp", None, "cloud", &store()).unwrap();
    let brief = automation_chat::brief(&item, &store()).unwrap();
    assert!(brief.contains("## Description\n\n_none yet_\n"));
    assert!(!brief.contains("_TODO_"));
}

#[test]
fn open_starts_the_items_chat_with_the_brief_as_claudes_argument() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = new_automation(&world);
    let reply = automation_chat::open(&item.slug, &store()).unwrap();
    assert_eq!(reply, json!({"ok": true, "mode": "start"}));
    let started = &world.wait_started(1)[0];
    assert_eq!(started.item, item.slug);
    assert_eq!(std::fs::canonicalize(&started.cwd).unwrap(), std::fs::canonicalize(std::env::var("HOME").unwrap()).unwrap());
    assert_eq!(started.args, [automation_chat::brief(&item, &store()).unwrap()]);
    assert_eq!(world.sessions(), [item.slug.clone()]);
}

#[test]
fn open_on_a_live_chat_types_nothing_and_hands_back_the_brief() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let item = new_automation(&world);
    assert!(world.tmux(&["new-session", "-d", "-s", &item.slug, "cat"]).0);
    let reply = automation_chat::open(&item.slug, &store()).unwrap();
    assert_eq!(reply, json!({"ok": true, "attached": true, "brief": automation_chat::brief(&item, &store()).unwrap()}));
    assert!(world.started().is_empty());
    std::thread::sleep(std::time::Duration::from_millis(200));
    let (_, pane) = world.tmux(&["capture-pane", "-p", "-t", &format!("={}:", item.slug)]);
    assert!(pane.trim().is_empty(), "nothing was typed into the chat: {pane:?}");
}

#[test]
fn open_resumes_an_earlier_chat_with_the_brief() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let mut item = new_automation(&world);
    let cwd = world.dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let transcript = world.dir.path().join("t.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let cwd = std::fs::canonicalize(cwd).unwrap();
    let start = json!({"v": 1, "event": "start", "session_id": "s-1", "cwd": cwd, "transcript_path": transcript, "pid": 999_999_999, "ts": Utc::now().to_rfc3339()});
    let end = json!({"v": 1, "event": "end", "session_id": "s-1", "ts": Utc::now().to_rfc3339()});
    std::fs::write(world.root().join("sessions.jsonl"), format!("{start}\n{end}\n")).unwrap();
    item.attach_session("s-1").unwrap();
    let reply = automation_chat::open(&item.slug, &store()).unwrap();
    assert_eq!(reply["mode"], "resume");
    let item = WorkItem::find(&item.slug).unwrap();
    assert_eq!(world.wait_started(1)[0].args, ["--resume".to_string(), "s-1".to_string(), automation_chat::brief(&item, &store()).unwrap()]);
}

/// A local automation's runs attach to its item (QM_ITEM); its edit chat neither refuses for a live run nor
/// resumes one.
#[test]
fn a_local_automations_chat_resumes_its_authoring_session_past_a_live_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let (mut item, cwd, transcript) = local_scene(&world);
    log_session(&world, "s-author", &cwd, &transcript, true, 999_999_999);
    item.attach_session("s-author").unwrap();
    start_run(&world, &cwd, &transcript, &item.slug, "s-run", false);
    let plan = automation_chat::plan(&WorkItem::find(&item.slug).unwrap(), &store()).unwrap();
    assert_eq!(plan.mode.name(), "resume");
    assert_eq!(plan.argv[plan.argv.len() - 3..plan.argv.len() - 1], ["--resume", "s-author"]);
}

#[test]
fn a_local_automations_chat_starts_fresh_when_its_only_sessions_are_runs() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("achat");
    let (item, cwd, transcript) = local_scene(&world);
    start_run(&world, &cwd, &transcript, &item.slug, "s-run", false);
    start_run(&world, &cwd, &transcript, &item.slug, "s-old-run", true);
    let item = WorkItem::find(&item.slug).unwrap();
    let plan = automation_chat::plan(&item, &store()).unwrap();
    assert_eq!(plan.mode.name(), "start");
    assert_eq!(plan.argv.last().unwrap(), &automation_chat::brief(&item, &store()).unwrap());
    assert!(!plan.argv.contains(&"--resume".to_string()));
}

#[test]
fn open_refuses_an_item_that_is_not_an_automation() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _world = ChatWorld::new("achat");
    WorkItem::create("Plain work", "MyApp", None, None, None, None).unwrap();
    let error = automation_chat::open("plain-work", &store()).err().unwrap();
    assert!(error.message.contains("is not an automation"), "{}", error.message);
}

fn local_scene(world: &ChatWorld) -> (WorkItem, std::path::PathBuf, std::path::PathBuf) {
    let cwd = world.dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let transcript = world.dir.path().join("t.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let item = automation_chat::create("Shipped digest", "MyApp", None, "local", &store()).unwrap();
    (item, std::fs::canonicalize(cwd).unwrap(), transcript)
}

fn log_session(world: &ChatWorld, id: &str, cwd: &std::path::Path, transcript: &std::path::Path, ended: bool, pid: u32) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(world.root().join("sessions.jsonl")).unwrap();
    writeln!(f, "{}", json!({"v": 1, "event": "start", "session_id": id, "cwd": cwd, "transcript_path": transcript, "pid": pid, "ts": Utc::now().to_rfc3339()})).unwrap();
    if ended {
        writeln!(f, "{}", json!({"v": 1, "event": "end", "session_id": id, "ts": Utc::now().to_rfc3339()})).unwrap();
    }
}

fn start_run(world: &ChatWorld, cwd: &std::path::Path, transcript: &std::path::Path, slug: &str, session: &str, ended: bool) {
    log_session(world, session, cwd, transcript, ended, std::process::id());
    WorkItem::find(slug).unwrap().attach_session(session).unwrap();
    let runs = RunLog::new(slug, &world.automations()).unwrap();
    let id = runs.enqueue(&format!("cron:{session}"), &Value::Null, "chat", "manual", Utc::now()).unwrap();
    runs.started(&id, session, &format!("{slug}--run-{id}"), slug, Utc::now()).unwrap();
}
