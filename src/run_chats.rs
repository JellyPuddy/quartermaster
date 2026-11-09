//! The live `<slug>--run-<id>` chats of local automation runs among the tmux session names, shaped as the
//! chats list's loose rows with a `run` field: titled by the automation's name and the run's subject, with
//! whose move it is from the session qm gave the run; a `notify: quiet` automation's runs say `quiet`, so the
//! page leaves them out of its whose-move count. `by_session` is the other way in: every chat-flow run that
//! has a session, by that session id.

use std::path::Path;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};

use crate::automation_store::{valid_slug, AutomationStore, Entry};
use crate::chat_attention::ChatAttention;
use crate::chat_flow::SEPARATOR;
use crate::run_fold::Run;
use crate::run_log::RunLog;
use crate::session_log::SessionLog;

/// A chat-flow run as attention and notifications name it: its session, its own tmux, its automation and run,
/// and "<automation name> · <subject>".
#[derive(Clone, Debug)]
pub struct Chat {
    pub session_id: String,
    pub tmux: String,
    pub slug: String,
    pub run_id: String,
    pub title: String,
    pub quiet: bool,
}

/// Every chat-flow run that has a session, by that session id (from the run logs, whatever the run's status: a
/// finished run's chat stays open).
pub fn by_session(dir: &Path) -> Vec<(String, Chat)> {
    let found = (|| -> crate::error::Res<Vec<(String, Chat)>> {
        let mut out: Vec<(String, Chat)> = vec![];
        for entry in AutomationStore::new(dir).list()?.into_iter().filter(|e| e.record.get("runner").and_then(Value::as_str) == Some("local")) {
            for run in RunLog::new(&entry.slug, dir)?.runs() {
                let (Some(session), Some(tmux)) = (run.session_id.clone(), run.tmux.clone()) else { continue };
                if !tmux.contains(SEPARATOR) {
                    continue;
                }
                let chat = Chat { session_id: session.clone(), tmux, slug: entry.slug.clone(), run_id: run.id.clone(), title: title(&entry, &run), quiet: entry.record.get("notify").and_then(Value::as_str) == Some("quiet") };
                match out.iter_mut().find(|(id, _)| *id == session) {
                    Some(existing) => existing.1 = chat,
                    None => out.push((session, chat)),
                }
            }
        }
        Ok(out)
    })();
    found.unwrap_or_else(|e| {
        crate::data_root::log_error("run-chats", e.class, &e.message);
        vec![]
    })
}

/// "<automation name> · <subject>": the subject the run's item names (its title, else its key), else the run.
pub fn title(entry: &Entry, run: &Run) -> String {
    let subject = run.item.as_object().and_then(|item| item.get("title").filter(|t| !t.is_null()).or_else(|| item.get("key")).map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string())));
    let name = entry.record.get("name").and_then(Value::as_str).unwrap_or(&entry.slug);
    format!("{name} · {}", subject.unwrap_or_else(|| format!("run {}", run.id)))
}

/// The rows for the tmux session names that are run chats of a known automation.
pub fn chats(panes: &[String], dir: &Path, attention: &mut ChatAttention) -> Vec<Value> {
    let store = AutomationStore::new(dir);
    let log = SessionLog::read();
    let mut rows = vec![];
    for name in panes {
        let Some((slug, id)) = name.split_once(SEPARATOR) else { continue };
        if !valid_slug(slug) {
            continue;
        }
        let Ok(Some(entry)) = store.read(slug) else { continue };
        let Ok(runs) = RunLog::new(slug, dir) else { continue };
        let run = runs.run(id);
        let session = run.as_ref().and_then(|r| r.session_id.as_deref()).and_then(|s| log.session_for(s));
        let turn = session.as_ref().map(|s| attention.turn_for(s));
        let state = turn.as_ref().map_or("none".to_string(), |t| t.state.clone());
        let since = turn.as_ref().and_then(|t| t.since).and_then(|s| DateTime::<Utc>::from_timestamp(s as i64, 0)).map(|t| t.to_rfc3339_opts(SecondsFormat::Secs, true));
        let shown = run.unwrap_or_else(|| Run { id: id.to_string(), ..Run::default() });
        rows.push(json!({"name": name, "id": name, "run": {"slug": slug, "id": id, "quiet": entry.record.get("notify").and_then(Value::as_str) == Some("quiet")},
            "session": session.as_ref().map(|s| s.id.clone()), "title": title(&entry, &shown), "project": session.as_ref().and_then(|s| s.project()),
            "cwd": session.as_ref().and_then(|s| s.cwd()).map(|c| crate::cli_format::short_path(Some(&c))), "state": state, "since": since,
            "tool": turn.as_ref().and_then(|t| t.tool.clone())}));
    }
    rows
}
