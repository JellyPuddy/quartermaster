//! What each tick does with a local automation's started runs, paused or not: a run whose session's turn
//! ended (your_turn) is `finished`; a finished `--run-` chat left idle for CLOSE_AFTER is killed (`closed`); an
//! untouched run still busy past its `timeout_minutes` is `timed_out` — its `--run-` chat killed (a pr-review
//! run's Review chat is left open), a history note on the automation's item and a macOS notification. A run
//! whose chat is gone — its session ended, or no session and no tmux past START_GRACE — is `failed`. A run the
//! user typed into (a second prompt) is theirs while its session lives: never closed or stopped.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};

use crate::automation_store::{local_settings, Entry};
use crate::chat_attention::ChatAttention;
use crate::chat_flow::SEPARATOR;
use crate::run_fold::Run;
use crate::run_log::RunLog;
use crate::session_log::{Session, SessionLog};
use crate::tmux::Tmux;
use crate::work_item::WorkItem;
use crate::{data_root, event_log, turn_notifier};

const CLOSE_AFTER: f64 = 3600.0;
const START_GRACE: f64 = 300.0;
/// A live run's session in these states holds a slot; "none" is a run whose first prompt the hooks haven't
/// reported yet.
const BUSY: [&str; 3] = ["working", "waiting", "none"];

/// The run ids a lifecycle pass ended, by outcome.
#[derive(Default, Debug)]
pub struct Outcomes {
    pub finished: Vec<String>,
    pub closed: Vec<String>,
    pub timed_out: Vec<String>,
    pub failed: Vec<String>,
}

pub struct RunLifecycle {
    dir: PathBuf,
    tmux: Tmux,
    sessions: Vec<Session>,
    turns: Map<String, Value>,
    attention: ChatAttention,
}

fn seconds(at: DateTime<Utc>) -> f64 {
    at.timestamp() as f64 + f64::from(at.timestamp_subsec_millis()) / 1000.0
}

impl RunLifecycle {
    pub fn new(dir: &Path) -> RunLifecycle {
        RunLifecycle { dir: dir.to_path_buf(), tmux: Tmux::new(), sessions: SessionLog::read().sessions(), turns: event_log::turns(), attention: ChatAttention::new() }
    }

    /// Checks every started run of one automation.
    pub fn call(&mut self, entry: &Entry, now: DateTime<Utc>) -> crate::error::Res<Outcomes> {
        let mut done = Outcomes::default();
        let log = RunLog::new(&entry.slug, &self.dir)?;
        for run in log.runs() {
            let (outcome, list) = match run.status.as_str() {
                "live" => match self.live(entry, &log, &run, now)? {
                    Some(o) => o,
                    None => continue,
                },
                "finished" => match self.idle(&log, &run, now)? {
                    Some(o) => o,
                    None => continue,
                },
                _ => continue,
            };
            let ids = match outcome {
                "finished" => &mut done.finished,
                "closed" => &mut done.closed,
                "timed_out" => &mut done.timed_out,
                _ => &mut done.failed,
            };
            ids.push(list);
        }
        Ok(done)
    }

    /// A live run holds a slot while its session works, waits on background work or hasn't reported its first
    /// prompt; before the session's SessionStart hook ran, while its tmux session lives.
    pub fn busy(&mut self, run: &Run) -> bool {
        let Some(session) = self.session(run) else { return self.tmux.live(run.tmux.as_deref().unwrap_or("")) };
        session.live && BUSY.contains(&self.attention.turn_for(&session).state.as_str())
    }

    fn live(&mut self, entry: &Entry, log: &RunLog, run: &Run, now: DateTime<Utc>) -> crate::error::Res<Option<(&'static str, String)>> {
        let session = self.session(run);
        if session.as_ref().is_some_and(|s| self.attention.turn_for(s).state == "your_turn") {
            log.finished(&run.id, now)?;
            return Ok(Some(("finished", run.id.clone())));
        }
        if let Some(why) = self.chat_gone(run, session.as_ref(), now) {
            log.failed(&run.id, why, now)?;
            return Ok(Some(("failed", run.id.clone())));
        }
        if self.typed_into(run) || !self.busy(run) {
            return Ok(None);
        }
        let minutes = local_settings(&entry.record).get("timeout_minutes").and_then(Value::as_i64).unwrap_or(30);
        let Some(started) = run.started_at else { return Ok(None) };
        if seconds(now) - seconds(started) < (minutes * 60) as f64 {
            return Ok(None);
        }
        self.stop(entry, log, run, minutes, now)?;
        Ok(Some(("timed_out", run.id.clone())))
    }

    fn chat_gone(&self, run: &Run, session: Option<&Session>, now: DateTime<Utc>) -> Option<&'static str> {
        if let Some(session) = session {
            return (!session.live).then_some("session ended before the run finished");
        }
        let started = run.started_at?;
        if self.tmux.live(run.tmux.as_deref().unwrap_or("")) || seconds(now) - seconds(started) <= START_GRACE {
            return None;
        }
        Some("its chat ended before the session started")
    }

    fn idle(&mut self, log: &RunLog, run: &Run, now: DateTime<Utc>) -> crate::error::Res<Option<(&'static str, String)>> {
        let tmux_name = run.tmux.clone().unwrap_or_default();
        if !(own_chat(run) && !self.typed_into(run) && self.tmux.live(&tmux_name)) {
            return Ok(None);
        }
        let Some(session) = self.session(run) else { return Ok(None) };
        let turn = self.attention.turn_for(&session);
        let idle_since = turn.since.filter(|_| turn.state == "your_turn");
        if idle_since.is_none_or(|since| seconds(now) - since < CLOSE_AFTER) {
            return Ok(None);
        }
        self.tmux.kill(&tmux_name);
        log.closed(&run.id, now)?;
        Ok(Some(("closed", run.id.clone())))
    }

    fn stop(&self, entry: &Entry, log: &RunLog, run: &Run, minutes: i64, now: DateTime<Utc>) -> crate::error::Res<()> {
        if own_chat(run) {
            self.tmux.kill(run.tmux.as_deref().unwrap_or(""));
        }
        log.timed_out(&run.id, now)?;
        let what = format!("{} timed out after {minutes} min", run.id);
        let text = if own_chat(run) { format!("run {what}") } else { format!("run {what} (its Review chat stays open)") };
        match WorkItem::find(&entry.slug).and_then(|mut item| item.add_note(&text, "history")) {
            Ok(()) => {}
            Err(e) => data_root::log_error(&format!("automation-timeout {}", entry.slug), e.class, &e.message),
        }
        let click = if own_chat(run) { None } else { Some(vec!["open-chat".to_string(), run.tmux.clone().unwrap_or_default()]) };
        let title = entry.record.get("name").and_then(Value::as_str).unwrap_or(&entry.slug);
        turn_notifier::announce(title, &format!("Run {what}"), &format!("qm-automation-{}", entry.slug), click, false);
        Ok(())
    }

    /// Any prompt after the first (the run's own) means the user took it over.
    fn typed_into(&self, run: &Run) -> bool {
        run.session_id.as_ref().and_then(|id| self.turns.get(id)).and_then(|t| t.get("prompts")).and_then(Value::as_i64).unwrap_or(0) > 1
    }

    fn session(&self, run: &Run) -> Option<Session> {
        let id = run.session_id.as_ref()?;
        self.sessions.iter().find(|s| s.id == *id).cloned()
    }
}

/// Only the `--run-` chat a chat flow opened is ever killed by qm.
fn own_chat(run: &Run) -> bool {
    run.tmux.as_deref().unwrap_or("").contains(SEPARATOR)
}
