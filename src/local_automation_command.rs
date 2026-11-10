//! The `qm automation …` subcommands and output for `runner: local` automations (part of `automation_command`):
//! their rows and runs from the run log with no network, a manual run or retry followed by one tick so it starts
//! at once when it can, the tick itself and its LaunchAgent.

use chrono::Utc;
use serde_json::Value;

use crate::automation_command::{local_time, say, s, slug, usage, Said, Stop, USAGE};
use crate::automation_store::AutomationStore;
use crate::automation_tick::{self, Tick};
use crate::automations::Automations;
use crate::error::QmError;
use crate::local_automations::{self as local, Detail};
use crate::routines_client::RoutinesClient;
use crate::run_log::Run;
use crate::tick_installer::{TickInstaller, LABEL};
use crate::chat_flow;

pub(crate) fn status_line(service: &Automations, slug: &str, out: &mut String) -> Said {
    let log = service.local_automations().run_log(slug)?;
    let last = log.recent(1).into_iter().next();
    let last = match last {
        Some(run) => format!("{} {}", run.status, local_time(run.started_at.or(run.ended_at))),
        None => "none".into(),
    };
    say(out, format!("{slug}: on this machine, {} queued, {} live, last run {last}", log.queue().len(), log.live().len()));
    Ok(())
}

pub(crate) fn tick_status() -> String {
    let last = automation_tick::state(&crate::automation_store::dir()).get("last_tick_at").and_then(Value::as_str).and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok()).map(|t| t.with_timezone(&Utc));
    let installed = if TickInstaller::new().installed() { "installed" } else { "not installed (qm automation install-tick)" };
    format!("tick: {installed}{}", last.map(|t| format!(", last tick {}", local_time(Some(t)))).unwrap_or_default())
}

pub(crate) fn show(detail: &Detail, out: &mut String) -> Said {
    let record = &detail.entry.record;
    say(out, s(record.get("name")));
    if let Some(item) = &detail.item {
        say(out, format!("item: {}  {}  {}", detail.slug, item.project().unwrap_or_default(), item.state().unwrap_or_default()));
    }
    let cron = s(record.get("cron")).trim().to_string();
    let hint = if cron.is_empty() || detail.schedule.contains(&cron) { String::new() } else { format!("  ({cron} Amsterdam time)") };
    say(out, format!("schedule: {}{hint}", detail.schedule));
    if let Some(next) = detail.next_at {
        say(out, format!("next run: {}", local_time(Some(next))));
    }
    let model = Some(s(record.get("model"))).filter(|m| !m.is_empty()).unwrap_or_else(|| "default".into());
    say(out, format!("enabled: {}  runner: local  model: {model}", record.get("enabled") != Some(&Value::Bool(false))));
    let guard = s(record.get("when"));
    say(out, format!("guard: {}", if guard.trim().is_empty() { "none — a due cron queues one run".to_string() } else { guard }));
    say(out, format!("flow: {}  notify: {}  timeout: {} min", s(detail.settings.get("flow")), s(detail.settings.get("notify")), s(detail.settings.get("timeout_minutes"))));
    say(out, format!("cwd: {}", chat_flow::cwd(&detail.entry)));
    say(out, format!("prompt: {}", AutomationStore::current().prompt_path(&detail.slug)?.display()));
    if let Some(error) = &detail.guard_error {
        say(out, format!("last guard error: {}", s(error.get("error"))));
    }
    run_lines(&detail.queue, &detail.recent.iter().take(10).cloned().collect::<Vec<_>>(), out);
    Ok(())
}

fn run_lines(queue: &[Run], runs: &[Run], out: &mut String) {
    say(out, format!("queued:{}", if queue.is_empty() { " none" } else { "" }));
    for run in queue {
        let waiting = run.waiting.as_ref().map(|w| format!("  waiting: {w}")).unwrap_or_default();
        say(out, format!("  {}  {}  {}{waiting}", run.id, run.trigger.clone().unwrap_or_default(), run.key.clone().unwrap_or_default()));
    }
    say(out, format!("runs:{}", if runs.is_empty() { " none" } else { "" }));
    for run in runs {
        let detail = if run.live() { Some(format!("tmux {}", run.tmux.clone().unwrap_or_default())) } else { run.error.clone() };
        say(out, format!("  {}  {}  {}  {}{}", run.id, run.status, local_time(run.started_at.or(run.ended_at)), run.key.clone().unwrap_or_default(), detail.map(|d| format!("  {d}")).unwrap_or_default()));
    }
}

fn runs(slug: &str, out: &mut String) -> Said {
    let detail = local::LocalAutomations::new(&crate::automation_store::dir()).detail(slug)?;
    run_lines(&detail.queue, &detail.recent, out);
    Ok(())
}

fn runs_phrase(ids: &[String]) -> String {
    if ids.len() == 1 { format!("run {}", ids[0]) } else { format!("{} runs ({})", ids.len(), ids.join(", ")) }
}

/// Queued run ids, then one tick so they start now when nothing holds them.
pub(crate) fn after_run(service: &Automations, slug: &str, ids: &[String], note: &str, out: &mut String) -> Said {
    if ids.is_empty() {
        say(out, format!("{slug}: the guard found nothing new"));
        return Ok(());
    }
    let tick = service.local_automations().tick().call(Utc::now());
    let started: Vec<String> = match &tick {
        Some(Tick::Ran(summary)) => summary.started.iter().filter(|(s, id)| s == slug && ids.contains(id)).map(|(_, id)| id.clone()).collect(),
        _ => vec![],
    };
    let queued: Vec<String> = ids.iter().filter(|id| !started.contains(id)).cloned().collect();
    let mut parts = vec![];
    if !started.is_empty() {
        parts.push(format!("started {}{note}", runs_phrase(&started)));
    }
    if !queued.is_empty() {
        parts.push(format!("queued {}{note} — {}", runs_phrase(&queued), wait_reason(service, slug, &queued, &tick)?));
    }
    say(out, format!("{slug}: {}", parts.join("; ")));
    Ok(())
}

fn wait_reason(service: &Automations, slug: &str, ids: &[String], tick: &Option<Tick>) -> Result<String, QmError> {
    let log = service.local_automations().run_log(slug)?;
    if let Some(waiting) = ids.iter().find_map(|id| log.run(id).and_then(|run| run.waiting)) {
        return Ok(format!("waiting: {waiting}"));
    }
    Ok(match tick {
        None => "the tick failed (see qm.log); the next tick starts it".into(),
        Some(Tick::Locked) => "a tick is running; the next tick starts it".into(),
        Some(Tick::Ran(summary)) if summary.paused => "local automations are paused (qm config set automations.local_paused false)".into(),
        Some(Tick::Ran(summary)) if summary.held.is_some() => format!("held: {}", summary.held.clone().unwrap_or_default()),
        Some(Tick::Ran(summary)) => format!("the next tick starts it when a slot is free ({} of {} running)", summary.running, s(Some(&summary.max_running))),
    })
}

fn retry(args: &[String], out: &mut String) -> Said {
    let [slug, old] = args else { return Err(usage()) };
    let client = RoutinesClient::new();
    let service = Automations::new(&client, AutomationStore::current());
    let id = service.local_automations().retry(slug, old, Utc::now())?;
    after_run(&service, slug, &[id], &format!(" (retry of {old})"), out)
}

/// One scheduler pass (what launchd runs every 5 minutes); quiet when it did nothing and nobody is watching.
/// --dry-run [SLUG] only runs guards.
fn tick(args: &[String], out: &mut String) -> Said {
    if args.first().map(String::as_str) == Some("--dry-run") {
        return dry_run(&args[1..], out);
    }
    if !args.is_empty() {
        return Err(usage());
    }
    let summary = match local::LocalAutomations::new(&crate::automation_store::dir()).tick().call(Utc::now()) {
        None => return Ok(say(out, "tick failed — see qm.log")),
        Some(Tick::Locked) => return Ok(say(out, "another tick is running")),
        Some(Tick::Ran(summary)) => summary,
    };
    let pairs = |list: &[(String, String)]| list.iter().map(|(slug, id)| format!("{slug}/{id}")).collect::<Vec<_>>().join(", ");
    let mut lines: Vec<String> = [("queued", &summary.queued), ("started", &summary.started), ("finished", &summary.finished), ("closed", &summary.closed), ("timed out", &summary.timed_out), ("failed", &summary.failed)]
        .iter()
        .filter(|(_, runs)| !runs.is_empty())
        .map(|(what, runs)| format!("{what} {}", pairs(runs)))
        .collect();
    lines.extend(summary.problems.iter().map(|(slug, problem)| format!("{slug}: {}", s(Some(problem)))));
    if let Some(held) = &summary.held {
        lines.push(format!("held: {held}"));
    }
    if summary.paused {
        lines.push("local automations are paused".into());
    }
    if lines.is_empty() && std::io::IsTerminal::is_terminal(&std::io::stdout()) {
        lines.push(format!("nothing to do ({} of {} running)", summary.running, s(Some(&summary.max_running))));
    }
    lines.iter().for_each(|line| say(out, line));
    Ok(())
}

fn dry_run(args: &[String], out: &mut String) -> Said {
    if args.len() > 1 {
        return Err(usage());
    }
    let client = RoutinesClient::new();
    let service = Automations::new(&client, AutomationStore::current());
    let slugs: Vec<String> = if args.is_empty() { service.local()?.into_iter().filter(|row| local::local(&row.entry)).map(|row| row.slug).collect() } else { args.to_vec() };
    if slugs.is_empty() {
        say(out, "no local automations");
    }
    for slug in &slugs {
        dry_run_lines(&service, slug, !args.is_empty(), out)?;
    }
    Ok(())
}

fn dry_run_lines(service: &Automations, slug: &str, single: bool, out: &mut String) -> Said {
    if !single {
        let entry = service.store().read(slug)?;
        if entry.is_some_and(|e| s(e.record.get("when")).trim().is_empty()) {
            let next = service.local_automations().detail(slug)?.next_at;
            say(out, format!("{slug}: no guard — {}", next.map_or("manual only".to_string(), |t| format!("the next cron run queues one run at {}", local_time(Some(t))))));
            return Ok(());
        }
    }
    let dry = match service.local_automations().tick().dry_run(slug) {
        Ok(dry) => dry,
        Err(message) if single => return Err(Stop::Abort(format!("qm: {message}"))),
        Err(message) => return Ok(say(out, format!("{slug}: {message}"))),
    };
    dry.items.iter().for_each(|item| say(out, format!("{slug}: would queue {}", s(item.get("key")))));
    dry.seen.iter().for_each(|item| say(out, format!("{slug}: already seen {}", s(item.get("key")))));
    for problem in &dry.problems {
        let item = match problem.get("item") {
            Some(item) if !item.is_null() => format!("{} ", item.get("key").filter(|k| !k.is_null()).map_or_else(|| item.to_string(), |k| s(Some(k)))),
            _ => String::new(),
        };
        say(out, format!("{slug}: refused {item}— {}", s(problem.get("error"))));
    }
    if dry.items.is_empty() && dry.seen.is_empty() && dry.problems.is_empty() {
        say(out, format!("{slug}: the guard prints nothing"));
    }
    Ok(())
}

fn install(args: &[String], out: &mut String) -> Said {
    let installer = TickInstaller::new();
    if args == ["--print"] {
        out.push_str(&installer.plist());
        return Ok(());
    }
    if !args.is_empty() {
        return Err(usage());
    }
    installer.install()?;
    say(out, format!("installed {}: launchd runs `qm automation tick` every 5 minutes, output in {}", installer.plist_path().display(), installer.log_path().display()));
    Ok(())
}

fn uninstall(args: &[String], out: &mut String) -> Said {
    if !args.is_empty() {
        return Err(usage());
    }
    TickInstaller::new().uninstall()?;
    say(out, format!("uninstalled {LABEL}: no more ticks"));
    Ok(())
}

pub(crate) fn dispatch(sub: &str, args: &[String], out: &mut String) -> Said {
    match sub {
        "runs" => runs(&slug(&mut args.to_vec())?, out),
        "retry" => retry(args, out),
        "tick" => tick(args, out),
        "install-tick" => install(args, out),
        "uninstall-tick" => uninstall(args, out),
        _ => Err(Stop::Abort(USAGE.into())),
    }
}
