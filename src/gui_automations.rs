//! The ⚙ area's Automations tab, server side (`/api/automations…`), over the `Automations` service. GET answers
//! the local files at once, merged with the routines the last list call saw; every network call (the list, a
//! detail's runs, push, recreate, pull, pause, resume, run, delete, adopt) runs as a `gui_jobs` job, never under
//! the action mutex, and each action ends with one list call so the tab shows where it landed. Automations being
//! off or Claude Code's token having expired is a state of the tab (`remote.state`), not an error. The
//! `runner: local` part is `gui_local_automations`.

use std::collections::BTreeMap;
use std::sync::Mutex;

use chrono::{SecondsFormat, Utc};
use serde_json::{json, Map, Value};

use crate::automation_store::{AutomationStore, Entry};
use crate::automations::{drift, Automations, Removed, STALE};
use crate::error::{QmError, Res};
use crate::gui_jobs::{self, Failure};
use crate::gui_local_automations as locals;
use crate::local_automations::{self, item_or_none};
use crate::local_schedule::{self, LocalSchedule};
use crate::routines_client::{self as rc, Routines, RoutinesClient};
use crate::work_item::WorkItem;

type Reply = (&'static str, &'static str, Vec<u8>);
/// Makes the routines client a job uses: on its own thread, so the client needn't be `Send`.
pub type Client = fn() -> Box<dyn Routines>;

const ACTIONS: [&str; 8] = ["apply", "pause", "resume", "run", "pull", "push", "recreate", "delete"];

static REMOTE: Mutex<Option<Value>> = Mutex::new(None);
static RUNS: Mutex<BTreeMap<String, Value>> = Mutex::new(BTreeMap::new());

fn remote_lock() -> std::sync::MutexGuard<'static, Option<Value>> {
    REMOTE.lock().unwrap_or_else(|p| p.into_inner())
}

fn runs_lock() -> std::sync::MutexGuard<'static, BTreeMap<String, Value>> {
    RUNS.lock().unwrap_or_else(|p| p.into_inner())
}

/// Forgets what the tab has listed and loaded (a test starts from a tab that has listed nothing yet).
pub fn forget() {
    *remote_lock() = None;
    runs_lock().clear();
}

fn default_client() -> Box<dyn Routines> {
    Box::new(RoutinesClient::new())
}

fn answer(status: &'static str, body: Value) -> Reply {
    (status, "application/json; charset=utf-8", body.to_string().into_bytes())
}

use crate::gui_local_automations::text;

fn arg(e: QmError) -> String {
    e.message
}

fn store() -> AutomationStore {
    AutomationStore::current()
}

fn entry_of(slug: &str) -> Result<Entry, String> {
    store().read(slug).map_err(arg)?.ok_or_else(|| format!("no automation '{slug}'"))
}

/// The reply for a /api/automations route, None for any other.
pub fn respond(method: &str, route: &str, body: &[u8]) -> Option<Reply> {
    respond_with(default_client, method, route, body)
}

pub fn respond_with(client: Client, method: &str, route: &str, body: &[u8]) -> Option<Reply> {
    if route != "/api/automations" && !route.starts_with("/api/automations/") {
        return None;
    }
    let verb = route.trim_start_matches("/api/automations").trim_start_matches('/');
    let request = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
    let slug = text(request.get("slug"));
    let result = match (method, verb) {
        ("GET", "") => Ok(list()),
        ("GET", slug) => detail(slug),
        ("POST", "refresh") => Ok(refresh(client)),
        ("POST", "runs") => load_runs(client, &slug),
        ("POST", "adopt") => adopt(client, &request),
        ("POST", "new") => create(&request),
        ("POST", "install-tick" | "uninstall-tick") => Ok(locals::install_tick(verb == "install-tick")),
        ("POST", "local-pause") => locals::set_paused(request.get("paused") == Some(&json!(true))),
        ("POST", v) if ACTIONS.contains(&v) || locals::ACTIONS.contains(&v) => act(client, v, &slug, &request),
        _ => return None,
    };
    Some(match result {
        Ok(value) => answer("200 OK", value),
        Err(message) => answer("422 Unprocessable Content", json!({"ok": false, "error": message})),
    })
}

fn enabled() -> bool {
    crate::project_config::ProjectConfig::current().automations_token_source().is_some_and(|s| rc::TOKEN_SOURCES.contains(&s))
}

fn remote_state() -> Value {
    if !enabled() {
        return json!({"state": "off", "message": format!("automations are off: run `{}`", rc::CONFIG_COMMAND), "command": rc::CONFIG_COMMAND});
    }
    remote_lock().clone().unwrap_or_else(|| json!({"state": "idle"}))
}

/// Every local store entry with its item (none when the item is gone).
fn rows() -> Result<Vec<(Entry, Option<WorkItem>)>, String> {
    Ok(store().list().map_err(arg)?.into_iter().map(|e| { let item = item_or_none(&e.slug); (e, item) }).collect())
}

fn schedule(cron: Option<&str>) -> Value {
    let Some(cron) = cron else { return Value::Null };
    let s = LocalSchedule::from_cron(cron, Utc::now());
    json!({"label": s.label(), "days": s.days, "time": s.time, "raw": s.raw()})
}

fn list() -> Value {
    let remote = remote_state();
    let entries = rows().unwrap_or_default();
    let routines = remote.get("routines").and_then(Value::as_object);
    let payload: Vec<Value> = entries.iter().map(|(entry, item)| if local_automations::local(entry) { locals::row(entry, item.as_ref(), Utc::now()) } else { row_payload(entry, item.as_ref(), routines) }).collect();
    let managed: Vec<&str> = payload.iter().filter_map(|r| r["routine"].as_str()).collect();
    let unmanaged: Vec<Value> = routines.into_iter().flat_map(|m| m.values()).filter(|r| !managed.contains(&r["id"].as_str().unwrap_or(""))).map(|r| {
        let cron = r["cron_expression"].as_str();
        json!({"id": r["id"], "name": r["name"], "cron": r["cron_expression"], "enabled": r["enabled"] != json!(false), "schedule": schedule(cron), "routineUrl": rc::routine_url(r["id"].as_str().unwrap_or(""))})
    }).collect();
    let mut shown = remote.clone();
    if let Some(m) = shown.as_object_mut() {
        m.remove("routines");
    }
    let entries: Vec<Entry> = entries.into_iter().map(|(e, _)| e).collect();
    json!({"remote": shown, "local": locals::header(&entries, Utc::now()), "rows": payload, "unmanaged": unmanaged})
}

fn item_payload(item: Option<&WorkItem>) -> Value {
    item.map_or(Value::Null, |i| {
        let notes: Vec<Value> = i.notes().iter().map(|n| json!({"stamp": n.stamp, "kind": n.kind, "text": n.text, "position": n.position})).collect();
        json!({"title": i.title(), "project": i.project(), "state": i.state(), "description": i.description(), "notes": notes})
    })
}

fn detail(slug: &str) -> Result<Value, String> {
    let entry = entry_of(slug)?;
    let item = item_or_none(slug);
    let mut out = if local_automations::local(&entry) {
        locals::detail(&entry, item.as_ref())?
    } else {
        let record = &entry.record;
        let runs = runs_lock().get(slug).cloned().unwrap_or_else(|| json!({"state": "idle"}));
        let store = store();
        let names = |key: &str, pick: &dyn Fn(&Value) -> Option<Value>| Value::Array(record.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(pick).collect());
        let mut out = row_payload(&entry, item.as_ref(), remote_state().get("routines").and_then(Value::as_object));
        out["prompt"] = json!(entry.prompt);
        out["model"] = record.get("model").cloned().unwrap_or(Value::Null);
        out["promptPath"] = json!(store.prompt_path(slug).map_err(arg)?);
        out["ymlPath"] = json!(store.yml_path(slug).map_err(arg)?);
        out["repos"] = names("sources", &|s| s.as_object().and_then(|_| s.pointer("/git_repository/url").or_else(|| s.get("url")).cloned()));
        out["connectors"] = names("connectors", &|c| c.as_object().and_then(|_| c.get("name").cloned()));
        out["runs"] = runs.get("runs").cloned().unwrap_or(Value::Null);
        out["runsState"] = runs["state"].clone();
        out["runsError"] = runs.get("error").cloned().unwrap_or(Value::Null);
        out
    };
    out["item"] = item_payload(item.as_ref());
    Ok(out)
}

fn row_payload(entry: &Entry, item: Option<&WorkItem>, routines: Option<&Map<String, Value>>) -> Value {
    let record = &entry.record;
    let id = record.get("routine").and_then(Value::as_str);
    let remote = id.and_then(|id| routines.and_then(|r| r.get(id)));
    let run = remote.and_then(|r| r.get("last_run")).filter(|r| r.is_object());
    let at = run.and_then(|r| r.get("finished_at").filter(|v| !v.is_null()).or_else(|| r.get("fired_at")));
    json!({
        "slug": entry.slug, "name": record.get("name").filter(|n| !n.is_null()).cloned().unwrap_or_else(|| json!(item.map_or(entry.slug.clone(), WorkItem::title))),
        "project": item.and_then(WorkItem::project), "state": item.and_then(WorkItem::state), "cron": record.get("cron").cloned().unwrap_or(Value::Null),
        "schedule": schedule(record.get("cron").and_then(Value::as_str)), "enabled": record.get("enabled") != Some(&json!(false)),
        "runner": record.get("runner").filter(|r| !r.is_null()).cloned().unwrap_or_else(|| json!("cloud")), "routine": id,
        "routineUrl": id.map(rc::routine_url), "drift": drift(entry, remote), "missing": id.is_some() && routines.is_some() && remote.is_none(),
        "nextRunAt": remote.and_then(|r| r.get("next_run_at")).cloned().unwrap_or(Value::Null),
        "lastRun": run.map(|r| json!({"status": r["status"], "at": at, "url": r["session_id"].as_str().map(rc::run_url)})),
    })
}

fn refresh(client: Client) -> Value {
    if !enabled() {
        return json!({"ok": true, "remote": remote_state()});
    }
    let loaded: Vec<String> = runs_lock().iter().filter(|(_, r)| r["state"] != "idle").map(|(slug, _)| slug.clone()).collect();
    gui_jobs::background("automations", "listing routines", false, move || {
        fetch_routines(&*client()).map_err(failure)?;
        let mut runs = runs_lock();
        for slug in &loaded {
            if let Some(shown) = runs.get(slug).cloned() {
                runs.insert(slug.clone(), stale(&shown));
            }
        }
        Ok(json!({"ok": true, "quiet": true, "automation": null}))
    })
}

/// What Ruby raises as an `ArgumentError`: its own, a stale push and every routines-client error.
pub(crate) fn argument_error(e: &QmError) -> bool {
    e.class == "ArgumentError" || e.class == STALE || e.class.starts_with("RoutinesClient::")
}

pub(crate) fn failure(e: QmError) -> Failure {
    if argument_error(&e) { Failure::Argument(e.message) } else { Failure::Other(e.message, e.class) }
}

fn unreachable(e: &QmError) -> bool {
    e.class == rc::NOT_ENABLED || e.class == rc::TOKEN_EXPIRED
}

/// The one list call; an unreachable API becomes the tab's state.
fn fetch_routines(client: &dyn Routines) -> Res<()> {
    match client.list() {
        Ok(routines) => {
            let by_id: Map<String, Value> = routines.into_iter().map(|r| (text(r.get("id")), r)).collect();
            *remote_lock() = Some(json!({"state": "ok", "fetchedAt": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true), "routines": by_id}));
            Ok(())
        }
        Err(e) if unreachable(&e) => Ok(set_unreachable(&e)),
        Err(e) if e.class.starts_with("RoutinesClient::") => {
            let mut remote = remote_lock();
            let mut state = remote.take().unwrap_or_else(|| json!({"state": "idle"}));
            state["state"] = json!("error");
            state["message"] = json!(e.message);
            *remote = Some(state);
            Ok(())
        }
        Err(e) => Err(e),
    }
}

fn set_unreachable(e: &QmError) {
    let state = if e.class == rc::NOT_ENABLED { "off" } else { "expired" };
    *remote_lock() = Some(json!({"state": state, "message": e.message}));
}

/// Runs shown until the page asks again: still listed, but idle, so the open detail reloads them.
fn stale(runs: &Value) -> Value {
    json!({"state": "idle", "runs": runs.get("runs").cloned().unwrap_or(Value::Null)})
}

fn load_runs(client: Client, slug: &str) -> Result<Value, String> {
    let id = entry_of(slug)?.record.get("routine").and_then(Value::as_str).map(String::from);
    let slug = slug.to_string();
    Ok(gui_jobs::background(&format!("automation-runs-{slug}"), "loading runs", false, move || {
        let loaded = match &id {
            Some(id) => client().runs(id, 10),
            None => Ok(vec![]),
        };
        let quiet = |error: &str| json!({"ok": false, "quiet": true, "error": error, "automation": slug});
        match loaded {
            Ok(runs) => {
                runs_lock().insert(slug.clone(), json!({"state": "ok", "runs": runs}));
                Ok(json!({"ok": true, "quiet": true, "automation": slug}))
            }
            Err(e) if unreachable(&e) => {
                set_unreachable(&e);
                runs_lock().insert(slug.clone(), json!({"state": "idle"}));
                Ok(quiet(&e.message))
            }
            Err(e) if e.class.starts_with("RoutinesClient::") => {
                runs_lock().insert(slug.clone(), json!({"state": "error", "error": e.message}));
                Ok(quiet(&e.message))
            }
            Err(e) => Err(failure(e)),
        }
    }))
}

fn adopt(client: Client, request: &Value) -> Result<Value, String> {
    let (id, project) = (text(request.get("id")), text(request.get("project")));
    if project.is_empty() {
        return Err(format!("pick a project for {id}"));
    }
    let slug = Some(text(request.get("slug"))).filter(|s| !s.is_empty());
    Ok(job(client, &format!("automation-adopt-{id}"), "adopting", move |service| {
        let entry = service.adopt(&id, &project, slug.as_deref())?;
        Ok((format!("adopted as {}", entry.slug), Some(entry.slug)))
    }))
}

/// A `kind: automation` item and its empty files; the page then opens its chat through the automation-chat action.
fn create(request: &Value) -> Result<Value, String> {
    let (title, project) = (text(request.get("title")).trim().to_string(), text(request.get("project")));
    if title.is_empty() || project.is_empty() {
        return Err("an automation needs a title and a project".into());
    }
    let description = text(request.get("description")).trim().to_string();
    let runner = Some(text(request.get("runner"))).filter(|r| !r.is_empty()).unwrap_or_else(|| "cloud".into());
    let item = crate::automation_chat::create(&title, &project, Some(description.as_str()).filter(|d| !d.is_empty()), &runner, &store()).map_err(arg)?;
    Ok(json!({"ok": true, "slug": item.slug}))
}

fn act(client: Client, verb: &str, slug: &str, request: &Value) -> Result<Value, String> {
    let entry = entry_of(slug)?;
    if local_automations::local(&entry) {
        if !locals::ACTIONS.contains(&verb) {
            return Err(format!("{slug} runs locally — nothing on claude.ai"));
        }
        return locals::act(verb, slug, request);
    }
    if !ACTIONS.contains(&verb) {
        return Err(format!("{verb} is for local automations"));
    }
    if verb == "apply" {
        save_edits(&entry, request)?;
    }
    let (verb, slug, request) = (verb.to_string(), slug.to_string(), request.clone());
    let label = if verb == "apply" { "pushing".to_string() } else { verb.clone() };
    Ok(job(client, &format!("automation-{slug}"), &label, move |service| {
        let message = run_action(service, &verb, &slug, &request);
        let mut runs = runs_lock();
        if let Some(shown) = runs.get(&slug).cloned() {
            runs.insert(slug.clone(), stale(&shown));
        }
        message.map(|m| (m, Some(slug.clone())))
    }))
}

fn run_action(service: &Automations, verb: &str, slug: &str, request: &Value) -> Res<String> {
    Ok(match verb {
        "apply" | "push" => {
            let changes = service.push(slug, verb == "push" && request.get("force") == Some(&json!(true)), false)?.changes;
            if changes.is_empty() { format!("{slug}: nothing to push") } else { format!("{slug}: {}", changes.join("; ")) }
        }
        "recreate" => format!("{slug}: {}", service.push(slug, false, true)?.changes.join("; ")),
        "pull" => {
            let changes = service.pull(slug)?;
            if changes.is_empty() { format!("{slug}: already in sync") } else { format!("{slug}: pulled {}", changes.join(", ")) }
        }
        "pause" | "resume" => {
            if verb == "pause" { service.pause(slug)? } else { service.resume(slug, false).map(|_| ())? }
            format!("{slug}: {}", if verb == "pause" { "paused" } else { "resumed" })
        }
        "run" => {
            service.run(slug)?;
            format!("{slug}: running")
        }
        _ => {
            let routine = service.store().read(slug)?.and_then(|e| e.record.get("routine").and_then(Value::as_str).map(String::from));
            match service.delete(slug)? {
                Removed::Paused => format!("{slug}: paused; delete it on claude.ai: {}", rc::routine_url(routine.as_deref().unwrap_or(""))),
                Removed::Deleted => format!("{slug}: deleted"),
                Removed::Local => format!("{slug}: removed (it was never pushed)"),
            }
        }
    })
}

/// Apply's schedule and prompt land in the local files before the push.
fn save_edits(entry: &Entry, request: &Value) -> Result<(), String> {
    let mut changes = Map::new();
    if request.get("cron").is_some() {
        let cron = text(request.get("cron")).trim().to_string();
        if cron.split_whitespace().count() != 5 {
            return Err(format!("a cron has five fields (minute hour day month weekday), got {}", crate::gui_server::inspect(&cron)));
        }
        changes.insert("cron".into(), json!(cron));
    } else if request.get("days").is_some() {
        let days: Vec<i64> = request["days"].as_array().map(|a| a.iter().filter_map(Value::as_i64).collect()).unwrap_or_default();
        changes.insert("cron".into(), json!(local_schedule::to_cron(&days, &text(request.get("time")), Utc::now())?));
    }
    let prompt = if request.get("prompt").is_some() { text(request.get("prompt")) } else { entry.prompt.clone() };
    store().write(&entry.slug, &changes, &prompt).map_err(arg)?;
    Ok(())
}

/// A network action as a job: its message for the toast, then one list call, also after a refusal (a stale push
/// then shows its drift); an unreachable API answers quietly (the tab shows why).
fn job(client: Client, key: &str, label: &str, work: impl FnOnce(&Automations) -> Res<(String, Option<String>)> + Send + 'static) -> Value {
    gui_jobs::background(key, label, false, move || {
        let routines = client();
        let service = Automations::new(&*routines, store());
        match work(&service) {
            Ok((message, slug)) => {
                fetch_routines(&*routines).map_err(failure)?;
                Ok(json!({"ok": true, "message": message, "automation": slug}))
            }
            Err(e) if unreachable(&e) => {
                set_unreachable(&e);
                Ok(json!({"ok": false, "quiet": true, "error": e.message}))
            }
            Err(e) if argument_error(&e) => {
                fetch_routines(&*routines).map_err(failure)?;
                Ok(json!({"ok": false, "error": e.message}))
            }
            Err(e) => Err(failure(e)),
        }
    })
}
