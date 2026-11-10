//! The Settings view's server side, over `ConfigFile`: `GET /api/settings` is the form's payload, `POST
//! /api/settings/check` validates a draft (the page never validates in JS), `POST /api/settings/save`
//! writes one. A save is refused as stale (409) when config.yml changed since the page loaded it, and with
//! its issues (422) while the draft has errors; a written save answers a fresh state build so the page's
//! buttons follow at once. Off the action mutex: the write is quick and serialised by `ConfigFile`'s
//! flock, and the digest check is what keeps two editors apart.

use serde_json::{json, Map, Value};
use serde_yaml::Value as Yaml;

use crate::config_check::{tidy, ConfigCheck, Issue, MachineProbe};
use crate::config_features::features;
use crate::config_file::{ConfigFile, WriteError};
use crate::config_schema as schema;
use crate::data_root;
use crate::price_defaults::DEFAULTS;
use crate::ruby_num::Num;
use crate::transcript_usage::KINDS;
use crate::work_item::WorkItem;
use crate::yaml_scalar::text;

type Reply = (&'static str, &'static str, Vec<u8>);

fn answer(status: &'static str, body: Value) -> Reply {
    (status, "application/json; charset=utf-8", body.to_string().into_bytes())
}

/// The reply for a /api/settings route, None for any other.
pub fn respond(method: &str, route: &str, body: &[u8], token: &str) -> Option<Reply> {
    let request = || serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
    Some(match (method, route) {
        ("GET", "/api/settings") => answer("200 OK", payload(&ConfigFile::load(&data_root::config_file()))),
        ("POST", "/api/settings/check") => answer("200 OK", check(&request()["config"])),
        ("POST", "/api/settings/save") => {
            let request = request();
            save(&request["config"], request["digest"].as_str().unwrap_or(""), token)
        }
        _ => return None,
    })
}

fn issues_json(issues: &[Issue]) -> Value {
    Value::Array(issues.iter().map(Issue::to_json).collect())
}

fn price_defaults() -> Value {
    let number = |text: &str| match Num::literal(text) {
        Num::Int(i) => json!(i as i64),
        Num::Float(f) => json!(f),
    };
    Value::Object(DEFAULTS.iter().map(|(model, rates)| (model.to_string(), Value::Object(KINDS.iter().zip(rates).map(|(k, r)| (k.to_string(), number(r))).collect()))).collect())
}

fn payload(file: &ConfigFile) -> Value {
    let issues = file.issues();
    let mut items = Map::new();
    for item in WorkItem::all().unwrap_or_default() {
        if let Some(project) = item.project() {
            let n = items.get(&project).and_then(Value::as_u64).unwrap_or(0);
            items.insert(project, json!(n + 1));
        }
    }
    json!({
        "schema": schema::payload(),
        "config": to_json(&normalize(&file.data, "")),
        "digest": file.digest,
        "issues": issues_json(&issues),
        "features": features(&file.data, &issues),
        "items": items,
        "priceDefaults": price_defaults(),
        "path": data_root::config_file().to_string_lossy(),
    })
}

fn check(config: &Value) -> Value {
    let data = to_yaml(config);
    let issues = ConfigCheck::new(&data, None, &MachineProbe).issues();
    json!({"issues": issues_json(&issues), "features": features(&data, &issues)})
}

fn save(config: &Value, digest: &str, token: &str) -> Reply {
    let data = to_yaml(config);
    let mut file = ConfigFile::load(&data_root::config_file());
    file.replace(data.clone());
    match file.write(Some(digest)) {
        Ok(_) => {
            let state = crate::gui_state::build(token);
            answer("200 OK", json!({"ok": true, "settings": payload(&ConfigFile::load(&data_root::config_file())), "state": state}))
        }
        Err(e @ WriteError::Stale) => answer("409 Conflict", json!({"ok": false, "stale": true, "error": e.message(), "settings": payload(&ConfigFile::load(&data_root::config_file()))})),
        Err(WriteError::Invalid(issues)) => {
            let message = WriteError::Invalid(issues.clone()).message();
            answer("422 Unprocessable Content", json!({"ok": false, "error": message, "issues": issues_json(&issues), "features": features(&data, &issues)}))
        }
        Err(e) => answer("500 Internal Server Error", json!({"ok": false, "error": e.message()})),
    }
}

/// A mapping as the form edits it: unset values dropped (`tidy`) and every shorthand opened into its mapping
/// (a project's plain path is `{root}`, a plain dev_server `{command}`); keys the schema doesn't govern are
/// left as they are.
fn normalize(value: &Yaml, pattern: &str) -> Yaml {
    let shorthand = schema::container_at(pattern).and_then(|c| c.shorthand);
    let value = match (shorthand, value) {
        (Some(short), Yaml::String(_)) => Yaml::Mapping(serde_yaml::Mapping::from_iter([(Yaml::String(short.into()), value.clone())])),
        _ => value.clone(),
    };
    let Yaml::Mapping(map) = &value else { return value };
    let map = match pattern.is_empty() {
        true => match tidy(&value, "") {
            Yaml::Mapping(m) => m,
            _ => return value,
        },
        false => map.clone(),
    };
    let mut out = serde_yaml::Mapping::new();
    for (key, child_value) in &map {
        let child = schema::child(pattern, &text(key)).filter(|c| schema::container_at(c).is_some());
        out.insert(key.clone(), match child {
            Some(c) => normalize(child_value, &c),
            None => child_value.clone(),
        });
    }
    Yaml::Mapping(out)
}

pub(crate) fn to_yaml(value: &Value) -> Yaml {
    serde_yaml::to_value(value).unwrap_or(Yaml::Null)
}

/// A YAML value as JSON, mapping keys as their text.
pub(crate) fn to_json(value: &Yaml) -> Value {
    match value {
        Yaml::Null => Value::Null,
        Yaml::Bool(b) => json!(b),
        Yaml::Number(n) => n.as_i64().map(|i| json!(i)).or_else(|| n.as_u64().map(|u| json!(u))).or_else(|| n.as_f64().and_then(|f| serde_json::Number::from_f64(f).map(Value::Number))).unwrap_or(Value::Null),
        Yaml::String(s) => json!(s),
        Yaml::Sequence(items) => Value::Array(items.iter().map(to_json).collect()),
        Yaml::Mapping(m) => Value::Object(m.iter().map(|(k, v)| (text(k), to_json(v))).collect()),
        Yaml::Tagged(t) => to_json(&t.value),
    }
}
