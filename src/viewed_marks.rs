//! Which files of an item's diff the user marked viewed (`viewed/<slug>.json`): a mark is keyed to
//! (path, digest of that file's diff as shown). Reading and applying only; setting a mark is the
//! GUI action's, in Ruby.

use serde_json::{json, Value};

use crate::data_root;

/// A file's diff as the pane shows it, hashed: its paths, status and every hunk's header and lines.
pub fn digest(file: &Value) -> String {
    let hunks: Vec<Value> = file["hunks"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|h| {
            let lines: Vec<String> = h["lines"].as_array().into_iter().flatten().map(|l| format!("{}{}", l["t"].as_str().unwrap_or(""), l["s"].as_str().unwrap_or(""))).collect();
            json!([h["header"], lines])
        })
        .collect();
    let binary = if file["binary"].as_bool().unwrap_or(false) { 1 } else { 0 };
    let shown = json!([file["status"], file["oldPath"], file["path"], binary, hunks]);
    crate::sha256::hex(shown.to_string().as_bytes())[..20].to_string()
}

/// `ViewedMarks#marks`: path → digests, empty for anything unreadable.
fn marks(slug: &str) -> serde_json::Map<String, Value> {
    let path = data_root::root().join("viewed").join(format!("{slug}.json"));
    match std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        Some(Value::Object(d)) => match d.get("marks") {
            Some(Value::Object(m)) => m.clone(),
            _ => Default::default(),
        },
        _ => Default::default(),
    }
}

/// Gives each file of a diff payload its `digest` and `viewed` flag.
pub fn apply(slug: &str, files: &mut [Value]) {
    let known = marks(slug);
    for file in files {
        let d = digest(file);
        let viewed = match known.get(file["path"].as_str().unwrap_or("")) {
            Some(Value::Array(list)) => list.iter().any(|x| x.as_str() == Some(d.as_str())),
            Some(Value::Null) | None => false,
            Some(Value::String(s)) => *s == d,
            Some(_) => false,
        };
        let o = file.as_object_mut().unwrap();
        o.insert("digest".into(), json!(d));
        o.insert("viewed".into(), json!(viewed));
    }
}
