//! The Automations service against a stand-in routines API held in memory: it records every call, applies
//! creates and updates the way the API would (through the real request body) and stamps a new updated_at on
//! each write. No keychain, no network.

use quartermaster::automation_store::{AutomationStore, Record};
use quartermaster::automations::{self, Automations, Detail, Removed};
use quartermaster::error::{QmError, Res};
use quartermaster::routines_client::{self as rc, Deleted, Routines};
use quartermaster::work_item::WorkItem;
use serde_json::{json, Map, Value};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());
const DEFAULT_MODEL: &str = "claude-default-model";

fn digest() -> Value {
    let list: Value = serde_json::from_str(include_str!("fixtures/routines-list-response.json")).unwrap();
    list["data"][0].clone()
}

fn id() -> String {
    digest()["id"].as_str().unwrap().to_string()
}

struct Stub {
    routines: RefCell<BTreeMap<String, Value>>,
    calls: RefCell<Vec<Value>>,
    stamp: RefCell<u32>,
    fail_with: RefCell<Option<(&'static str, String)>>,
    delete_answer: RefCell<Deleted>,
}

impl Stub {
    fn new() -> Stub {
        let stub = Stub { routines: RefCell::default(), calls: RefCell::default(), stamp: RefCell::new(0), fail_with: RefCell::default(), delete_answer: RefCell::new(Deleted::Unsupported) };
        stub.routines.borrow_mut().insert(id(), digest());
        stub
    }

    fn record(&self, call: Value) -> Res<()> {
        if let Some((class, message)) = self.fail_with.borrow().clone() {
            return Err(QmError::new(class, message));
        }
        self.calls.borrow_mut().push(call);
        Ok(())
    }

    fn calls_named(&self, name: &str) -> Vec<Value> {
        self.calls.borrow().iter().filter(|c| c[0] == name).cloned().collect()
    }

    fn apply(&self, mut routine: Value, body: Value) -> Value {
        for (k, v) in body.as_object().unwrap() {
            if k != "clear_mcp_connections" {
                routine[k] = v.clone();
            }
        }
        *self.stamp.borrow_mut() += 1;
        routine["updated_at"] = json!(format!("2026-11-06T09:00:0{}Z", self.stamp.borrow()));
        self.routines.borrow_mut().insert(routine["id"].as_str().unwrap().to_string(), routine.clone());
        routine
    }

    fn touch(&self, id: &str) {
        self.routines.borrow_mut().get_mut(id).unwrap()["updated_at"] = json!("2026-11-06T10:00:00Z");
    }

    fn missing(&self, id: &str) -> Res<Value> {
        self.routines.borrow().get(id).cloned().ok_or_else(|| QmError::new(rc::ROUTINE_MISSING, format!("routine {id} isn't on claude.ai any more — delete the automation in qm")))
    }
}

impl Routines for Stub {
    fn list(&self) -> Res<Vec<Value>> {
        self.record(json!(["list"]))?;
        Ok(self.routines.borrow().values().cloned().collect())
    }
    fn get(&self, id: &str) -> Res<Value> {
        self.record(json!(["get", id]))?;
        self.missing(id)
    }
    fn create(&self, fields: &Map<String, Value>) -> Res<Value> {
        self.record(json!(["create", fields]))?;
        let mut body = rc::request_body(fields, "00000000-0000-4000-8000-000000000009");
        if let Some(context) = body.pointer_mut("/job_config/ccr/session_context").and_then(Value::as_object_mut) {
            context.entry("model").or_insert(json!(DEFAULT_MODEL));
        }
        Ok(self.apply(json!({"id": "trig_NEW", "enabled": true}), body))
    }
    fn update(&self, id: &str, fields: &Map<String, Value>) -> Res<Value> {
        self.record(json!(["update", id, fields]))?;
        let current = self.missing(id)?;
        Ok(self.apply(current, rc::request_body(fields, "00000000-0000-4000-8000-000000000009")))
    }
    fn run(&self, id: &str) -> Res<Value> {
        self.record(json!(["run", id]))?;
        Ok(json!({"session_id": "cse_RUN"}))
    }
    fn runs(&self, id: &str, limit: usize) -> Res<Vec<Value>> {
        self.record(json!(["runs", id, limit]))?;
        Ok(vec![json!({"id": "cse_1", "title": "Digest run", "status": "completed", "created_at": "2026-11-05T07:10:10Z", "updated_at": null, "url": "https://claude.ai/code/cse_1"})])
    }
    fn delete(&self, id: &str) -> Res<Deleted> {
        self.record(json!(["delete", id]))?;
        let answer = *self.delete_answer.borrow();
        if answer == Deleted::Deleted {
            self.routines.borrow_mut().remove(id);
        }
        Ok(answer)
    }
}

struct World {
    _dir: tempfile::TempDir,
    stub: Stub,
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl World {
    fn new() -> World {
        let lock = ENV.lock().unwrap_or_else(|p| p.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("QM_ROOT", dir.path());
        std::env::set_var("HOME", dir.path());
        World { _dir: dir, stub: Stub::new(), _lock: lock }
    }

    fn service(&self) -> Automations<'_> {
        Automations::new(&self.stub, AutomationStore::current())
    }

    fn adopt(&self) {
        self.service().adopt(&id(), "MyApp", Some("digest")).unwrap();
        self.stub.calls.borrow_mut().clear();
    }

    fn store(&self) -> AutomationStore {
        AutomationStore::current()
    }

    fn edit(&self, changes: Value, prompt: Option<&str>) {
        let entry = self.store().read("digest").unwrap().unwrap();
        let record: Record = changes.as_object().unwrap().clone();
        self.store().write("digest", &record, prompt.unwrap_or(&entry.prompt)).unwrap();
    }

    fn history(&self, slug: &str) -> Vec<String> {
        WorkItem::find(slug).unwrap().notes().into_iter().filter(|n| n.kind == "history").map(|n| n.text).collect()
    }

    fn record(&self, slug: &str, key: &str) -> Value {
        self.store().read(slug).unwrap().unwrap().record.get(key).cloned().unwrap_or(Value::Null)
    }

    fn state(&self, slug: &str) -> String {
        WorkItem::find(slug).unwrap().state().unwrap()
    }
}

fn slack() -> Value {
    digest()["mcp_connections"].clone()
}

#[test]
fn adopt_stores_the_routine_and_makes_an_automation_item() {
    let w = World::new();
    w.stub.routines.borrow_mut().get_mut(&id()).unwrap()["job_config"]["ccr"]["events"][0]["data"]["message"]["content"] = json!("Post the digest.\nTo Slack.\n\nDetails here.");
    let entry = w.service().adopt(&id(), "MyApp", None).unwrap();
    assert_eq!(entry.slug, "shipped-digest-dm");
    let record = &entry.record;
    assert_eq!((&record["routine"], &record["runner"], &record["cron"], &record["enabled"], &record["remote_updated_at"]), (&json!(id()), &json!("cloud"), &json!("0 7 * * 1,4"), &json!(true), &digest()["updated_at"]));
    let item = WorkItem::find("shipped-digest-dm").unwrap();
    assert_eq!((item.kind().as_deref(), item.routine(), item.runner().as_deref(), item.project().as_deref(), item.state().as_deref(), item.title().as_str()), (Some("automation"), Some(id()), Some("cloud"), Some("MyApp"), Some("active"), "Shipped digest (DM)"));
    assert_eq!(item.description(), "Shipped digest (DM)\n\nPost the digest.\nTo Slack.");
}

#[test]
fn adopting_a_managed_routine_again_is_refused() {
    let w = World::new();
    w.adopt();
    let error = w.service().adopt(&id(), "MyApp", None).unwrap_err();
    assert!(error.message.contains("is already managed by qm as 'digest'"), "{}", error.message);
}

#[test]
fn push_sends_only_what_changed_and_notes_it() {
    let w = World::new();
    w.adopt();
    w.edit(json!({"cron": "0 6 * * 1"}), None);
    let pushed = w.service().push("digest", false, false).unwrap();
    assert_eq!(w.stub.calls_named("update"), vec![json!(["update", id(), {"cron": "0 6 * * 1", "connectors": slack()}])]);
    assert_eq!(w.record("digest", "remote_updated_at"), json!("2026-11-06T09:00:01Z"));
    assert_eq!(w.history("digest").len(), 1);
    assert!(w.history("digest")[0].starts_with("pushed: schedule → Mon 07:00 (0 6 * * 1 UTC)") || w.history("digest")[0].starts_with("pushed: schedule → Mon 0"), "{:?}", w.history("digest"));
    assert!(pushed.changes[0].contains("(0 6 * * 1 UTC)"));
}

#[test]
fn a_prompt_change_sends_the_whole_job_config() {
    let w = World::new();
    w.adopt();
    w.edit(json!({}), Some("New prompt"));
    w.service().push("digest", false, false).unwrap();
    let call = &w.stub.calls_named("update")[0];
    let mut keys: Vec<&String> = call[2].as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["allowed_tools", "connectors", "environment_id", "model", "prompt", "sources"]);
    let routine = &w.stub.routines.borrow()[&id()];
    assert_eq!(routine["job_config"]["ccr"]["events"][0]["data"]["message"]["content"], "New prompt");
    assert_eq!(routine["job_config"]["ccr"]["session_context"], digest()["job_config"]["ccr"]["session_context"]);
    assert_eq!(w.history("digest"), ["pushed: prompt changed"]);
}

#[test]
fn push_with_nothing_changed_writes_nothing() {
    let w = World::new();
    w.adopt();
    let pushed = w.service().push("digest", false, false).unwrap();
    assert!(pushed.changes.is_empty() && !pushed.created);
    assert!(w.stub.calls_named("update").is_empty());
    assert!(w.history("digest").is_empty());
}

#[test]
fn push_refuses_a_routine_changed_outside_qm_unless_forced() {
    let w = World::new();
    w.adopt();
    w.stub.touch(&id());
    w.edit(json!({"cron": "0 6 * * 1"}), None);
    let error = w.service().push("digest", false, false).unwrap_err();
    assert_eq!(error.class, automations::STALE);
    for part in ["digest changed outside qm", "qm automation pull digest", "qm automation push digest --force"] {
        assert!(error.message.contains(part), "{}", error.message);
    }
    assert!(w.stub.calls_named("update").is_empty());
    assert_eq!(w.record("digest", "remote_updated_at"), digest()["updated_at"]);
    w.service().push("digest", true, false).unwrap();
    assert_eq!(w.stub.calls_named("update").len(), 1);
    assert_eq!(w.record("digest", "remote_updated_at"), json!("2026-11-06T09:00:01Z"));
}

#[test]
fn first_push_creates_the_routine_and_links_it() {
    let w = World::new();
    w.service().create_item("new-digest", "New digest", "MyApp").unwrap();
    let record = json!({"runner": "cloud", "name": "New digest", "cron": "0 8 * * *", "enabled": true, "environment_id": "env_1", "model": "claude-sonnet-5-5"});
    w.store().write("new-digest", record.as_object().unwrap(), "Do it.").unwrap();
    assert_eq!(w.state("new-digest"), "in_progress");
    w.service().push("new-digest", false, false).unwrap();
    let fields = &w.stub.calls_named("create")[0][1];
    assert_eq!((&fields["name"], &fields["cron"], &fields["enabled"], &fields["prompt"]), (&json!("New digest"), &json!("0 8 * * *"), &json!(true), &json!("Do it.")));
    assert_eq!((w.record("new-digest", "routine"), w.record("new-digest", "remote_updated_at")), (json!("trig_NEW"), json!("2026-11-06T09:00:01Z")));
    let item = WorkItem::find("new-digest").unwrap();
    assert_eq!((item.routine().as_deref(), item.state().as_deref(), item.kind().as_deref()), (Some("trig_NEW"), Some("active"), Some("automation")));
    assert_eq!(w.history("new-digest"), ["pushed: created routine trig_NEW"]);
}

#[test]
fn the_first_push_takes_the_routines_defaults_and_sends_no_nulls_so_a_second_push_has_nothing_to_send() {
    let w = World::new();
    w.service().create_item("fresh", "Fresh", "MyApp").unwrap();
    let record = json!({"runner": "cloud", "name": "Fresh", "cron": "0 8 * * *"});
    w.store().write("fresh", record.as_object().unwrap(), "Do it.").unwrap();
    w.service().push("fresh", false, false).unwrap();
    let fields = w.stub.calls_named("create")[0][1].clone();
    assert!(fields.as_object().unwrap().values().all(|v| !v.is_null()), "a create sends no nulls");
    assert_eq!(fields["connectors"], json!([]));
    assert_eq!(w.stub.routines.borrow()["trig_NEW"]["mcp_connections"], json!([]));
    assert_eq!((w.record("fresh", "enabled"), w.record("fresh", "model")), (json!(true), json!(DEFAULT_MODEL)));
    assert_eq!(w.store().read("fresh").unwrap().unwrap().prompt, "Do it.");
    w.stub.calls.borrow_mut().clear();
    let again = w.service().push("fresh", false, false).unwrap();
    assert!(again.changes.is_empty());
    assert_eq!(*w.stub.calls.borrow(), vec![json!(["get", "trig_NEW"])]);
    assert_eq!(w.history("fresh"), ["pushed: created routine trig_NEW"]);
}

#[test]
fn a_push_never_sends_a_field_left_unset_locally() {
    let w = World::new();
    w.adopt();
    w.edit(json!({"enabled": null, "name": "Renamed"}), None);
    w.service().push("digest", false, false).unwrap();
    assert!(w.stub.calls_named("update")[0][2].get("enabled").is_none());
    assert_eq!(w.history("digest").last().unwrap(), "pushed: name → Renamed");
    assert_eq!(w.stub.routines.borrow()[&id()]["enabled"], true);
}

#[test]
fn pause_and_resume_push_enabled_and_move_the_state() {
    let w = World::new();
    w.adopt();
    w.service().pause("digest").unwrap();
    assert_eq!(w.stub.calls_named("update")[0], json!(["update", id(), {"enabled": false, "connectors": slack()}]));
    assert_eq!((w.record("digest", "enabled"), w.state("digest")), (json!(false), "fridge".to_string()));
    w.service().resume("digest", false).unwrap();
    assert_eq!((w.stub.routines.borrow()[&id()]["enabled"].clone(), w.state("digest")), (json!(true), "active".to_string()));
    assert_eq!(w.history("digest"), ["pushed: resumed", "pushed: paused"], "newest first");
    assert!(w.service().resume("digest", true).unwrap_err().message.contains("--skip-existing is for local automations"));
}

#[test]
fn pull_overwrites_local_and_keeps_a_bak() {
    let w = World::new();
    w.adopt();
    w.edit(json!({"cron": "0 6 * * 1"}), None);
    w.stub.routines.borrow_mut().get_mut(&id()).unwrap()["enabled"] = json!(false);
    w.stub.touch(&id());
    let changes = w.service().pull("digest").unwrap();
    assert_eq!(changes, ["schedule", "enabled"]);
    assert_eq!((w.record("digest", "cron"), w.record("digest", "enabled"), w.record("digest", "remote_updated_at")), (json!("0 7 * * 1,4"), json!(false), json!("2026-11-06T10:00:00Z")));
    assert!(std::fs::read_to_string(format!("{}.bak", w.store().yml_path("digest").unwrap().display())).unwrap().contains("0 6 * * 1"));
    assert_eq!(w.state("digest"), "fridge");
    assert_eq!(w.history("digest"), ["pulled from claude.ai: schedule, enabled"]);
}

#[test]
fn run_runs_the_routine_now() {
    let w = World::new();
    w.adopt();
    w.service().run("digest").unwrap();
    assert_eq!(*w.stub.calls.borrow(), vec![json!(["run", id()])]);
}

#[test]
fn delete_without_an_api_delete_pauses_and_keeps_the_files() {
    let w = World::new();
    w.adopt();
    assert_eq!(w.service().delete("digest").unwrap(), Removed::Paused);
    assert_eq!(*w.stub.calls.borrow(), vec![json!(["delete", id()]), json!(["update", id(), {"enabled": false, "connectors": slack()}])]);
    assert_eq!((w.state("digest"), w.record("digest", "enabled")), ("resolved".to_string(), json!(false)));
}

#[test]
fn delete_with_an_api_delete_removes_files_resolves_and_keeps_the_item() {
    let w = World::new();
    w.adopt();
    *w.stub.delete_answer.borrow_mut() = Deleted::Deleted;
    assert_eq!(w.service().delete("digest").unwrap(), Removed::Deleted);
    assert!(w.store().read("digest").unwrap().is_none());
    assert_eq!(w.state("digest"), "resolved");
    assert_eq!(w.history("digest"), ["deleted"]);
}

#[test]
fn delete_of_a_routine_already_gone_from_claude_ai_removes_it_from_qm() {
    let w = World::new();
    w.adopt();
    w.stub.routines.borrow_mut().remove(&id());
    assert_eq!(w.service().delete("digest").unwrap(), Removed::Deleted);
    assert!(w.store().read("digest").unwrap().is_none());
    assert_eq!(w.state("digest"), "resolved");
}

#[test]
fn the_overview_pairs_rows_with_routines_marks_drift_and_lists_the_unmanaged() {
    let w = World::new();
    w.adopt();
    let other = {
        let mut r = digest();
        r["id"] = json!("trig_OTHER");
        r["name"] = json!("Other routine");
        r
    };
    w.stub.routines.borrow_mut().insert("trig_OTHER".into(), other);
    w.stub.touch(&id());
    let service = w.service();
    let overview = service.overview(service.local().unwrap()).unwrap();
    assert_eq!(overview.rows.len(), 1);
    assert!(overview.rows[0].drift && overview.rows[0].remote.is_some());
    assert_eq!(overview.unmanaged.iter().map(|r| r["id"].as_str().unwrap()).collect::<Vec<_>>(), ["trig_OTHER"]);
    assert_eq!(*w.stub.calls.borrow(), vec![json!(["list"])]);
}

#[test]
fn detail_has_the_routine_and_its_last_runs() {
    let w = World::new();
    w.adopt();
    let Detail::Cloud(detail) = w.service().detail("digest", 10).unwrap() else { panic!("a cloud detail") };
    assert_eq!((detail.runs.len(), detail.drift), (1, false));
    assert!(w.stub.calls.borrow().contains(&json!(["runs", id(), 10])));
}

#[test]
fn push_of_a_routine_deleted_on_claude_ai_says_it_is_gone() {
    let w = World::new();
    w.adopt();
    w.stub.routines.borrow_mut().remove(&id());
    let error = w.service().push("digest", false, false).unwrap_err();
    assert!(error.message.contains(&format!("digest: routine {} isn't on claude.ai any more — delete the automation in qm (`qm automation delete digest`) or re-create it (`qm automation push digest --recreate`)", id())), "{}", error.message);
    assert_eq!(*w.stub.calls.borrow(), vec![json!(["get", id()])]);
    assert_eq!(w.record("digest", "routine"), json!(id()));
}

#[test]
fn recreate_makes_a_new_routine_for_one_deleted_on_claude_ai() {
    let w = World::new();
    w.adopt();
    w.stub.routines.borrow_mut().remove(&id());
    w.edit(json!({"name": "Digest again"}), None);
    let pushed = w.service().push("digest", false, true).unwrap();
    assert_eq!(pushed.changes, [format!("re-created routine trig_NEW (was {})", id())]);
    assert!(pushed.created);
    let fields = &w.stub.calls_named("create")[0][1];
    assert_eq!((&fields["name"], &fields["connectors"][0]["name"]), (&json!("Digest again"), &json!("Slack")));
    assert_eq!((w.record("digest", "routine"), w.record("digest", "remote_updated_at")), (json!("trig_NEW"), json!("2026-11-06T09:00:01Z")));
    assert_eq!((WorkItem::find("digest").unwrap().routine().as_deref(), w.state("digest").as_str()), (Some("trig_NEW"), "active"));
    assert_eq!(w.history("digest").last().unwrap(), &format!("pushed: re-created routine trig_NEW (was {})", id()));
    assert!(w.service().push("digest", false, false).unwrap().changes.is_empty());
}

#[test]
fn recreate_without_connectors_clears_the_api_default_set() {
    let w = World::new();
    w.adopt();
    w.stub.routines.borrow_mut().remove(&id());
    w.edit(json!({"connectors": [], "enabled": false}), None);
    w.service().push("digest", false, true).unwrap();
    let fields = w.stub.calls_named("create")[0][1].as_object().unwrap().clone();
    assert_eq!(rc::request_body(&fields, "u")["clear_mcp_connections"], true);
    assert_eq!(w.state("digest"), "fridge");
}

#[test]
fn recreate_refuses_a_routine_that_still_exists_and_one_never_pushed() {
    let w = World::new();
    w.adopt();
    let before = std::fs::read_to_string(w.store().yml_path("digest").unwrap()).unwrap();
    let error = w.service().push("digest", false, true).unwrap_err();
    assert!(error.message.contains(&format!("digest: routine {} is still on claude.ai — `qm automation push digest` updates it", id())), "{}", error.message);
    assert_eq!(std::fs::read_to_string(w.store().yml_path("digest").unwrap()).unwrap(), before);
    w.stub.calls.borrow_mut().clear();
    w.service().create_item("fresh", "Fresh", "MyApp").unwrap();
    w.store().write("fresh", json!({"runner": "cloud", "name": "Fresh", "cron": "0 8 * * *"}).as_object().unwrap(), "Do it.").unwrap();
    let error = w.service().push("fresh", false, true).unwrap_err();
    assert!(error.message.contains("fresh has no routine yet: `qm automation push fresh` creates it"), "{}", error.message);
    assert!(w.stub.calls.borrow().is_empty());
}

#[test]
fn a_client_error_passes_through_with_its_class() {
    let w = World::new();
    w.adopt();
    *w.stub.fail_with.borrow_mut() = Some((rc::NOT_ENABLED, "automations are off: run `qm config set automations.token_source claude_code`".into()));
    let error = w.service().push("digest", false, false).unwrap_err();
    assert_eq!(error.class, rc::NOT_ENABLED);
}

#[test]
fn push_pull_and_adopt_refuse_a_local_automation() {
    let w = World::new();
    WorkItem::create_automation("nightly", "Nightly", "MyApp", None, None).unwrap();
    let record = json!({"runner": "local", "name": "Nightly", "cron": "0 8 * * *", "enabled": true});
    w.store().write("nightly", record.as_object().unwrap(), "x\n").unwrap();
    let service = w.service();
    assert!(service.push("nightly", false, false).unwrap_err().message.contains("nightly runs locally — nothing on claude.ai"));
    assert!(service.pull("nightly").unwrap_err().message.contains("nightly runs locally — nothing on claude.ai"));
    assert!(service.adopt("trig_1", "MyApp", Some("nightly")).unwrap_err().message.contains("nightly runs locally — nothing on claude.ai"));
    assert!(w.stub.calls.borrow().is_empty());
}
