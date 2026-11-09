//! The Automations tab's `runner: local` part, never the network: `gui_automations` hands it every local slug
//! and asks it for the tab header's tick status. Rows and detail read the run logs and tick.json; Run now,
//! Enable (with "mark existing as seen"), Retry and the tick's Install/Uninstall run as `gui_jobs` jobs (a guard
//! may take 60 s, a tick starts runs, launchctl is an external tool); the pause toggle writes config.yml; Resume
//! reopens an ended chat run under its own tmux name.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Map, Value};

use crate::automation_store::{AutomationStore, Entry};
use crate::automation_tick::{self, Tick};
use crate::error::QmError;
use crate::gui_jobs::{self, Failure};
use crate::local_automations::{self as local, LocalAutomations};
use crate::local_cron::{self, LocalCron};
use crate::run_fold::Run;
use crate::tick_installer::TickInstaller;
use crate::work_item::WorkItem;

/// Enabled local automations that went this long (seconds) without a tick show the tab's "no tick" warning.
const STALE_TICK: i64 = 15 * 60;
pub const ACTIONS: [&str; 7] = ["apply", "pause", "resume", "run", "delete", "retry", "resume-run"];

/// What a local action answers, or the `ArgumentError` text the router turns into a 422.
pub type Answer = Result<Value, String>;

fn arg(e: QmError) -> String {
    e.message
}

fn iso(time: Option<DateTime<Utc>>) -> Value {
    time.map_or(Value::Null, |t| json!(t.to_rfc3339_opts(SecondsFormat::Secs, true)))
}

pub(crate) fn text(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

fn presence(v: Option<&Value>) -> Value {
    let t = text(v);
    if t.trim().is_empty() { Value::Null } else { json!(t) }
}

fn schedule(cron: &str) -> Value {
    if cron.is_empty() {
        return Value::Null;
    }
    if let Some(error) = local_cron::error(cron) {
        return json!({"label": format!("{cron} (invalid: {error})"), "raw": true});
    }
    match LocalCron::new(cron) {
        Ok(c) => json!({"label": c.label(), "days": c.days(), "time": c.time(), "raw": !c.simple()}),
        Err(_) => Value::Null,
    }
}

fn store() -> AutomationStore {
    AutomationStore::current()
}

fn locals() -> LocalAutomations {
    LocalAutomations::new(store().dir())
}

/// A row of the list: schedule, enabled, next run, queue and live counts, last run.
pub fn row(entry: &Entry, item: Option<&WorkItem>, now: DateTime<Utc>) -> Value {
    let record = &entry.record;
    let log = locals().run_log(&entry.slug);
    let last = log.as_ref().ok().and_then(|l| l.recent(1).into_iter().next());
    let cron = text(record.get("cron")).trim().to_string();
    let next = if cron.is_empty() || local_cron::error(&cron).is_some() { None } else { local_cron::next_after(&cron, now).ok().flatten() };
    let counts = |f: fn(&crate::run_log::RunLog) -> usize| log.as_ref().map(f).unwrap_or(0);
    json!({
        "slug": entry.slug, "name": record.get("name").filter(|n| !n.is_null()).cloned().unwrap_or_else(|| json!(item.map_or(entry.slug.clone(), WorkItem::title))),
        "project": item.and_then(WorkItem::project), "state": item.and_then(WorkItem::state), "cron": record.get("cron").cloned().unwrap_or(Value::Null),
        "schedule": schedule(&cron), "enabled": record.get("enabled") != Some(&json!(false)), "runner": "local", "routine": null, "drift": false, "missing": false,
        "nextRunAt": iso(next), "queued": counts(|l| l.queue().len()), "live": counts(|l| l.live().len()),
        "lastRun": last.map(|run| json!({"status": run.status, "at": iso(run.started_at.or(run.ended_at))})),
    })
}

/// The tab header's local part: the tick (installed, last tick, stale when enabled local automations went 15
/// minutes without one), the global pause and the last tick's usage hold.
pub fn header(entries: &[Entry], now: DateTime<Utc>) -> Value {
    let state = automation_tick::state(store().dir());
    let settings = crate::project_config::ProjectConfig::current().local_automations().clone();
    let last = state.get("last_tick_at").and_then(Value::as_str).and_then(|t| DateTime::parse_from_rfc3339(t).ok()).map(|t| t.with_timezone(&Utc));
    let locals: Vec<&Entry> = entries.iter().filter(|e| local::local(e)).collect();
    let enabled = locals.iter().any(|e| e.record.get("enabled") != Some(&json!(false)));
    let max = settings.max_running;
    json!({
        "count": locals.len(), "installed": TickInstaller::new().installed(), "lastTickAt": state.get("last_tick_at").cloned().unwrap_or(Value::Null),
        "stale": enabled && last.is_none_or(|t| (now - t).num_seconds() > STALE_TICK), "paused": settings.paused,
        "held": state.get("held").cloned().unwrap_or(Value::Null), "running": state.get("running").cloned().unwrap_or(Value::Null),
        "maxRunning": if max.fract() == 0.0 { json!(max as i64) } else { json!(max) },
    })
}

fn subject(run: &Run) -> Value {
    let named = run.item.as_object().and_then(|i| i.get("title").filter(|t| !t.is_null()).or_else(|| i.get("key").filter(|k| !k.is_null())));
    match named {
        Some(v) => json!(text(Some(v))),
        None => json!(run.key),
    }
}

fn run_payload(run: &Run, chats: &[String]) -> Value {
    let own = run.flow.as_deref() == Some("chat");
    let name = if own { run.tmux.clone() } else { run.item_slug.clone() };
    let live = if own { name.as_ref().is_some_and(|n| chats.contains(n)) } else { name.is_some() };
    json!({
        "id": run.id, "status": run.status, "trigger": run.trigger, "subject": subject(run), "error": run.error,
        "startedAt": iso(run.started_at), "endedAt": iso(run.finished_at.or(run.ended_at)), "retriedAs": run.retried_as,
        "chat": if live { json!(name) } else { Value::Null }, "runChat": own, "resumable": own && !live && run.session_id.is_some(),
        "retryable": !run.live() && run.retried_as.is_none(),
    })
}

/// A local automation's detail: its settings, guard, queue and recent runs with their chats.
pub fn detail(entry: &Entry, item: Option<&WorkItem>) -> Result<Value, String> {
    let d = locals().detail(&entry.slug).map_err(arg)?;
    let record = &entry.record;
    let chats = crate::tmux::Tmux::new().sessions();
    let mut out = match row(entry, item, Utc::now()) {
        Value::Object(m) => m,
        _ => Map::new(),
    };
    let setting = |k: &str| d.settings.get(k).cloned().unwrap_or(Value::Null);
    let store = store();
    let pairs = [
        ("prompt", json!(entry.prompt)), ("model", record.get("model").cloned().unwrap_or(Value::Null)),
        ("promptPath", json!(store.prompt_path(&entry.slug).map_err(arg)?)), ("ymlPath", json!(store.yml_path(&entry.slug).map_err(arg)?)),
        ("guard", presence(record.get("when"))), ("flow", setting("flow")), ("notify", setting("notify")), ("timeoutMinutes", setting("timeout_minutes")),
        ("permissionMode", record.get("permission_mode").cloned().unwrap_or(Value::Null)),
        ("allowedTools", record.get("allowed_tools").filter(|t| t.is_array()).cloned().unwrap_or_else(|| json!([]))),
        ("cwd", json!(crate::cli_format::short_path(Some(&crate::chat_flow::cwd(entry))))),
        ("guardError", d.guard_error.as_ref().map_or(Value::Null, |e| json!({"error": e.get("error"), "at": e.get("at")}))),
        ("queue", Value::Array(d.queue.iter().map(|run| json!({"id": run.id, "trigger": run.trigger, "subject": subject(run), "queuedAt": iso(Some(run.queued_at)), "waiting": run.waiting})).collect())),
        ("runs", Value::Array(d.recent.iter().map(|run| run_payload(run, &chats)).collect())), ("runsState", json!("ok")),
    ];
    out.extend(pairs.into_iter().map(|(k, v)| (k.to_string(), v)));
    Ok(Value::Object(out))
}

/// A local action. Quick file changes answer at once; the rest start a job.
pub fn act(verb: &str, slug: &str, request: &Value) -> Answer {
    let done = |what: &str, result: Result<(), QmError>| result.map(|_| json!({"ok": true, "message": format!("{slug}: {what}"), "automation": slug})).map_err(arg);
    match verb {
        "apply" => done("saved", save_edits(slug, request)),
        "resume-run" => resume_run(slug, &text(request.get("run"))),
        "pause" => done("paused", locals().pause(slug)),
        "delete" => done("deleted", locals().delete(slug)),
        _ => Ok(job(slug, verb, request.clone())),
    }
}

fn job(slug: &str, verb: &str, request: Value) -> Value {
    let slug = slug.to_string();
    let label = if verb == "resume" { "enabling" } else { verb };
    let verb = verb.to_string();
    gui_jobs::background(&format!("automation-{slug}"), label, false, move || match run_action(&verb, &slug, &request) {
        Ok(message) => Ok(json!({"ok": true, "message": message, "automation": slug})),
        Err(e) => Err(crate::gui_automations::failure(e)),
    })
}

fn run_action(verb: &str, slug: &str, request: &Value) -> Result<String, QmError> {
    let local = locals();
    match verb {
        "resume" => {
            let skip = request.get("skipExisting") == Some(&json!(true));
            let marked = local.resume(slug, skip, Utc::now())?;
            let noun = if marked == 1 { "item" } else { "items" };
            Ok(format!("{slug}: enabled{}", if skip { format!(", {marked} existing {noun} marked seen") } else { String::new() }))
        }
        "run" => {
            let ids = local.run(slug, Utc::now())?;
            started_message(&local, slug, &ids, "run")
        }
        _ => {
            let id = local.retry(slug, &text(request.get("run")), Utc::now())?;
            started_message(&local, slug, &[id], "retry")
        }
    }
}

/// Queued run ids, then one tick so they start now when nothing holds them.
fn started_message(local: &LocalAutomations, slug: &str, ids: &[String], what: &str) -> Result<String, QmError> {
    if ids.is_empty() {
        return Ok(format!("{slug}: the guard found nothing new"));
    }
    let tick = local.tick().call(Utc::now());
    let started = match &tick {
        Some(Tick::Ran(summary)) => summary.started.iter().filter(|(s, id)| s == slug && ids.contains(id)).count(),
        _ => 0,
    };
    let queued = ids.len() - started;
    let mut parts = vec![];
    if started > 0 {
        parts.push(format!("started {started} {what}{}", if started > 1 { "s" } else { "" }));
    }
    if queued > 0 {
        parts.push(format!("queued {queued} ({})", wait_reason(local, slug, ids, &tick)));
    }
    Ok(format!("{slug}: {}", parts.join("; ")))
}

fn wait_reason(local: &LocalAutomations, slug: &str, ids: &[String], tick: &Option<Tick>) -> String {
    let log = local.run_log(slug).ok();
    if let Some(waiting) = ids.iter().find_map(|id| log.as_ref().and_then(|l| l.run(id)).and_then(|r| r.waiting)) {
        return format!("waiting: {waiting}");
    }
    match tick {
        None | Some(Tick::Locked) => "the next tick starts it".into(),
        Some(Tick::Ran(s)) if s.paused => "local automations are paused".into(),
        Some(Tick::Ran(s)) if s.held.is_some() => format!("held: {}", s.held.clone().unwrap_or_default()),
        Some(Tick::Ran(s)) => format!("{} of {} running", s.running, text(Some(&s.max_running))),
    }
}

/// Apply saves the local files only: a local automation has nothing to push.
fn save_edits(slug: &str, request: &Value) -> Result<(), QmError> {
    let store = store();
    let entry = store.read(slug)?.ok_or_else(|| QmError::argument(format!("no automation '{slug}'")))?;
    let mut changes = Map::new();
    if request.get("cron").is_some() {
        let cron = text(request.get("cron")).trim().to_string();
        if let Some(error) = Some(&cron).filter(|c| !c.is_empty()).and_then(|c| local_cron::error(c)) {
            return Err(QmError::argument(error));
        }
        changes.insert("cron".into(), json!(cron));
    } else if request.get("days").is_some() {
        let days: Vec<i64> = request["days"].as_array().map(|a| a.iter().filter_map(Value::as_i64).collect()).unwrap_or_default();
        changes.insert("cron".into(), json!(local_cron::to_cron(&days, &text(request.get("time"))).map_err(QmError::argument)?));
    }
    let prompt = if request.get("prompt").is_some() { text(request.get("prompt")) } else { entry.prompt };
    store.write(slug, &changes, &prompt)?;
    Ok(())
}

/// Resume: an ended chat run's session again, in a tmux of its own name.
fn resume_run(slug: &str, run_id: &str) -> Answer {
    let entry = store().read(slug).map_err(arg)?.ok_or_else(|| format!("no automation '{slug}'"))?;
    let run = locals().run_log(slug).map_err(arg)?.run(run_id).ok_or_else(|| format!("no run {run_id} in {slug}"))?;
    if run.session_id.is_none() || run.flow.as_deref() != Some("chat") {
        return Err(format!("run {run_id} has no session to resume"));
    }
    let name = crate::chat_flow::resume(&entry, &run)?;
    Ok(json!({"ok": true, "name": name, "message": format!("{slug}: run {run_id} resumed")}))
}

/// Install or uninstall the launchd tick, as a job.
pub fn install_tick(install: bool) -> Value {
    gui_jobs::background("automation-tick", if install { "installing the tick" } else { "removing the tick" }, false, move || {
        let installer = TickInstaller::new();
        let done = if install { installer.install() } else { installer.uninstall() };
        done.map_err(|e| Failure::Argument(e.message))?;
        let message = if install { "tick installed: launchd runs `qm automation tick` every 5 minutes" } else { "tick uninstalled" };
        Ok(json!({"ok": true, "message": message, "automation": null}))
    })
}

/// The global pause, written to config.yml as `qm config set` would.
pub fn set_paused(paused: bool) -> Answer {
    let file = crate::data_root::config_file();
    let mut config = crate::config_file::ConfigFile::load(&file);
    config.set("automations.local_paused", serde_yaml::Value::Bool(paused)).map_err(|e| format!("config.yml not saved: {e}"))?;
    config.write(None).map_err(|e| format!("config.yml not saved: {}", e.message()))?;
    Ok(json!({"ok": true, "paused": paused}))
}
