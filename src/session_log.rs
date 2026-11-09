use std::collections::{HashMap, HashSet};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::sync::OnceLock;

use serde_json::{Map, Value};

use crate::clock;
use crate::data_root;
use crate::error::Res;
use crate::transcripts;
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
#[derive(Clone)]
pub struct Session {
    pub id: String,
    start: Event,
    last: Event,
    pub live: bool,
    pub captured: bool,
}

impl Session {
    /// A session an item lists but the log never captured: identity only.
    pub fn uncaptured(id: &str) -> Session {
        Session { id: id.to_string(), start: Map::new(), last: Map::new(), live: false, captured: false }
    }

    /// The last event's timestamp, None when there is none.
    pub fn last_ts_opt(&self) -> Option<String> {
        text(self.last.get("ts"))
    }

    pub fn started_ts_opt(&self) -> Option<String> {
        text(self.start.get("ts"))
    }
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
    /// The claude process the SessionStart hook found.
    pub fn pid(&self) -> Option<i64> {
        self.start.get("pid").and_then(Value::as_i64)
    }
    pub fn project(&self) -> Option<String> {
        text(self.start.get("project"))
    }
    pub fn end_reason(&self) -> Option<String> {
        if self.ended() { text(self.last.get("reason")) } else { None }
    }
    pub fn commits(&self) -> Vec<String> {
        match (self.ended(), self.last.get("commits")) {
            (true, Some(Value::Array(c))) => c.iter().map(|v| text(Some(v)).unwrap_or_default()).collect(),
            _ => vec![],
        }
    }
    pub fn transcript(&self) -> Option<std::path::PathBuf> {
        transcripts::locate(Some(&self.id), self.start.get("transcript_path").and_then(Value::as_str))
    }
    /// live (running: never resume, it would fork), resumable (transcript still exists) or expired.
    pub fn tier(&self) -> &'static str {
        if !self.captured {
            "uncaptured"
        } else if self.live {
            "live"
        } else if self.transcript().is_some() {
            "resumable"
        } else {
            "expired"
        }
    }
    pub fn first_prompt(&self) -> Option<String> {
        transcripts::first_prompt(self.transcript().as_deref())
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

struct Grouped {
    sessions: Vec<Session>,
    index: HashMap<String, usize>,
}

/// The log as read once; it is never appended to in place, so what it derives is never stale.
pub struct SessionLog {
    events: Vec<Event>,
    grouped: OnceLock<Grouped>,
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
        let events = crate::jsonl_lines::read(&Self::path())
            .iter()
            .filter_map(|l| match serde_json::from_str::<Value>(l) {
                Ok(Value::Object(m)) => Some(m),
                _ => None,
            })
            .collect();
        SessionLog { events, grouped: OnceLock::new() }
    }

    /// The `ts` of the newest event other than a dismissal: the last time capture saw anything.
    pub fn last_activity_ts(&self) -> Option<String> {
        self.events.iter().rev().find(|e| e.get("event").and_then(Value::as_str) != Some("dismissed")).and_then(|e| e.get("ts")).and_then(Value::as_str).map(String::from)
    }

    pub fn last_start_for(&self, session_id: Option<&str>) -> Option<&Event> {
        self.events.iter().rev().find(|e| {
            e.get("event").and_then(Value::as_str) == Some("start") && e.get("session_id").and_then(Value::as_str) == session_id
        })
    }

    /// Every captured session in the order its id first appears; built in one pass over the events and
    /// kept for the life of this value, which never changes after `read`.
    fn grouped(&self) -> &Grouped {
        self.grouped.get_or_init(|| {
            // per id, in first-seen order: the newest start event and the newest event that is not a dismissal
            let mut slots: Vec<(&str, Option<&Event>, Option<&Event>)> = vec![];
            let mut at: HashMap<&str, usize> = HashMap::new();
            for e in &self.events {
                let Some(id) = e.get("session_id").and_then(Value::as_str) else { continue };
                let slot = *at.entry(id).or_insert_with(|| {
                    slots.push((id, None, None));
                    slots.len() - 1
                });
                match e.get("event").and_then(Value::as_str) {
                    Some("dismissed") => {}
                    Some("start") => {
                        slots[slot].1 = Some(e);
                        slots[slot].2 = Some(e);
                    }
                    _ => slots[slot].2 = Some(e),
                }
            }
            let mut sessions = vec![];
            let mut index = HashMap::new();
            for (id, start, last) in slots {
                let (Some(start), Some(last)) = (start, last) else { continue };
                let live = last.get("event").and_then(Value::as_str) == Some("start") && alive(start.get("pid"));
                index.insert(id.to_string(), sessions.len());
                sessions.push(Session { id: id.to_string(), start: start.clone(), last: last.clone(), live, captured: true });
            }
            Grouped { sessions, index }
        })
    }

    pub fn sessions(&self) -> Vec<Session> {
        self.grouped().sessions.clone()
    }

    pub fn session_for(&self, session_id: &str) -> Option<Session> {
        let g = self.grouped();
        g.index.get(session_id).map(|&i| g.sessions[i].clone())
    }

    /// An item's sessions, newest captured first, uncaptured last — the order plain resume would pick.
    pub fn item_sessions(&self, item: &WorkItem) -> Res<Vec<Session>> {
        let mut out: Vec<(Session, Option<f64>)> = vec![];
        for id in item.session_ids() {
            let session = self.session_for(&id).unwrap_or_else(|| Session::uncaptured(&id));
            let when = match session.last_ts_opt() {
                Some(ts) => Some(-(crate::clock::parse(&ts).ok_or_else(|| crate::error::QmError::argument(format!("no time information in {ts:?}")))?.timestamp_millis() as f64 / 1000.0)),
                None => None,
            };
            out.push((session, when));
        }
        out.sort_by(|a, b| match (a.1, b.1) {
            (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        });
        Ok(out.into_iter().map(|(s, _)| s).collect())
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
        let claimed: HashSet<String> = WorkItem::all()?.iter().flat_map(|i| i.session_ids()).collect();
        let dismissed: HashSet<&str> = self
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
