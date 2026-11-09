//! The local copy of each automation, the source of truth push sends from: `automations/<slug>.yml` (the
//! routine's settings, `v:` first) and `automations/<slug>.prompt.md` (the prompt, nothing else). A write
//! merges onto the stored keys, so keys qm doesn't know survive, keeps each replaced file as `<file>.bak` and
//! replaces files through `atomic_file`.

use std::fs;
use std::path::{Path, PathBuf};

use regex::Regex;
use serde_json::{json, Map, Value};

use crate::error::{QmError, Res};
use crate::{atomic_file, config_emit, data_root};

pub const VERSION: i64 = 1;
const FIELDS: [&str; 17] = [
    "routine", "runner", "name", "cron", "when", "flow", "repos", "cwd", "model", "sources", "connectors", "allowed_tools", "permission_mode", "environment_id", "enabled", "timeout_minutes",
    "notify",
];
const NOTIFY: [&str; 2] = ["attention", "quiet"];

pub type Record = Map<String, Value>;

#[derive(Debug, Clone)]
pub struct Entry {
    pub slug: String,
    pub record: Record,
    pub prompt: String,
}

pub struct AutomationStore {
    dir: PathBuf,
}

/// A slug the store accepts: `[a-z0-9][a-z0-9-]*`.
pub fn valid_slug(slug: &str) -> bool {
    let mut chars = slug.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c.is_ascii_digit()) && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `automations/` under the data root.
pub fn dir() -> PathBuf {
    data_root::root().join("automations")
}

/// A record's defaults for the fields a local automation leaves unset (null counts as unset).
pub fn local_settings(record: &Record) -> Record {
    let mut out = Record::new();
    out.insert("flow".into(), json!("chat"));
    out.insert("timeout_minutes".into(), json!(30));
    out.insert("notify".into(), json!("attention"));
    for (k, v) in record {
        if !v.is_null() {
            out.insert(k.clone(), v.clone());
        }
    }
    out
}

/// Ruby's `inspect` of a settings value, as the messages quote it.
fn inspect(v: &Value) -> String {
    match v {
        Value::Null => "nil".into(),
        Value::String(s) => crate::ruby_text::inspect_ascii(s).unwrap_or_else(|| format!("{s:?}")),
        other => other.to_string(),
    }
}

fn strings(v: &Value) -> Option<Vec<&str>> {
    v.as_array()?.iter().map(Value::as_str).collect()
}

/// An error naming every field a local automation can't run with.
pub fn validate_local(record: &Record) -> Res<()> {
    let settings = local_settings(record);
    let mut problems: Vec<String> = vec![];
    let shown = |k: &str| settings.get(k).map(inspect).unwrap_or_else(|| "nil".into());
    if settings.get("permission_mode").and_then(Value::as_str) == Some("bypassPermissions") {
        problems.push("permission_mode bypassPermissions is refused for local automations".into());
    }
    if !settings.get("notify").and_then(Value::as_str).is_some_and(|n| NOTIFY.contains(&n)) {
        problems.push(format!("notify must be attention or quiet, got {}", shown("notify")));
    }
    if !settings.get("flow").and_then(Value::as_str).is_some_and(|f| !f.is_empty()) {
        problems.push(format!("flow must be a flow name, got {}", shown("flow")));
    }
    if !settings.get("timeout_minutes").and_then(Value::as_i64).is_some_and(|t| t > 0) {
        problems.push(format!("timeout_minutes must be a positive whole number, got {}", shown("timeout_minutes")));
    }
    if settings.get("allowed_tools").is_some_and(|t| strings(t).is_none()) {
        problems.push("allowed_tools must be a list of tool names".into());
    }
    let repo = Regex::new(r"^[\w.-]+/[\w.-]+$").unwrap();
    if settings.get("repos").is_some_and(|r| !strings(r).is_some_and(|r| r.iter().all(|s| repo.is_match(s)))) {
        problems.push("repos must be a list of owner/name strings".into());
    }
    if problems.is_empty() { Ok(()) } else { Err(QmError::argument(problems.join("; "))) }
}

fn checked(slug: &str) -> Res<&str> {
    if valid_slug(slug) { Ok(slug) } else { Err(QmError::argument(format!("not an automation slug: {slug:?}"))) }
}

fn replace(path: &Path, content: &str) -> Res<()> {
    if let Ok(old) = fs::read(path) {
        fs::write(format!("{}.bak", path.display()), old)?;
    }
    Ok(atomic_file::write(path, content)?)
}

impl AutomationStore {
    pub fn new(dir: impl Into<PathBuf>) -> AutomationStore {
        AutomationStore { dir: dir.into() }
    }

    /// The store under the live data root.
    pub fn current() -> AutomationStore {
        Self::new(dir())
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn yml_path(&self, slug: &str) -> Res<PathBuf> {
        Ok(self.dir.join(format!("{}.yml", checked(slug)?)))
    }

    pub fn prompt_path(&self, slug: &str) -> Res<PathBuf> {
        Ok(self.dir.join(format!("{}.prompt.md", checked(slug)?)))
    }

    pub fn exists(&self, slug: &str) -> bool {
        self.yml_path(slug).is_ok_and(|p| p.exists())
    }

    pub fn read(&self, slug: &str) -> Res<Option<Entry>> {
        if !self.exists(slug) {
            return Ok(None);
        }
        let prompt = fs::read_to_string(self.prompt_path(slug)?).unwrap_or_default();
        Ok(Some(Entry { slug: slug.to_string(), record: self.load_record(slug)?, prompt }))
    }

    /// Every stored automation, by slug.
    pub fn list(&self) -> Res<Vec<Entry>> {
        let Ok(children) = fs::read_dir(&self.dir) else { return Ok(vec![]) };
        let mut slugs: Vec<String> = children.filter_map(|e| e.ok()).filter_map(|e| e.file_name().to_string_lossy().strip_suffix(".yml").map(String::from)).filter(|s| valid_slug(s)).collect();
        slugs.sort();
        slugs.iter().filter_map(|s| self.read(s).transpose()).collect()
    }

    pub fn find_by_routine(&self, id: &str) -> Res<Option<Entry>> {
        Ok(self.list()?.into_iter().find(|e| e.record.get("routine").and_then(Value::as_str) == Some(id)))
    }

    /// Merges `record` onto the stored keys and writes it with `prompt`; returns the entry as stored.
    pub fn write(&self, slug: &str, record: &Record, prompt: &str) -> Res<Entry> {
        let mut merged = if self.exists(slug) { self.load_record(slug)? } else { Record::new() };
        for (k, v) in record {
            merged.insert(k.clone(), v.clone());
        }
        merged.insert("v".into(), json!(VERSION));
        if merged.get("runner").and_then(Value::as_str) == Some("local") {
            validate_local(&merged)?;
        }
        fs::create_dir_all(&self.dir)?;
        let ordered = ordered(&merged);
        let yaml = serde_yaml::to_value(Value::Object(ordered))?;
        replace(&self.yml_path(slug)?, &format!("---\n{}", config_emit::dump(&yaml)))?;
        replace(&self.prompt_path(slug)?, prompt)?;
        Ok(Entry { slug: slug.to_string(), record: merged, prompt: prompt.to_string() })
    }

    /// Removes the two files and the run log; the `.bak`s stay as the last copy.
    pub fn delete_local(&self, slug: &str) -> Res<()> {
        for path in [self.yml_path(slug)?, self.prompt_path(slug)?, crate::run_log::RunLog::new(slug, &self.dir)?.path()] {
            let _ = fs::remove_file(path);
        }
        Ok(())
    }

    fn load_record(&self, slug: &str) -> Res<Record> {
        let text = fs::read_to_string(self.yml_path(slug)?)?;
        Ok(match serde_yaml::from_str::<Value>(&text) {
            Ok(Value::Object(map)) => map,
            Ok(_) => Record::new(),
            Err(e) => return Err(e.into()),
        })
    }
}

/// `v` first, then the known fields in their order, then every other key as stored.
fn ordered(record: &Record) -> Record {
    let mut out = Record::new();
    for key in std::iter::once("v").chain(FIELDS) {
        if let Some(v) = record.get(key) {
            out.insert(key.to_string(), v.clone());
        }
    }
    for (k, v) in record {
        if !out.contains_key(k) {
            out.insert(k.clone(), v.clone());
        }
    }
    out
}
