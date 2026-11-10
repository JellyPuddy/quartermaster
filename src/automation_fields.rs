//! What push and pull compare and send: the local files and a routine in one field shape, which fields
//! changed, what an update carries and how a history note names a change.

use serde_json::{json, Map, Value};

use crate::automation_store::{Entry, Record};
use crate::error::{QmError, Res};
use crate::local_schedule::LocalSchedule;
use crate::routines_client as rc;

pub(crate) fn record(pairs: Value) -> Record {
    pairs.as_object().cloned().unwrap_or_default()
}

pub const STALE: &str = "Automations::Stale";

/// Local field → how a history note names a change to it.
pub(crate) const CHANGE_LABELS: [(&str, &str); 9] = [
    ("name", "name"), ("cron", "schedule"), ("enabled", "enabled"), ("prompt", "prompt"), ("model", "model"), ("sources", "repos"), ("allowed_tools", "tools"),
    ("environment_id", "environment"), ("connectors", "connectors"),
];
pub(crate) const TOP_FIELDS: [&str; 4] = ["name", "cron", "enabled", "connectors"];
pub(crate) const LIST_FIELDS: [&str; 3] = ["sources", "allowed_tools", "connectors"];

/// An absent value, as a routine and the files both leave one.
pub(crate) fn get(map: &Map<String, Value>, key: &str) -> Value {
    map.get(key).cloned().unwrap_or(Value::Null)
}

pub(crate) fn same(field: &str, local: &Map<String, Value>, remote: &Map<String, Value>) -> bool {
    if LIST_FIELDS.contains(&field) {
        let list = |m: &Map<String, Value>| match get(m, field) {
            Value::Null => json!([]),
            other => other,
        };
        list(local) == list(remote)
    } else {
        get(local, field) == get(remote, field)
    }
}

/// A list field unset on one side and empty on the other is no change.
pub(crate) fn changed_fields(local: &Map<String, Value>, remote: &Map<String, Value>) -> Vec<&'static str> {
    CHANGE_LABELS.iter().map(|(field, _)| *field).filter(|field| !same(field, local, remote)).collect()
}

pub(crate) fn label(field: &str) -> &'static str {
    CHANGE_LABELS.iter().find(|(f, _)| *f == field).map_or("", |(_, label)| label)
}

/// The routine changed since the last sync.
pub fn drift(entry: &Entry, remote: Option<&Value>) -> bool {
    remote.is_some_and(|r| get(r.as_object().unwrap_or(&Map::new()), "updated_at") != get(&entry.record, "remote_updated_at"))
}

pub(crate) fn check_fresh(entry: &Entry, remote: &Value) -> Res<()> {
    if !drift(entry, Some(remote)) {
        return Ok(());
    }
    let slug = &entry.slug;
    let shown = |v: &Value| v.as_str().map(String::from).unwrap_or_else(|| "never".into());
    Err(QmError::new(
        STALE,
        format!(
            "{slug} changed outside qm (claude.ai: {}, last sync: {}): `qm automation pull {slug}` takes the routine, `qm automation push {slug} --force` overwrites it",
            shown(&remote["updated_at"]),
            shown(&get(&entry.record, "remote_updated_at"))
        ),
    ))
}

/// The entry in the client's field shape.
pub(crate) fn fields_of(entry: &Entry) -> Map<String, Value> {
    let mut fields: Map<String, Value> = CHANGE_LABELS.iter().map(|(k, _)| (k.to_string(), get(&entry.record, k))).collect();
    fields.insert("prompt".into(), json!(entry.prompt));
    fields
}

/// Changed top-level fields as they are; any changed job field sends all of them, since the API takes job_config
/// whole. Connectors always go along.
pub(crate) fn update_fields(entry: &Entry, changes: &[&str]) -> Map<String, Value> {
    let fields = fields_of(entry);
    let sends_job = changes.iter().any(|c| rc::JOB_FIELDS.contains(c));
    let keys = changes.iter().copied().filter(|c| TOP_FIELDS.contains(c)).chain(if sends_job { rc::JOB_FIELDS.to_vec() } else { vec![] });
    let mut out: Map<String, Value> = keys.map(|k| (k.to_string(), get(&fields, k))).collect();
    out.extend(connectors_of(entry));
    out
}

/// Every create and update carries the stored connectors (none → `[]`), so a pushed routine has exactly those
/// and never the API's default set.
pub(crate) fn connectors_of(entry: &Entry) -> Map<String, Value> {
    let connectors = match get(&entry.record, "connectors") {
        Value::Null => json!([]),
        other => other,
    };
    record(json!({"connectors": connectors}))
}

pub(crate) fn describe_change(field: &str, entry: &Entry) -> String {
    let record = &entry.record;
    match field {
        "cron" => {
            let cron = record.get("cron").and_then(Value::as_str).unwrap_or("");
            let schedule = LocalSchedule::from_cron(cron, chrono::Utc::now());
            format!("schedule → {}", if schedule.raw() { schedule.label() } else { format!("{} ({cron} UTC)", schedule.label()) })
        }
        "enabled" => (if record.get("enabled") == Some(&json!(false)) { "paused" } else { "resumed" }).to_string(),
        "name" => format!("name → {}", record.get("name").and_then(Value::as_str).unwrap_or("")),
        _ => format!("{} changed", label(field)),
    }
}

pub(crate) fn draft_description(name: Option<&str>, prompt: &str) -> String {
    let paragraph = regex::Regex::new(r"\n\s*\n").unwrap().split(crate::ruby_text::strip(prompt)).next().unwrap_or("").trim().to_string();
    [name.unwrap_or(""), paragraph.as_str()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n")
}
