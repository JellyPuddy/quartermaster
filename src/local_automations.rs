//! What the CLI and the GUI do with a `runner: local` automation, never over the network: its runs from the run
//! log, a manual run, pause and resume (the item's state follows, with a history note), retry and delete. The
//! guard and the tick are the scheduler's own (`automation_tick`).

use std::path::Path;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};

use crate::automation_flows as flows;
use crate::automation_store::{local_settings, AutomationStore, Entry, Record};
use crate::automation_tick::AutomationTick;
use crate::error::{QmError, Res};
use crate::run_log::{Run, RunLog};
use crate::work_item::WorkItem;
use crate::local_cron;

/// Whether the store entry runs on this machine.
pub fn local(entry: &Entry) -> bool {
    entry.record.get("runner").and_then(Value::as_str) == Some("local")
}

/// "every day 08:00", the cron as Amsterdam time, or manual only.
pub fn schedule_label(cron: &str) -> String {
    if cron.trim().is_empty() {
        return "manual only (no cron)".into();
    }
    match local_cron::error(cron) {
        Some(error) => format!("{cron} (invalid: {error})"),
        None => local_cron::label(cron).unwrap_or_else(|e| e),
    }
}

/// One local automation with its settings (defaults filled), schedule, queue, live and recent runs and its
/// last guard error.
pub struct Detail {
    pub slug: String,
    pub entry: Entry,
    pub item: Option<WorkItem>,
    pub settings: Record,
    pub schedule: String,
    pub next_at: Option<DateTime<Utc>>,
    pub queue: Vec<Run>,
    pub live: Vec<Run>,
    pub recent: Vec<Run>,
    pub guard_error: Option<Value>,
}

pub struct LocalAutomations {
    store: AutomationStore,
}

pub fn item_or_none(slug: &str) -> Option<WorkItem> {
    WorkItem::path_for(slug).exists().then(|| WorkItem::find(slug).ok()).flatten()
}

impl LocalAutomations {
    pub fn new(dir: &Path) -> LocalAutomations {
        LocalAutomations { store: AutomationStore::new(dir) }
    }

    pub fn tick(&self) -> AutomationTick {
        AutomationTick::new(self.store.dir())
    }

    pub fn run_log(&self, slug: &str) -> Res<RunLog> {
        RunLog::new(slug, self.store.dir())
    }

    pub fn detail(&self, slug: &str) -> Res<Detail> {
        let entry = self.entry(slug)?;
        let log = self.run_log(slug)?;
        let cron = entry.record.get("cron").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let next_at = if cron.is_empty() || local_cron::error(&cron).is_some() { None } else { local_cron::next_after(&cron, Utc::now()).ok().flatten() };
        Ok(Detail {
            slug: slug.to_string(),
            item: item_or_none(slug),
            settings: local_settings(&entry.record),
            schedule: schedule_label(&cron),
            next_at,
            queue: log.queue(),
            live: log.live(),
            recent: log.recent(20),
            guard_error: log.last_guard_error(),
            entry,
        })
    }

    /// Queues a manual run now and answers the queued run ids: with a guard, one per new item it prints; without
    /// one, a single run with no item.
    pub fn run(&self, slug: &str, now: DateTime<Utc>) -> Res<Vec<String>> {
        let entry = self.entry(slug)?;
        if !entry.record.get("when").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
            return self.tick().queue_guard(slug, "manual", now).map_err(QmError::argument);
        }
        let settings = local_settings(&entry.record);
        let flow = settings.get("flow").and_then(Value::as_str);
        if let Some(problem) = flows::problem(flow, &Value::Null) {
            return Err(QmError::argument(format!("{slug}: {problem}")));
        }
        let key = format!("manual:{}", now.to_rfc3339_opts(SecondsFormat::Secs, true));
        Ok(vec![self.run_log(slug)?.enqueue(&key, &Value::Null, flow.unwrap_or(flows::DEFAULT), "manual", now)?])
    }

    pub fn pause(&self, slug: &str) -> Res<()> {
        let entry = self.entry(slug)?;
        self.set_enabled(&entry, false, "paused")
    }

    /// Enables the automation; `skip_existing` first records the keys its guard prints now as seen, so only items
    /// that appear later queue runs. Answers how many keys it marked.
    pub fn resume(&self, slug: &str, skip_existing: bool, now: DateTime<Utc>) -> Res<usize> {
        let entry = self.entry(slug)?;
        if !skip_existing {
            self.set_enabled(&entry, true, "resumed")?;
            return Ok(0);
        }
        if entry.record.get("when").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
            return Err(QmError::argument(format!("{slug} has no guard (when:), so there are no existing items to mark seen")));
        }
        let keys: Vec<String> = self.tick().dry_run(slug).map_err(QmError::argument)?.items.iter().map(|item| item["key"].as_str().unwrap_or("").to_string()).collect();
        if !keys.is_empty() {
            self.run_log(slug)?.mark_seen(&keys, now)?;
        }
        self.set_enabled(&entry, true, &format!("resumed; {} existing guard {} marked seen", keys.len(), if keys.len() == 1 { "item" } else { "items" }))?;
        Ok(keys.len())
    }

    /// Queues an ended run's item again; answers the new run id. Refused while its flow refuses the item (a
    /// pr-review repo not in the yml's repos).
    pub fn retry(&self, slug: &str, run_id: &str, now: DateTime<Utc>) -> Res<String> {
        let entry = self.entry(slug)?;
        let log = self.run_log(slug)?;
        if let Some(old) = log.run(run_id).filter(|old| !old.item.is_null()) {
            if let Some(reason) = flows::refusal(old.flow.as_deref(), &entry.record, &old.item) {
                return Err(QmError::argument(format!("{slug}: can't retry run {run_id}: {reason}")));
            }
        }
        log.retry(run_id, now)
    }

    /// Removes the files and the run log and resolves the item (its notes kept); refused while a run is live.
    pub fn delete(&self, slug: &str) -> Res<()> {
        self.entry(slug)?;
        let live = self.run_log(slug)?.live().len();
        if live > 0 {
            let what = if live == 1 { "a live run".to_string() } else { format!("{live} live runs") };
            return Err(QmError::argument(format!("{slug} has {what} — stop or finish its runs first")));
        }
        self.store.delete_local(slug)?;
        if let Some(mut item) = item_or_none(slug) {
            item.add_note("deleted", "history")?;
            item.update_state("resolved")?;
        }
        Ok(())
    }

    fn entry(&self, slug: &str) -> Res<Entry> {
        let entry = self.store.read(slug)?.ok_or_else(|| QmError::argument(format!("no automation '{slug}'")))?;
        if !local(&entry) {
            return Err(QmError::argument(format!("{slug} runs on claude.ai, not locally")));
        }
        Ok(entry)
    }

    fn set_enabled(&self, entry: &Entry, enabled: bool, note: &str) -> Res<()> {
        let record: Record = json!({"enabled": enabled}).as_object().cloned().unwrap_or_default();
        self.store.write(&entry.slug, &record, &entry.prompt)?;
        let Some(mut item) = item_or_none(&entry.slug) else { return Ok(()) };
        item.add_note(note, "history")?;
        let state = if enabled { "active" } else { "fridge" };
        if item.state().as_deref() != Some(state) {
            item.update_state(state)?;
        }
        Ok(())
    }
}
