use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

use chrono::{DateTime, Duration, FixedOffset};
use serde_json::{json, Value};

use crate::{clock, data_root};

const TAIL_BYTES: u64 = 256 * 1024;
const SHOWN: usize = 20;
const NOT_ERRORS: [&str; 2] = ["transient ", "recovered after "];

/// The errors in qm.log the user hasn't seen yet: header lines (`failure_log`'s format) that are neither
/// transient nor recovered, newer than the time in `errors-seen-at` (absent or unreadable: the last 24 h), each
/// with its continuation lines. Reads only the log's last `tail_bytes`; an unreadable log counts as no errors.
pub struct ErrorLog {
    log: PathBuf,
    seen_file: PathBuf,
    now: DateTime<FixedOffset>,
    tail_bytes: u64,
}

struct Entry {
    at: String,
    context: String,
    time: DateTime<FixedOffset>,
    lines: Vec<String>,
}

impl ErrorLog {
    pub fn new() -> Self {
        let root = data_root::root();
        ErrorLog { log: root.join("qm.log"), seen_file: root.join("errors-seen-at"), now: chrono::Local::now().fixed_offset(), tail_bytes: TAIL_BYTES }
    }

    pub fn at(mut self, now: DateTime<FixedOffset>) -> Self {
        self.now = now;
        self
    }

    pub fn with_tail_bytes(mut self, bytes: u64) -> Self {
        self.tail_bytes = bytes;
        self
    }

    pub fn since(&self) -> DateTime<FixedOffset> {
        std::fs::read_to_string(&self.seen_file).ok().and_then(|t| clock::parse(t.trim())).unwrap_or(self.now - Duration::hours(24))
    }

    fn entries(&self) -> Vec<Entry> {
        let since = self.since();
        parse(&self.tail()).into_iter().filter(|e| e.time > since).collect()
    }

    pub fn count(&self) -> usize {
        self.entries().len()
    }

    /// The status line's count: a log not modified since the marker is not read at all.
    pub fn count_if_modified(&self) -> usize {
        let modified = std::fs::metadata(&self.log).and_then(|m| m.modified()).ok().map(|t| DateTime::<chrono::Utc>::from(t).fixed_offset());
        match modified {
            Some(t) if t > self.since() => self.count(),
            _ => 0,
        }
    }

    /// The GUI's badge: the count and the newest `SHOWN` entries, newest first.
    pub fn summary(&self) -> Value {
        let entries = self.entries();
        let shown: Vec<Value> = entries.iter().rev().take(SHOWN).map(|e| json!({"at": e.at, "context": e.context, "lines": e.lines})).collect();
        json!({"count": entries.len(), "entries": shown})
    }

    pub fn mark_seen(&self) -> std::io::Result<()> {
        data_root::ensure_setup()?;
        std::fs::write(&self.seen_file, format!("{}\n", self.now.to_rfc3339_opts(chrono::SecondsFormat::Secs, false)))
    }

    fn tail(&self) -> String {
        let read = || -> std::io::Result<String> {
            let mut file = std::fs::File::open(&self.log)?;
            let start = file.metadata()?.len().saturating_sub(self.tail_bytes);
            file.seek(SeekFrom::Start(start))?;
            let mut bytes = vec![];
            file.read_to_end(&mut bytes)?;
            let text = String::from_utf8_lossy(&bytes).into_owned();
            Ok(if start == 0 { text } else { text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap_or_default() })
        };
        read().unwrap_or_default()
    }
}

impl Default for ErrorLog {
    fn default() -> Self {
        Self::new()
    }
}

/// A continuation belongs to the header above it; one with no error header above it (a skipped header, or the
/// tail's cut start) is dropped.
fn parse(text: &str) -> Vec<Entry> {
    let mut found: Vec<Entry> = vec![];
    let mut open = false;
    for line in text.lines() {
        if line.starts_with(char::is_whitespace) {
            if open {
                found.last_mut().expect("an open entry exists").lines.push(line.to_string());
            }
        } else if line.is_empty() {
            open = false;
        } else if let Some(entry) = error_entry(line) {
            found.push(entry);
            open = true;
        } else {
            open = false;
        }
    }
    found
}

fn error_entry(line: &str) -> Option<Entry> {
    let (at, rest) = line.split_once(' ')?;
    let rest = rest.strip_prefix('[')?;
    let (context, message) = rest.split_once("] ")?;
    if context.contains(']') || at.is_empty() || NOT_ERRORS.iter().any(|p| message.starts_with(p)) {
        return None;
    }
    Some(Entry { at: at.to_string(), context: context.to_string(), time: clock::parse(at)?, lines: vec![line.to_string()] })
}

/// The header badge's Mark seen: now goes into `errors-seen-at`, and the reply carries the cleared badge.
pub fn mark_seen_reply() -> Result<Value, String> {
    let log = ErrorLog::new();
    log.mark_seen().map_err(|e| e.to_string())?;
    Ok(json!({"ok": true, "errors": log.summary()}))
}
