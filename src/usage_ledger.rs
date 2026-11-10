//! Token totals per session — its transcript plus its sub-agent transcripts — kept permanently in
//! `usage-cache.json`. Claude Code prunes transcripts after a few weeks; the ledger is what still
//! knows what an expired session spent. It is a record, not a cache: nothing here prunes or rebuilds it.

use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use crate::data_root;
use crate::error::QmError;
use crate::session_log::Session;
use crate::transcript_usage::{self as tu, Buckets, SYSTEM_CALL_ERROR};

/// The class qm.log names for a ledger file that isn't one.
const CORRUPT_LEDGER: &str = "Quartermaster::UsageLedger::CorruptLedger";

pub struct SessionUsage {
    pub buckets: Buckets,
    pub agents: i64,
    pub known: bool,
}

pub struct UsageLedger {
    path: PathBuf,
    sessions: Option<Map<String, Value>>,
    dirty: bool,
}

/// The `sessions` of ledger text; None when it doesn't parse or isn't shaped `{sessions: {...}}`.
fn parse(content: &[u8]) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(content).ok()? {
        Value::Object(mut m) => match m.remove("sessions")? {
            Value::Object(sessions) => Some(sessions),
            _ => None,
        },
        _ => None,
    }
}

/// The `sessions` of the ledger file; a missing, unreadable or malformed file reads as empty. Only a save,
/// under its lock, decides what to do with one that isn't a ledger.
fn read_sessions(path: &Path) -> Map<String, Value> {
    std::fs::read(path).ok().and_then(|text| parse(&text)).unwrap_or_default()
}

/// `<transcript dir>/<session id>/subagents/**/*.jsonl`, sorted; hidden entries and symlinked
/// directories are skipped, as `Dir.glob` does.
fn subagent_transcripts(transcript: &Path, session_id: &str) -> Vec<PathBuf> {
    let mut found = vec![];
    let root = transcript.parent().unwrap_or(Path::new("")).join(session_id).join("subagents");
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for e in entries.filter_map(|e| e.ok()) {
            if e.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let path = e.path();
            let is_real_dir = std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir());
            if is_real_dir {
                stack.push(path);
            } else if path.extension().is_some_and(|x| x == "jsonl") && path.is_file() {
                found.push(path);
            }
        }
    }
    found.sort_by_key(|p| p.to_string_lossy().into_owned());
    found
}

impl UsageLedger {
    pub fn new() -> UsageLedger {
        UsageLedger { path: data_root::root().join("usage-cache.json"), sessions: None, dirty: false }
    }

    fn sessions(&mut self) -> &mut Map<String, Value> {
        let path = &self.path;
        self.sessions.get_or_insert_with(|| read_sessions(path))
    }

    /// The session's totals; known is false only for an expired session nobody tallied.
    pub fn session_usage(&mut self, session: &Session) -> Result<SessionUsage, QmError> {
        let entry = self.sessions().get(&session.id).cloned();
        let entry = match session.transcript() {
            Some(transcript) => self.refresh(&session.id, &transcript, entry)?,
            None => entry,
        };
        let Some(entry) = entry else { return Ok(SessionUsage { buckets: Map::new(), agents: 0, known: session.live }) };
        let files = entry.get("files").and_then(Value::as_object).ok_or_else(|| QmError::new("NoMethodError", "undefined method 'values'"))?;
        let mut buckets = Map::new();
        for state in files.values() {
            let state = state.as_object().ok_or_else(|| QmError::new("TypeError", "file state is not a hash"))?;
            tu::merge(&mut buckets, &tu::totals(state)?)?;
        }
        Ok(SessionUsage { buckets, agents: files.len() as i64 - 1, known: true })
    }

    fn refresh(&mut self, session_id: &str, transcript: &Path, entry: Option<Value>) -> Result<Option<Value>, QmError> {
        let Ok(meta) = std::fs::metadata(transcript) else { return Ok(entry) };
        let signature = json!([transcript.to_string_lossy(), meta.len() as i64, tu::mtime_f64(&meta)?]);
        if let Some(e) = &entry {
            if e.get("main") == Some(&signature) {
                return Ok(entry);
            }
        }
        let mut files = entry.as_ref().and_then(|e| e.get("files")).and_then(Value::as_object).cloned().unwrap_or_default();
        let mut paths = vec![transcript.to_path_buf()];
        paths.extend(subagent_transcripts(transcript, session_id));
        for path in paths {
            let key = path.to_string_lossy().into_owned();
            let state = files.get(&key).and_then(Value::as_object);
            match tu::scan(&path, state) {
                Ok(next) => {
                    files.insert(key, Value::Object(next));
                }
                Err(e) if e.class == SYSTEM_CALL_ERROR => continue, // vanished between the glob and the read
                Err(e) => return Err(e),
            }
        }
        self.dirty = true;
        let fresh = json!({ "main": signature, "files": Value::Object(files) });
        self.sessions().insert(session_id.to_string(), fresh.clone());
        Ok(Some(fresh))
    }

    /// Writes the ledger when a lookup changed it: atomic, and merged over what another qm process saved
    /// meanwhile (its sessions aren't dropped). The read-merge-write holds a flock, so a second saver merges
    /// over the first's ledger. A file there that isn't a ledger is never overwritten: it moves aside to
    /// `<file>.corrupt-<UTC time>` first, and qm.log says so.
    pub fn save(&mut self) {
        if !self.dirty {
            return;
        }
        let ours = self.sessions().clone();
        match self.write_merged(ours) {
            Ok(()) => self.dirty = false,
            Err((class, message)) => data_root::log_error("usage-ledger", class, &message),
        }
    }

    fn write_merged(&self, ours: Map<String, Value>) -> Result<(), (&'static str, String)> {
        use std::os::unix::io::AsRawFd;
        let io = |e: std::io::Error| ("IOError", e.to_string());
        let dir = self.path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(dir).map_err(io)?;
        let name = self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let lock = std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join(format!(".{name}.lock"))).map_err(io)?;
        // SAFETY: the descriptor stays open until `lock` drops at the end of this function.
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        let mut merged = self.ledger_on_disk()?;
        merged.extend(ours);
        let payload = json!({ "v": 1, "sessions": Value::Object(merged) });
        crate::atomic_file::write(&self.path, &payload.to_string()).map_err(io)
    }

    /// The sessions saved on disk; a file that can't be read is an error (nothing is saved), one that reads but
    /// isn't a ledger is set aside.
    fn ledger_on_disk(&self) -> Result<Map<String, Value>, (&'static str, String)> {
        let content = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
            Err(e) => return Err(("SystemCallError", e.to_string())),
        };
        if let Some(sessions) = parse(&content) {
            return Ok(sessions);
        }
        self.set_aside_corrupt()?;
        Ok(Map::new())
    }

    fn set_aside_corrupt(&self) -> Result<(), (&'static str, String)> {
        let mut aside = PathBuf::from(format!("{}.corrupt-{}", self.path.display(), chrono::Utc::now().format("%Y%m%dT%H%M%SZ")));
        if aside.exists() {
            aside = PathBuf::from(format!("{}-{}", aside.display(), std::process::id()));
        }
        std::fs::rename(&self.path, &aside).map_err(|e| ("IOError", e.to_string()))?;
        data_root::log_error("usage-ledger", CORRUPT_LEDGER, &format!("{} is not a ledger; kept as {}", self.path.display(), aside.display()));
        Ok(())
    }
}

impl Default for UsageLedger {
    fn default() -> Self {
        Self::new()
    }
}
