use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::io::AsRawFd;

use serde_json::{Map, Value};

use crate::clock;
use crate::data_root;
use crate::error::Res;
use crate::work_item::WorkItem;

pub const EVENT_VERSION: i64 = 1;

pub type Event = Map<String, Value>;

fn truthy(v: Option<&Value>) -> Option<&Value> {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => None,
        some => some,
    }
}

fn text(v: Option<&Value>) -> Option<String> {
    truthy(v).map(|v| match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    })
}

/// One captured session, built from its log events — the only reader of the event schema.
pub struct Session {
    pub id: String,
    start: Event,
    last: Event,
    pub live: bool,
}

impl Session {
    pub fn started_ts(&self) -> String {
        text(self.start.get("ts")).unwrap_or_default()
    }
    pub fn last_ts(&self) -> String {
        text(self.last.get("ts")).unwrap_or_default()
    }
    pub fn cwd(&self) -> Option<String> {
        text(self.start.get("cwd"))
    }
    pub fn branch(&self) -> Option<String> {
        text(self.start.get("branch"))
    }
    pub fn launched_for(&self) -> Option<String> {
        text(self.start.get("work_item"))
    }
    pub fn aside_for(&self) -> Option<String> {
        text(self.start.get("aside"))
    }
    pub fn loose_id(&self) -> Option<String> {
        text(self.start.get("loose"))
    }
    pub fn item_label(&self) -> Option<String> {
        self.launched_for()
            .or_else(|| self.aside_for().map(|a| format!("aside:{a}")))
            .or_else(|| self.loose_id().map(|l| format!("loose:{l}")))
    }
    pub fn ended(&self) -> bool {
        self.last.get("event").and_then(Value::as_str) == Some("end")
    }
    pub fn duration_s(&self) -> Option<i64> {
        if self.ended() { self.last.get("duration_s").and_then(Value::as_i64) } else { None }
    }
}

fn alive(pid: Option<&Value>) -> bool {
    let Some(pid) = pid.and_then(Value::as_i64) else { return false };
    // SAFETY: kill with signal 0 only probes for the process.
    let rc = unsafe { libc::kill(pid as i32, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

pub struct SessionLog {
    events: Vec<Event>,
}

impl SessionLog {
    pub fn path() -> std::path::PathBuf {
        data_root::root().join("sessions.jsonl")
    }

    /// Appends one event under an exclusive lock, with the schema version first.
    pub fn append(event: Event) -> Res<()> {
        data_root::ensure_setup()?;
        let mut line = Map::new();
        line.insert("v".into(), Value::from(EVENT_VERSION));
        line.extend(event);
        let mut file = OpenOptions::new().create(true).append(true).open(Self::path())?;
        // SAFETY: the descriptor stays open for the whole call.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        writeln!(file, "{}", Value::Object(line))?;
        Ok(())
    }

    pub fn read() -> SessionLog {
        let text = std::fs::read_to_string(Self::path()).unwrap_or_default();
        let events = text
            .lines()
            .filter_map(|l| match serde_json::from_str::<Value>(l) {
                Ok(Value::Object(m)) => Some(m),
                _ => None,
            })
            .collect();
        SessionLog { events }
    }

    pub fn last_start_for(&self, session_id: Option<&str>) -> Option<&Event> {
        self.events.iter().rev().find(|e| {
            e.get("event").and_then(Value::as_str) == Some("start") && e.get("session_id").and_then(Value::as_str) == session_id
        })
    }

    pub fn sessions(&self) -> Vec<Session> {
        let mut order: Vec<Option<String>> = vec![];
        for e in &self.events {
            let id = e.get("session_id").and_then(Value::as_str).map(String::from);
            if !order.contains(&id) {
                order.push(id);
            }
        }
        order
            .into_iter()
            .filter_map(|id| {
                let mine: Vec<&Event> =
                    self.events.iter().filter(|e| e.get("session_id").and_then(Value::as_str) == id.as_deref()).collect();
                let start = (*mine.iter().rev().find(|e| e.get("event").and_then(Value::as_str) == Some("start"))?).clone();
                let last = (*mine.iter().rev().find(|e| e.get("event").and_then(Value::as_str) != Some("dismissed"))?).clone();
                let live = last.get("event").and_then(Value::as_str) == Some("start") && alive(start.get("pid"));
                Some(Session { id: id?, start, last, live })
            })
            .collect()
    }

    pub fn dismiss(session_id: &str) -> Res<()> {
        let mut e = Event::new();
        e.insert("event".into(), "dismissed".into());
        e.insert("session_id".into(), session_id.into());
        e.insert("ts".into(), clock::now_iso().into());
        Self::append(e)
    }

    /// Captured sessions no work item claims and nobody dismissed; asides and launched sessions never land here.
    pub fn inbox(&self) -> Res<Vec<Session>> {
        let claimed: Vec<String> = WorkItem::all()?.iter().flat_map(|i| i.session_ids()).collect();
        let dismissed: Vec<&str> = self
            .events
            .iter()
            .filter(|e| e.get("event").and_then(Value::as_str) == Some("dismissed"))
            .filter_map(|e| e.get("session_id").and_then(Value::as_str))
            .collect();
        Ok(self
            .sessions()
            .into_iter()
            .filter(|s| {
                s.launched_for().is_none()
                    && s.aside_for().is_none()
                    && !claimed.contains(&s.id)
                    && !dismissed.contains(&s.id.as_str())
            })
            .collect())
    }
}
