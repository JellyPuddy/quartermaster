//! One local automation's runs: `automations/<slug>.runs.jsonl`, append-only, one `{v, at, event, …}` line per
//! event, and the fold of it. Writers name the event; the fold gives the queue, live and recent runs, the keys
//! already seen, the last guard error and the last cron check. A writer that decides from the fold re-reads it
//! and appends under one flock, so a tick and a CLI or GUI write never both queue a key.

use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Map, Value};

use crate::automation_store::{self, AutomationStore};
use crate::error::{QmError, Res};
use crate::random_id;
pub use crate::run_fold::{Fold, Run};

pub const VERSION: i64 = 1;

pub struct RunLog {
    pub slug: String,
    dir: PathBuf,
}

/// The log held under its flock: what a writer deciding from the fold works on.
pub struct Locked {
    file: File,
    path: PathBuf,
}

fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Secs, true)
}

impl RunLog {
    pub fn new(slug: &str, dir: &Path) -> Res<RunLog> {
        if !automation_store::valid_slug(slug) {
            return Err(QmError::argument(format!("not an automation slug: {slug:?}")));
        }
        Ok(RunLog { slug: slug.to_string(), dir: dir.to_path_buf() })
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(format!("{}.runs.jsonl", self.slug))
    }

    /// The session ids of every run of a `notify: quiet` local automation, which attention and turn
    /// notifications leave out.
    pub fn quiet_session_ids(dir: &Path) -> HashSet<String> {
        let found = (|| -> Res<HashSet<String>> {
            let mut ids = HashSet::new();
            for entry in AutomationStore::new(dir).list()? {
                if entry.record.get("runner").and_then(Value::as_str) == Some("local") && entry.record.get("notify").and_then(Value::as_str) == Some("quiet") {
                    ids.extend(RunLog::new(&entry.slug, dir)?.runs().into_iter().filter_map(|r| r.session_id));
                }
            }
            Ok(ids)
        })();
        found.unwrap_or_else(|e| {
            crate::data_root::log_error("quiet-runs", e.class, &e.message);
            HashSet::new()
        })
    }

    /// The sessions of a local automation item's runs: attached to the item through QM_ITEM, but never its chat,
    /// so no resume path picks one.
    pub fn session_ids_for(item: &crate::work_item::WorkItem, dir: &Path) -> Vec<String> {
        if !item.automation() || item.runner().as_deref() != Some("local") {
            return vec![];
        }
        RunLog::new(&item.slug, dir).map(|log| log.runs().into_iter().filter_map(|r| r.session_id).collect()).unwrap_or_default()
    }

    /// Runs `f` holding the log's flock, with the fold readable fresh from `Locked`.
    pub fn exclusively<T>(&self, f: impl FnOnce(&mut Locked) -> Res<T>) -> Res<T> {
        std::fs::create_dir_all(&self.dir)?;
        let file = OpenOptions::new().append(true).create(true).open(self.path())?;
        // SAFETY: flock on a descriptor this function owns.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        f(&mut Locked { file, path: self.path() })
    }

    pub fn fold(&self) -> Fold {
        Fold::read(&self.path())
    }

    pub fn runs(&self) -> Vec<Run> {
        self.fold().runs
    }

    pub fn queue(&self) -> Vec<Run> {
        self.fold().queue()
    }

    pub fn live(&self) -> Vec<Run> {
        self.fold().live()
    }

    pub fn recent(&self, limit: usize) -> Vec<Run> {
        self.fold().recent(limit)
    }

    pub fn run(&self, id: &str) -> Option<Run> {
        self.fold().run(id).cloned()
    }

    pub fn seen_keys(&self) -> HashSet<String> {
        self.fold().seen
    }

    pub fn last_guard_error(&self) -> Option<Value> {
        self.fold().guard_error
    }

    pub fn last_cron_check(&self) -> Option<DateTime<Utc>> {
        self.fold().checked
    }

    fn append(&self, event: &str, at: DateTime<Utc>, fields: Value) -> Res<()> {
        self.exclusively(|log| log.append(event, at, fields))
    }

    /// Queues a run with no dedupe; returns its id.
    pub fn enqueue(&self, key: &str, item: &Value, flow: &str, trigger: &str, at: DateTime<Utc>) -> Res<String> {
        self.exclusively(|log| log.enqueue(key, item, flow, trigger, at))
    }

    /// Queues a guard item unless its key was seen; returns the run id or None.
    pub fn enqueue_item(&self, key: &str, item: &Value, flow: &str, trigger: &str, at: DateTime<Utc>) -> Res<Option<String>> {
        self.exclusively(|log| if log.fold().seen.contains(key) { Ok(None) } else { log.enqueue(key, item, flow, trigger, at).map(Some) })
    }

    /// Records a guard item its flow refuses (it never queues) unless its key was seen; the key counts as seen,
    /// so it is reported once. Returns the refused run id or None.
    pub fn refuse_item(&self, key: &str, item: &Value, flow: &str, trigger: &str, reason: &str, at: DateTime<Utc>) -> Res<Option<String>> {
        self.exclusively(|log| {
            if log.fold().seen.contains(key) {
                return Ok(None);
            }
            let id = random_id::alphanumeric(8);
            log.append("refused", at, json!({"run_id": id, "key": key, "item": item, "flow": flow, "trigger": trigger, "reason": reason}))?;
            Ok(Some(id))
        })
    }

    /// Queues the run a due cron minute asks for, unless a cron run is already queued; returns the run id or None.
    pub fn enqueue_cron(&self, due: DateTime<Utc>, flow: &str, at: DateTime<Utc>) -> Res<Option<String>> {
        self.exclusively(|log| if log.fold().cron_queued() { Ok(None) } else { log.enqueue(&format!("cron:{}", iso(due)), &Value::Null, flow, "cron", at).map(Some) })
    }

    /// Queues a new run with an ended run's item, bypassing dedupe; returns its id.
    pub fn retry(&self, run_id: &str, at: DateTime<Utc>) -> Res<String> {
        self.exclusively(|log| {
            let fold = log.fold();
            let old = fold.run(run_id).ok_or_else(|| QmError::argument(format!("no run {run_id} in {}", self.slug)))?;
            if old.queued() || old.live() {
                return Err(QmError::argument(format!("run {run_id} is still {}", old.status)));
            }
            let id = random_id::alphanumeric(8);
            log.append("retried", at, json!({"run_id": run_id, "new_run_id": id}))?;
            log.append("queued", at, json!({"run_id": id, "key": old.key, "item": old.item, "flow": old.flow, "trigger": "retry"}))?;
            Ok(id)
        })
    }

    pub fn started(&self, run_id: &str, session_id: &str, tmux: &str, item_slug: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("started", at, json!({"run_id": run_id, "session_id": session_id, "tmux": tmux, "item_slug": item_slug}))
    }

    /// Records why a queued run doesn't start, only when the reason changed.
    pub fn waiting(&self, run_id: &str, reason: &str, at: DateTime<Utc>) -> Res<()> {
        self.exclusively(|log| if log.fold().run(run_id).and_then(|r| r.waiting.as_deref()) == Some(reason) { Ok(()) } else { log.append("waiting", at, json!({"run_id": run_id, "reason": reason})) })
    }

    pub fn finished(&self, run_id: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("finished", at, json!({"run_id": run_id}))
    }

    pub fn timed_out(&self, run_id: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("timed_out", at, json!({"run_id": run_id}))
    }

    pub fn closed(&self, run_id: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("closed", at, json!({"run_id": run_id}))
    }

    /// A queued run its flow refused at start.
    pub fn refused(&self, run_id: &str, reason: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("refused", at, json!({"run_id": run_id, "reason": reason}))
    }

    pub fn failed(&self, run_id: &str, error: &str, at: DateTime<Utc>) -> Res<()> {
        self.append("failed", at, json!({"run_id": run_id, "error": error}))
    }

    pub fn guard_error(&self, error: &str, item: Option<&Value>, at: DateTime<Utc>) -> Res<()> {
        let mut fields = json!({"error": error});
        if let Some(item) = item.filter(|i| !i.is_null()) {
            fields["item"] = item.clone();
        }
        self.append("guard_error", at, fields)
    }

    /// A guard run that exited cleanly; clears the last guard error.
    pub fn guard_ran(&self, items: usize, at: DateTime<Utc>) -> Res<()> {
        self.append("guard_ran", at, json!({"items": items}))
    }

    /// Keys recorded as seen without queuing a run.
    pub fn mark_seen(&self, keys: &[String], at: DateTime<Utc>) -> Res<()> {
        self.append("seen", at, json!({"keys": keys}))
    }

    /// The tick handled a due cron minute up to `at`.
    pub fn checked(&self, at: DateTime<Utc>) -> Res<()> {
        self.append("checked", at, json!({}))
    }
}

impl Locked {
    /// The fold, read fresh: what other writers have appended up to now.
    pub fn fold(&self) -> Fold {
        Fold::read(&self.path)
    }

    pub fn append(&mut self, event: &str, at: DateTime<Utc>, fields: Value) -> Res<()> {
        let mut line = Map::new();
        line.insert("v".into(), json!(VERSION));
        line.insert("at".into(), json!(iso(at)));
        line.insert("event".into(), json!(event));
        if let Value::Object(more) = fields {
            line.extend(more);
        }
        writeln!(self.file, "{}", Value::Object(line))?;
        Ok(self.file.flush()?)
    }

    fn enqueue(&mut self, key: &str, item: &Value, flow: &str, trigger: &str, at: DateTime<Utc>) -> Res<String> {
        let id = random_id::alphanumeric(8);
        self.append("queued", at, json!({"run_id": id, "key": key, "item": item, "flow": flow, "trigger": trigger}))?;
        Ok(id)
    }
}
