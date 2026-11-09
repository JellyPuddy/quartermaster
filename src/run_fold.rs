//! The runs of one local automation as its log folds them: each `{v, at, event, …}` line applied in order to
//! the `Run`s, the seen keys, the last guard error and the last cron check.

use std::collections::HashSet;
use std::path::Path;

use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Map, Value};

const ENDINGS: [&str; 3] = ["timed_out", "closed", "failed"];

#[derive(Clone, Debug, Default)]
pub struct Run {
    pub id: String,
    pub key: Option<String>,
    pub item: Value,
    pub flow: Option<String>,
    pub trigger: Option<String>,
    pub queued_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub session_id: Option<String>,
    pub tmux: Option<String>,
    pub item_slug: Option<String>,
    pub waiting: Option<String>,
    pub finished_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    /// `queued`, `live`, `finished`, `timed_out`, `closed`, `failed` or `refused`; empty for a run known only by id.
    pub status: String,
    pub error: Option<String>,
    pub retried_as: Option<String>,
}

impl Run {
    pub fn queued(&self) -> bool {
        self.status == "queued"
    }

    pub fn live(&self) -> bool {
        self.status == "live"
    }

    /// When the run left the queue, else when it was queued: the order `recent` keeps.
    fn moment(&self) -> DateTime<Utc> {
        self.started_at.or(self.ended_at).unwrap_or(self.queued_at)
    }
}

fn epoch() -> DateTime<Utc> {
    Utc.timestamp_opt(0, 0).unwrap()
}

fn time(value: Option<&Value>) -> DateTime<Utc> {
    value.and_then(Value::as_str).and_then(|s| DateTime::parse_from_rfc3339(s).ok()).map_or_else(epoch, |t| t.with_timezone(&Utc))
}

fn string(event: &Map<String, Value>, key: &str) -> Option<String> {
    event.get(key).and_then(Value::as_str).map(String::from)
}

/// What the log says, folded.
#[derive(Default)]
pub struct Fold {
    pub(crate) runs: Vec<Run>,
    pub(crate) seen: HashSet<String>,
    pub(crate) guard_error: Option<Value>,
    pub(crate) checked: Option<DateTime<Utc>>,
}

impl Fold {
    pub(crate) fn read(path: &Path) -> Fold {
        let mut fold = Fold::default();
        let Ok(text) = std::fs::read_to_string(path) else { return fold };
        for line in text.lines() {
            if let Ok(Value::Object(event)) = serde_json::from_str::<Value>(line) {
                fold.apply(&event);
            }
        }
        fold
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.runs.iter().position(|r| r.id == id)
    }

    fn apply(&mut self, event: &Map<String, Value>) {
        let at = time(event.get("at"));
        match event.get("event").and_then(Value::as_str) {
            Some("queued") => {
                let key = string(event, "key");
                self.seen.extend(key.clone());
                let run = Run { id: string(event, "run_id").unwrap_or_default(), key, item: event.get("item").cloned().unwrap_or(Value::Null), flow: string(event, "flow"), trigger: string(event, "trigger"), queued_at: at, status: "queued".into(), ..Run::default() };
                match self.index(&run.id) {
                    Some(i) => self.runs[i] = run,
                    None => self.runs.push(run),
                }
            }
            Some("refused") => self.apply_refused(event, at),
            Some("seen") => self.seen.extend(event.get("keys").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(String::from)),
            Some("guard_error") => self.guard_error = Some(Value::Object(event.clone())),
            Some("guard_ran") => self.guard_error = None,
            Some("checked") => self.checked = Some(at),
            Some(name) => {
                let Some(i) = string(event, "run_id").and_then(|id| self.index(&id)) else { return };
                apply_to_run(&mut self.runs[i], name, event, at);
            }
            None => {}
        }
    }

    /// A refused guard item becomes a run that never queued; a refused queued run ends.
    fn apply_refused(&mut self, event: &Map<String, Value>, at: DateTime<Utc>) {
        let id = string(event, "run_id").unwrap_or_default();
        let i = match self.index(&id) {
            Some(i) => i,
            None => {
                let Some(key) = string(event, "key") else { return };
                self.seen.insert(key.clone());
                self.runs.push(Run { id, key: Some(key), item: event.get("item").cloned().unwrap_or(Value::Null), flow: string(event, "flow"), trigger: string(event, "trigger"), queued_at: at, ..Run::default() });
                self.runs.len() - 1
            }
        };
        let run = &mut self.runs[i];
        run.status = "refused".into();
        run.ended_at = Some(at);
        run.error = string(event, "reason");
    }

    /// Oldest first; runs queued at the same second keep their log order.
    pub fn queue(&self) -> Vec<Run> {
        let mut queued: Vec<&Run> = self.runs.iter().filter(|r| r.queued()).collect();
        queued.sort_by_key(|r| r.queued_at);
        queued.into_iter().cloned().collect()
    }

    pub fn live(&self) -> Vec<Run> {
        self.runs.iter().filter(|r| r.live()).cloned().collect()
    }

    /// Runs that left the queue, newest first.
    pub fn recent(&self, limit: usize) -> Vec<Run> {
        let mut left: Vec<&Run> = self.runs.iter().filter(|r| !r.queued()).collect();
        left.sort_by_key(|r| r.moment());
        left.into_iter().rev().take(limit).cloned().collect()
    }

    pub fn run(&self, id: &str) -> Option<&Run> {
        self.runs.iter().find(|r| r.id == id)
    }

    pub fn runs(&self) -> &[Run] {
        &self.runs
    }

    pub fn seen_keys(&self) -> &HashSet<String> {
        &self.seen
    }

    pub fn cron_queued(&self) -> bool {
        self.queue().iter().any(|r| r.trigger.as_deref() == Some("cron"))
    }

    /// The latest `guard_error` event (its fields) since the last clean guard run.
    pub fn last_guard_error(&self) -> Option<&Value> {
        self.guard_error.as_ref()
    }

    pub fn last_cron_check(&self) -> Option<DateTime<Utc>> {
        self.checked
    }
}

fn apply_to_run(run: &mut Run, name: &str, event: &Map<String, Value>, at: DateTime<Utc>) {
    match name {
        "started" => {
            run.status = "live".into();
            run.started_at = Some(at);
            run.session_id = string(event, "session_id");
            run.tmux = string(event, "tmux");
            run.item_slug = string(event, "item_slug");
        }
        "waiting" => run.waiting = string(event, "reason"),
        "finished" => {
            run.status = "finished".into();
            run.finished_at = Some(at);
        }
        n if ENDINGS.contains(&n) => {
            run.status = n.to_string();
            run.ended_at = Some(at);
            run.error = string(event, "error");
        }
        "retried" => run.retried_as = string(event, "new_run_id"),
        _ => {}
    }
}
