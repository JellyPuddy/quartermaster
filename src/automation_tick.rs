//! One scheduler tick for local automations (launchd runs `qm automation tick` every 300 s). Under a
//! non-blocking flock on `automations/tick.lock` it checks each enabled automation's cron, runs the guard of a
//! due one or queues its coalesced cron run, then starts queued runs oldest-first through their flows while
//! the cap has free slots and no usage limit holds; it writes `automations/tick.json` and never waits for a
//! run. Before starting any, even while paused, `run_lifecycle` finishes, closes and times out the runs
//! already going.

use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::{json, Map, Value};

use crate::automation_flows::{self as flows, FlowError, Reply};
use crate::automation_store::{local_settings, validate_local, AutomationStore, Entry};
use crate::error::{QmError, Res};
use crate::project_config::{LocalAutomations, ProjectConfig};
use crate::run_lifecycle::RunLifecycle;
use crate::run_log::{Run, RunLog};
use crate::{atomic_file, automation_guard, chat_flow, data_root, local_cron, random_id};

const INTERVAL: i64 = 300;
const VERSION: i64 = 1;
const BY_HAND: [&str; 2] = ["manual", "retry"];

/// What a guard would queue now, without writing: new items the flow can take, ones already seen (a key the
/// guard repeats too) and the problems, refusals included.
#[derive(Debug)]
pub struct DryRun {
    pub items: Vec<Value>,
    pub seen: Vec<Value>,
    pub problems: Vec<Value>,
}

/// What one tick did; run lists are `(slug, run id)` pairs.
#[derive(Default, Debug)]
pub struct Summary {
    pub queued: Vec<(String, String)>,
    pub started: Vec<(String, String)>,
    pub failed: Vec<(String, String)>,
    pub finished: Vec<(String, String)>,
    pub closed: Vec<(String, String)>,
    pub timed_out: Vec<(String, String)>,
    pub problems: Map<String, Value>,
    pub paused: bool,
    pub held: Option<String>,
    pub running: usize,
    pub max_running: Value,
}

impl Summary {
    /// The summary as the CLI and the GUI report it.
    pub fn to_json(&self) -> Value {
        let pairs = |list: &[(String, String)]| Value::Array(list.iter().map(|(slug, id)| json!([slug, id])).collect());
        json!({"queued": pairs(&self.queued), "started": pairs(&self.started), "failed": pairs(&self.failed), "finished": pairs(&self.finished), "closed": pairs(&self.closed),
               "timed_out": pairs(&self.timed_out), "problems": self.problems, "paused": self.paused, "held": self.held, "running": self.running, "max_running": self.max_running})
    }
}

pub enum Tick {
    /// Another tick holds the lock: nothing was done.
    Locked,
    Ran(Box<Summary>),
}

pub struct AutomationTick {
    dir: PathBuf,
    store: AutomationStore,
    config: Option<LocalAutomations>,
    summary: Summary,
}

pub fn state_path(dir: &Path) -> PathBuf {
    dir.join("tick.json")
}

/// What the last tick wrote to tick.json, an empty map when nothing readable.
pub fn state(dir: &Path) -> Map<String, Value> {
    match std::fs::read_to_string(state_path(dir)).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        Some(Value::Object(m)) => m,
        _ => Map::new(),
    }
}

fn time(value: Option<&Value>) -> Option<DateTime<Utc>> {
    value.and_then(Value::as_str).and_then(|s| DateTime::parse_from_rfc3339(s).ok()).map(|t| t.with_timezone(&Utc))
}

fn number(n: f64) -> Value {
    if n.fract() == 0.0 && n.abs() < 1e15 { json!(n as i64) } else { json!(n) }
}

impl AutomationTick {
    pub fn new(dir: &Path) -> AutomationTick {
        AutomationTick { dir: dir.to_path_buf(), store: AutomationStore::new(dir), config: None, summary: Summary::default() }
    }

    /// Tick settings of its own instead of config.yml's.
    pub fn with_config(mut self, config: LocalAutomations) -> AutomationTick {
        self.config = Some(config);
        self
    }

    /// Runs one tick; None after an error (logged to qm.log, never raised).
    pub fn call(&mut self, now: DateTime<Utc>) -> Option<Tick> {
        match self.locked_tick(now) {
            Ok(tick) => Some(tick),
            Err(e) => {
                data_root::log_error("automation-tick", e.class, &e.message);
                None
            }
        }
    }

    fn locked_tick(&mut self, now: DateTime<Utc>) -> Res<Tick> {
        std::fs::create_dir_all(&self.dir)?;
        let lock = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(self.dir.join("tick.lock"))?;
        // SAFETY: a non-blocking flock on a descriptor this function owns; it is released when `lock` drops.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Ok(Tick::Locked);
        }
        self.summary = Summary::default();
        self.tick(now)?;
        Ok(Tick::Ran(Box::new(std::mem::take(&mut self.summary))))
    }

    /// The items the automation's guard would queue now, without writing.
    pub fn dry_run(&self, slug: &str) -> Result<DryRun, String> {
        let entry = self.local_entry(slug)?;
        let command = entry.record.get("when").and_then(Value::as_str).unwrap_or("");
        if command.trim().is_empty() {
            return Err(format!("{slug} has no guard (when:) — a due cron queues one run without an item"));
        }
        let (items, mut problems) = automation_guard::run(command, &chat_flow::cwd(&entry)).map_err(|e| e.0)?;
        let mut seen = RunLog::new(slug, &self.dir).map_err(|e| e.message)?.seen_keys();
        let settings = local_settings(&entry.record);
        let flow = settings.get("flow").and_then(Value::as_str);
        let (mut old, mut ok) = (vec![], vec![]);
        for item in items {
            let key = item["key"].as_str().unwrap_or("").to_string();
            if !seen.insert(key) {
                old.push(item);
            } else if let Some(why) = flows::problem(flow, &item).or_else(|| flows::refusal(flow, &entry.record, &item)) {
                problems.push(json!({"error": why, "item": item}));
            } else {
                ok.push(item);
            }
        }
        Ok(DryRun { items: ok, seen: old, problems })
    }

    /// Runs the guard now and queues its new items (trigger manual unless given); returns the queued run ids.
    /// Fails after recording a failed guard as a guard error.
    pub fn queue_guard(&mut self, slug: &str, trigger: &str, now: DateTime<Utc>) -> Result<Vec<String>, String> {
        let entry = self.local_entry(slug)?;
        let log = RunLog::new(slug, &self.dir).map_err(|e| e.message)?;
        self.queue_guard_items(&entry, &log, trigger, now, true).map_err(|e| e.message)
    }

    fn local_entry(&self, slug: &str) -> Result<Entry, String> {
        let entry = self.store.read(slug).map_err(|e| e.message)?.ok_or_else(|| format!("no automation {slug}"))?;
        if entry.record.get("runner").and_then(Value::as_str) != Some("local") {
            return Err(format!("{slug} runs on claude.ai, not locally"));
        }
        Ok(entry)
    }

    fn tick(&mut self, now: DateTime<Utc>) -> Res<()> {
        let previous = state(&self.dir);
        let settings = self.config.clone().unwrap_or_else(|| ProjectConfig::current().local_automations().clone());
        let locals: Vec<Entry> = self.store.list()?.into_iter().filter(|e| e.record.get("runner").and_then(Value::as_str) == Some("local")).collect();
        let paused = settings.paused;
        let since_tick = time(previous.get("last_tick_at"));
        if !paused {
            for entry in locals.iter().filter(|e| e.record.get("enabled") != Some(&Value::Bool(false))) {
                let found = self.check(entry, since_tick, now);
                self.guarded(entry, found);
            }
        }
        let held = hold(now, &settings);
        let mut lifecycle = RunLifecycle::new(&self.dir);
        for entry in &locals {
            let found = lifecycle.call(entry, now);
            match found {
                Ok(done) => {
                    let tag = |ids: Vec<String>| ids.into_iter().map(|id| (entry.slug.clone(), id)).collect::<Vec<_>>();
                    self.summary.finished.extend(tag(done.finished));
                    self.summary.closed.extend(tag(done.closed));
                    self.summary.timed_out.extend(tag(done.timed_out));
                    self.summary.failed.extend(tag(done.failed));
                }
                Err(e) => self.guarded(entry, Err::<(), _>(e)),
            }
        }
        let mut running = 0;
        for entry in &locals {
            running += RunLog::new(&entry.slug, &self.dir)?.live().iter().filter(|run| lifecycle.busy(run)).count();
        }
        if !paused && held.is_none() {
            self.start_queued(&locals, settings.max_running as i64 - running as i64, now);
        }
        self.summary.paused = paused;
        self.summary.held = held;
        self.summary.running = running + self.summary.started.len();
        self.summary.max_running = number(settings.max_running);
        self.write_state(now)
    }

    /// One automation's trouble is recorded and never stops the others.
    fn guarded<T>(&mut self, entry: &Entry, result: Res<T>) {
        if let Err(e) = result {
            self.summary.problems.insert(entry.slug.clone(), json!(e.message));
            data_root::log_error(&format!("automation-tick {}", entry.slug), e.class, &e.message);
        }
    }

    /// A due cron minute in (last check or last tick, now] runs the guard, or queues one cron run without one;
    /// either way the minute is checked.
    fn check(&mut self, entry: &Entry, since_tick: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Res<()> {
        let cron = entry.record.get("cron").and_then(Value::as_str).unwrap_or("").trim().to_string();
        if cron.is_empty() {
            return Ok(());
        }
        if let Some(error) = local_cron::error(&cron) {
            let shown = crate::ruby_text::inspect_ascii(&cron).unwrap_or_else(|| format!("{cron:?}"));
            self.summary.problems.insert(entry.slug.clone(), json!(format!("cron {shown}: {error}")));
            return Ok(());
        }
        validate_local(&entry.record)?;
        let log = RunLog::new(&entry.slug, &self.dir)?;
        let since = [log.last_cron_check(), since_tick].into_iter().flatten().max().unwrap_or(now - Duration::seconds(INTERVAL));
        let Some(due) = local_cron::LocalCron::new(&cron).map_err(QmError::argument)?.last_due(since, now) else { return Ok(()) };
        if entry.record.get("when").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
            self.queue_cron(entry, &log, due, now)?;
        } else {
            let ids = self.queue_guard_items(entry, &log, "guard", now, false)?;
            self.summary.queued.extend(ids.into_iter().map(|id| (entry.slug.clone(), id)));
        }
        log.checked(now)
    }

    fn queue_cron(&mut self, entry: &Entry, log: &RunLog, due: DateTime<Utc>, now: DateTime<Utc>) -> Res<()> {
        let settings = local_settings(&entry.record);
        let flow = settings.get("flow").and_then(Value::as_str);
        if let Some(problem) = flows::problem(flow, &Value::Null) {
            log.guard_error(&problem, None, now)?;
        } else if let Some(id) = log.enqueue_cron(due, flow.unwrap_or(flows::DEFAULT), now)? {
            self.summary.queued.push((entry.slug.clone(), id));
        }
        Ok(())
    }

    fn queue_guard_items(&self, entry: &Entry, log: &RunLog, trigger: &str, now: DateTime<Utc>, raise_failure: bool) -> Res<Vec<String>> {
        let command = entry.record.get("when").and_then(Value::as_str).unwrap_or("");
        let (items, problems) = match automation_guard::run(command, &chat_flow::cwd(entry)) {
            Ok(found) => found,
            Err(failed) => {
                log.guard_error(&failed.0, None, now)?;
                return if raise_failure { Err(QmError::argument(failed.0)) } else { Ok(vec![]) };
            }
        };
        let settings = local_settings(&entry.record);
        let flow = settings.get("flow").and_then(Value::as_str);
        log.guard_ran(items.len(), now)?;
        for p in &problems {
            log.guard_error(p["error"].as_str().unwrap_or(""), Some(&p["item"]), now)?;
        }
        let mut ids = vec![];
        for item in items {
            let key = item["key"].as_str().unwrap_or("");
            if let Some(problem) = flows::problem(flow, &item) {
                log.guard_error(&problem, Some(&item), now)?;
            } else if let Some(reason) = flows::refusal(flow, &entry.record, &item) {
                log.refuse_item(key, &item, flow.unwrap_or(flows::DEFAULT), trigger, &reason, now)?;
            } else if let Some(id) = log.enqueue_item(key, &item, flow.unwrap_or(flows::DEFAULT), trigger, now)? {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    /// A disabled automation still starts the runs the user asked for by hand.
    fn start_queued(&mut self, locals: &[Entry], slots: i64, now: DateTime<Utc>) {
        let mut queue: Vec<(&Entry, Run)> = vec![];
        for entry in locals {
            let Ok(log) = RunLog::new(&entry.slug, &self.dir) else { continue };
            let disabled = entry.record.get("enabled") == Some(&Value::Bool(false));
            queue.extend(log.queue().into_iter().filter(|run| !disabled || BY_HAND.contains(&run.trigger.as_deref().unwrap_or(""))).map(|run| (entry, run)));
        }
        queue.sort_by_key(|(_, run)| run.queued_at);
        let mut slots = slots;
        for (entry, run) in queue {
            if slots <= 0 {
                break;
            }
            if self.start(entry, &run, now) {
                slots -= 1;
            }
        }
    }

    /// Starts one queued run; true when a session started.
    fn start(&mut self, entry: &Entry, run: &Run, now: DateTime<Utc>) -> bool {
        let Ok(log) = RunLog::new(&entry.slug, &self.dir) else { return false };
        let session_id = random_id::uuid();
        let recorded = match flows::start(entry, &run.item, &entry.prompt, &run.id, &session_id) {
            Ok(Reply::Waiting(reason)) => log.waiting(&run.id, &reason, now).map(|_| false),
            Ok(Reply::Started { item_slug, tmux }) => log.started(&run.id, &session_id, &tmux, &item_slug, now).map(|_| {
                self.summary.started.push((entry.slug.clone(), run.id.clone()));
                true
            }),
            Err(FlowError::Refused(reason)) => log.refused(&run.id, &reason, now).map(|_| false),
            Err(FlowError::Other(message)) => log.failed(&run.id, &message, now).map(|_| {
                self.summary.failed.push((entry.slug.clone(), run.id.clone()));
                false
            }),
        };
        recorded.unwrap_or_else(|e| {
            self.guarded(entry, Err::<(), _>(e));
            false
        })
    }

    fn write_state(&self, now: DateTime<Utc>) -> Res<()> {
        let state = json!({"v": VERSION, "last_tick_at": now.to_rfc3339_opts(SecondsFormat::Secs, true), "paused": self.summary.paused, "held": self.summary.held, "running": self.summary.running,
                           "max_running": self.summary.max_running, "problems": self.summary.problems});
        Ok(atomic_file::write(&state_path(&self.dir), &format!("{}\n", serde_json::to_string_pretty(&state)?))?)
    }
}

/// "5h at 84%" while a usage window is at or over its hold; None when no limit holds or the snapshot is stale
/// (its 5-hour window has reset).
fn hold(now: DateTime<Utc>, settings: &LocalAutomations) -> Option<String> {
    let limits = crate::gui_state::rate_limits();
    if limits.is_null() {
        return None;
    }
    let reset = |window: &Value| window.get("resetsAt").and_then(Value::as_str).and_then(|s| DateTime::parse_from_rfc3339(s).ok()).is_some_and(|t| t <= now);
    if reset(&limits["fiveHour"]) {
        return None;
    }
    for (name, label, limit) in [("fiveHour", "5h", settings.hold_five_hour), ("sevenDay", "7d", settings.hold_seven_day)] {
        let window = &limits[name];
        let Some(used) = window.get("usedPercentage").and_then(Value::as_f64) else { continue };
        if used >= limit && !reset(window) {
            return Some(format!("{label} at {}%", used.round()));
        }
    }
    None
}
