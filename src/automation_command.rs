//! `qm automation …`: the user's claude.ai routines through the `Automations` service, and the local ones
//! (`local_automation_command`). A routines-client error (off, token expired, API changed) ends the command with
//! its message on stderr and exit 1.

use chrono::{DateTime, Local, Utc};
use serde_json::{json, Value};

use crate::automation_chat;
use crate::automation_store::AutomationStore;
use crate::automations::{Automations, Detail, Removed, Row};
use crate::cli_format::short_path;
use crate::error::{QmError, UNEMITTABLE};
use crate::gui_action::{self, truthy, Failed};
use crate::launcher::Mode;
use crate::local_automations as local;
use crate::local_schedule::LocalSchedule;
use crate::outcome::{done, Outcome};
use crate::project_config::shell_escape;
use crate::routines_client::{self, RoutinesClient};

pub const USAGE: &str = "usage: qm automation list | show SLUG | new TITLE --project P [--description TEXT] [--runner cloud|local] | edit SLUG | adopt TRIGGER_ID --project P [--slug S] | push SLUG [--force | --recreate] | pull SLUG | pause SLUG | resume SLUG [--skip-existing] | run SLUG | delete SLUG [--yes] | runs SLUG | retry SLUG RUN_ID | tick [--dry-run [SLUG]] | install-tick [--print] | uninstall-tick";

/// How a subcommand ends early: an `abort` message, or "this spelling isn't read here".
pub(crate) enum Stop {
    Abort(String),
    Refused,
}

impl From<QmError> for Stop {
    fn from(e: QmError) -> Stop {
        if e.class == UNEMITTABLE { Stop::Refused } else { Stop::Abort(format!("qm: {}", e.message)) }
    }
}

pub(crate) type Said = Result<(), Stop>;

pub(crate) fn usage() -> Stop {
    Stop::Abort(USAGE.into())
}

/// `puts`.
pub(crate) fn say(out: &mut String, text: impl AsRef<str>) {
    out.push_str(text.as_ref());
    out.push('\n');
}

/// Ruby's `to_s` of a JSON value.
pub(crate) fn s(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(t)) => t.clone(),
        Some(other) => other.to_string(),
    }
}

pub(crate) fn local_time(time: Option<DateTime<Utc>>) -> String {
    time.map(|t| t.with_timezone(&Local).format("%Y-%m-%d %H:%M").to_string()).unwrap_or_default()
}

/// An ISO time as "2026-11-05 07:10 UTC"; what isn't one stays as it was; nothing for no value.
fn short_time(iso: Option<&Value>) -> Option<String> {
    let text = iso.and_then(Value::as_str).filter(|t| !t.is_empty())?;
    Some(DateTime::parse_from_rfc3339(text).map_or_else(|_| text.to_string(), |t| t.with_timezone(&Utc).format("%Y-%m-%d %H:%M UTC").to_string()))
}

fn run_status(status: Option<&Value>) -> String {
    let text = s(status);
    if text.is_empty() { "none".into() } else { text.strip_prefix("ROUTINE_RUN_STATUS_").unwrap_or(&text).to_lowercase() }
}

pub fn run(args: &[String]) -> Outcome {
    let mut out = String::new();
    match dispatch(args, &mut out) {
        Ok(()) => done(out),
        Err(Stop::Abort(message)) => Outcome::Done { code: 1, stdout: out, stderr: format!("{message}\n") },
        Err(Stop::Refused) => Outcome::Refused,
    }
}

fn dispatch(args: &[String], out: &mut String) -> Said {
    let (sub, rest) = (args.first().map(String::as_str).ok_or_else(usage)?, args.get(1..).unwrap_or(&[]));
    let mut rest = rest.to_vec();
    match sub {
        "list" => list(out),
        "show" => show(&slug(&mut rest)?, out),
        "new" => new(&rest, out),
        "edit" => chat("edit", &slug(&mut rest)?, out),
        "adopt" => adopt(&rest, out),
        "push" => push(&mut rest, out),
        "pull" => pull(&slug(&mut rest)?, out),
        "pause" => pause(&slug(&mut rest)?, out),
        "resume" => resume(&mut rest, out),
        "run" => run_now(&slug(&mut rest)?, out),
        "delete" => delete(&mut rest, out),
        "runs" | "retry" | "tick" | "install-tick" | "uninstall-tick" => crate::local_automation_command::dispatch(sub, &rest, out),
        _ => Err(usage()),
    }
}

/// Removes every exact `flag` and says whether there was one.
fn take_flag(args: &mut Vec<String>, flag: &str) -> bool {
    let before = args.len();
    args.retain(|a| a != flag);
    args.len() != before
}

/// The one word left once a command's flags are taken out.
pub(crate) fn slug(args: &mut Vec<String>) -> Result<String, Stop> {
    if args.len() == 1 { Ok(args.remove(0)) } else { Err(usage()) }
}

/// Runs `f` with the service over this process's client and store.
fn with_service<T>(f: impl FnOnce(&Automations) -> Result<T, Stop>) -> Result<T, Stop> {
    let client = RoutinesClient::new();
    f(&Automations::new(&client, AutomationStore::current()))
}

fn row_line(row: &Row) -> String {
    let record = &row.entry.record;
    let is_local = local::local(&row.entry);
    let cron = s(record.get("cron"));
    let schedule = if is_local { local::schedule_label(&cron) } else { LocalSchedule::from_cron(&cron, Utc::now()).label() };
    let item = row.item.as_ref();
    [
        row.slug.clone(),
        item.and_then(|i| i.project()).unwrap_or_else(|| "-".into()),
        item.and_then(|i| i.state()).unwrap_or_else(|| "-".into()),
        schedule,
        (if record.get("enabled") == Some(&json!(false)) { "paused" } else { "enabled" }).into(),
        (if is_local { "local" } else { "cloud" }).into(),
    ]
    .join("  ")
}

fn remote_status(status: &crate::automations::Status) -> String {
    let Some(remote) = &status.remote else {
        return if status.row.entry.record.get("routine").is_some_and(|r| !r.is_null()) { "not on claude.ai" } else { "not pushed yet" }.into();
    };
    let empty = json!({});
    let run = remote.get("last_run").filter(|r| r.is_object()).unwrap_or(&empty);
    let last = format!("last run {}{}", run_status(run.get("status")), if truthy(run.get("status")) { short_time(run.get("finished_at").filter(|v| truthy(Some(v))).or(run.get("fired_at"))).map(|t| format!(" {t}")).unwrap_or_default() } else { String::new() });
    let mut parts = vec![last, format!("next {}", short_time(remote.get("next_run_at")).unwrap_or_else(|| "-".into()))];
    if status.drift {
        parts.push("changed outside qm (pull or push --force)".into());
    }
    parts.join(", ")
}

/// The local files at once, local runs from their run logs, then one list call for each routine's status and
/// the routines qm doesn't manage yet; with automations off that call is skipped when only local rows exist.
fn list(out: &mut String) -> Said {
    with_service(|service| {
        let rows = service.local()?;
        rows.iter().for_each(|row| say(out, row_line(row)));
        if rows.is_empty() {
            say(out, "no automations yet");
        }
        let (locals, clouds): (Vec<Row>, Vec<Row>) = rows.into_iter().partition(|row| local::local(&row.entry));
        for row in &locals {
            crate::local_automation_command::status_line(service, &row.slug, out)?;
        }
        if !locals.is_empty() {
            say(out, crate::local_automation_command::tick_status());
        }
        let cloud_rows = clouds.len();
        let overview = match service.overview(clouds) {
            Ok(overview) => overview,
            Err(e) if e.class == routines_client::NOT_ENABLED && cloud_rows == 0 && !locals.is_empty() => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        overview.rows.iter().for_each(|status| say(out, format!("{}: {}", status.row.slug, remote_status(status))));
        if !overview.unmanaged.is_empty() {
            say(out, "");
            say(out, "Not managed by qm (qm automation adopt ID --project P):");
            for routine in &overview.unmanaged {
                say(out, format!("  {}  {}  {}", s(routine.get("id")), s(routine.get("name")), LocalSchedule::from_cron(&s(routine.get("cron_expression")), Utc::now()).label()));
            }
        }
        Ok(())
    })
}

fn show(slug: &str, out: &mut String) -> Said {
    with_service(|service| {
        let detail = match service.detail(slug, 10)? {
            Detail::Local(detail) => return crate::local_automation_command::show(&detail, out),
            Detail::Cloud(detail) => detail,
        };
        let record = &detail.entry.record;
        say(out, s(record.get("name")));
        if let Some(item) = &detail.item {
            say(out, format!("item: {}  {}  {}", detail.slug, item.project().unwrap_or_default(), item.state().unwrap_or_default()));
        }
        let cron = s(record.get("cron"));
        say(out, format!("schedule: {}  ({cron} UTC)", LocalSchedule::from_cron(&cron, Utc::now()).label()));
        say(out, format!("enabled: {}  runner: {}  model: {}", record.get("enabled") != Some(&json!(false)), s(record.get("runner")), s(record.get("model"))));
        let list = |key: &str| record.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
        let repos: Vec<String> = list("sources").iter().filter_map(|src| src.pointer("/git_repository/url").or(src.get("url")).filter(|v| !v.is_null()).map(|v| s(Some(v)))).collect();
        say(out, format!("repos: {}", repos.join(", ")));
        say(out, format!("connectors: {}", list("connectors").iter().filter_map(|c| c.get("name").filter(|v| !v.is_null()).map(|v| s(Some(v)))).collect::<Vec<_>>().join(", ")));
        say(out, format!("prompt: {}", service.store().prompt_path(&detail.slug)?.display()));
        say(out, format!("routine: {}", record.get("routine").filter(|r| !r.is_null()).map(|r| routines_client::routine_url(&s(Some(r)))).unwrap_or_else(|| "not pushed yet".into())));
        if detail.drift {
            say(out, format!("changed outside qm: `qm automation pull {0}` or `qm automation push {0} --force`", detail.slug));
        }
        say(out, format!("runs:{}", if detail.runs.is_empty() { " none" } else { "" }));
        for run in &detail.runs {
            let status = Some(s(run.get("status"))).filter(|t| !t.is_empty()).unwrap_or_else(|| "?".into());
            say(out, format!("  {status}  {}  {}  {}", short_time(run.get("created_at")).unwrap_or_else(|| "-".into()), s(run.get("title")), s(run.get("url"))));
        }
        Ok(())
    })
}

/// `--project P` and `--slug S` among the words; the rest are positional.
fn named(args: &[String], names: &[&str]) -> Result<(Vec<(String, String)>, Vec<String>), Stop> {
    let (mut found, mut rest) = (vec![], vec![]);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if names.contains(&word.as_str()) {
            found.push((word.clone(), words.next().ok_or(Stop::Refused)?.clone()));
        } else if word == "--" {
            rest.extend(words.by_ref().cloned());
        } else {
            rest.push(word.clone());
        }
    }
    Ok((found, rest))
}

fn last<'a>(found: &'a [(String, String)], name: &str) -> Option<&'a str> {
    found.iter().rev().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

fn adopt(args: &[String], out: &mut String) -> Said {
    let (found, rest) = named(args, &["--project", "--slug"])?;
    let (Some(id), Some(project)) = (rest.first(), last(&found, "--project")) else { return Err(usage()) };
    let entry = with_service(|service| Ok(service.adopt(id, project, last(&found, "--slug"))?))?;
    say(out, format!("adopted {id} as {}", entry.slug));
    Ok(())
}

fn push(args: &mut Vec<String>, out: &mut String) -> Said {
    let (force, recreate) = (take_flag(args, "--force"), take_flag(args, "--recreate"));
    let slug = slug(args)?;
    let result = with_service(|service| Ok(service.push(&slug, force, recreate)?))?;
    say(out, if result.changes.is_empty() { format!("{slug}: nothing to push") } else { format!("{slug}: {}", result.changes.join("; ")) });
    Ok(())
}

fn pull(slug: &str, out: &mut String) -> Said {
    let changes = with_service(|service| Ok(service.pull(slug)?))?;
    say(out, if changes.is_empty() { format!("{slug}: already in sync") } else { format!("{slug}: pulled {} (previous files kept as .bak)", changes.join(", ")) });
    Ok(())
}

fn pause(slug: &str, out: &mut String) -> Said {
    with_service(|service| Ok(service.pause(slug)?))?;
    say(out, format!("{slug}: paused"));
    Ok(())
}

fn resume(args: &mut Vec<String>, out: &mut String) -> Said {
    let skip = take_flag(args, "--skip-existing");
    let slug = slug(args)?;
    let marked = with_service(|service| Ok(service.resume(&slug, skip)?))?;
    let noted = if skip { format!(", {marked} existing {} marked seen", if marked == 1 { "item" } else { "items" }) } else { String::new() };
    say(out, format!("{slug}: resumed{noted}"));
    Ok(())
}

fn run_now(slug: &str, out: &mut String) -> Said {
    with_service(|service| {
        let entry = service.store().read(slug)?.ok_or_else(|| QmError::argument(format!("no automation '{slug}'")))?;
        if local::local(&entry) {
            let ids = service.local_automations().run(slug, Utc::now())?;
            return crate::local_automation_command::after_run(service, slug, &ids, "", out);
        }
        service.run(slug)?;
        say(out, format!("{slug}: running — {}", routines_client::routine_url(&s(entry.record.get("routine")))));
        Ok(())
    })
}

fn delete(args: &mut Vec<String>, out: &mut String) -> Said {
    let yes = take_flag(args, "--yes");
    let slug = slug(args)?;
    with_service(|service| {
        let entry = service.store().read(&slug)?.ok_or_else(|| QmError::argument(format!("no automation '{slug}'")))?;
        if !yes {
            let place = if local::local(&entry) { "(its files and run log)" } else { "on claude.ai" };
            let name = Some(s(entry.record.get("name"))).filter(|n| !n.is_empty()).unwrap_or_else(|| slug.clone());
            eprint!("Delete {name} {place} and resolve {slug}? [y/N] ");
            let mut answer = String::new();
            let _ = std::io::stdin().read_line(&mut answer);
            if !answer.trim().to_lowercase().starts_with('y') {
                return Err(Stop::Abort("qm automation: not deleted".into()));
            }
        }
        match service.delete(&slug)? {
            Removed::Paused => say(out, format!("{slug}: paused; delete it on claude.ai: {}", routines_client::routine_url(&s(entry.record.get("routine"))))),
            Removed::Deleted => say(out, format!("{slug}: deleted")),
            Removed::Local => say(out, format!("{slug}: removed (it was never pushed)")),
        }
        Ok(())
    })
}

/// The item and its empty local files, then its chat with the brief.
fn new(args: &[String], out: &mut String) -> Said {
    let (found, rest) = named(args, &["--project", "--description", "--runner"])?;
    let (Some(project), [title]) = (last(&found, "--project"), &rest[..]) else { return Err(usage()) };
    let runner = last(&found, "--runner").unwrap_or("cloud");
    let refuse = |e: QmError| Stop::Abort(format!("qm automation new: {}", e.message));
    let item = automation_chat::create(title, project, last(&found, "--description"), runner, &AutomationStore::current()).map_err(refuse)?;
    say(out, format!("{}: created ({project}{}), files in {}", item.slug, if runner == "local" { ", runs locally" } else { "" }, short_path(Some(&crate::automation_store::dir().to_string_lossy()))));
    chat("new", &item.slug, out)
}

/// Opens (or resumes) the chat in the running GUI and brings the GUI up on it; a chat already running gets
/// nothing typed — the brief is printed to paste by hand. Without a GUI, prints how to start it in a terminal.
fn chat(name: &str, slug: &str, out: &mut String) -> Said {
    let refuse = |e: QmError| Stop::Abort(format!("qm automation {name}: {}", e.message));
    let store = AutomationStore::current();
    let item = automation_chat::automation(slug).map_err(refuse)?;
    let reply = match gui_action::call_optional(&format!("automation {name}"), "automation-chat", Some(&item.slug), json!({})) {
        Ok(reply) => reply,
        Err(Failed::Abort(message)) => return Err(Stop::Abort(message)),
        Err(Failed::Unsupported) => return Err(Stop::Refused),
    };
    let Some(reply) = reply else {
        let plan = automation_chat::plan(&item, &store).map_err(refuse)?;
        if matches!(plan.mode, Mode::Live) {
            return Err(Stop::Abort(format!("qm automation {name}: {} has a chat running outside the GUI — continue there", item.slug)));
        }
        say(out, "no qm gui running — start its chat with:");
        say(out, format!("  cd {} && QM_ITEM={} {}", shell_escape(&plan.cwd), item.slug, plan.argv.iter().map(|a| shell_escape(a)).collect::<Vec<_>>().join(" ")));
        return Ok(());
    };
    let _ = crate::chat_launch_commands::open_chat(&[item.slug.clone()]);
    if truthy(reply.get("attached")) {
        say(out, format!("{}: its chat is already running in the qm gui — nothing typed; paste this brief there if it needs it:", item.slug));
        say(out, s(reply.get("brief")));
    } else {
        say(out, format!("{}: its chat {} in the qm gui", item.slug, if s(reply.get("mode")) == "resume" { "resumed" } else { "started" }));
    }
    Ok(())
}
