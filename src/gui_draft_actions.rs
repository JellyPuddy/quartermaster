//! The draft actions of `POST /api/action` (`draft-put`, `draft-move`, `draft-edit`, `draft-delete`,
//! `drafts-discard`), as `Drafts` and `GuiActions` do them. A GitHub draft needs the repo's anchors
//! (`ReviewAnchors.refusal`) and a PR address needs the PR checks: both stay Ruby's (501).

use serde_json::{json, Map, Value};

use crate::clock::now_utc_iso;
use crate::drafts::{update, Halt};
use crate::gui_actions::{ok, Stop};
use crate::ruby_text::strip;

type R<T> = Result<T, Stop>;

const DIFF_FIELDS: [&str; 10] = ["path", "side", "line", "code", "range", "start_line", "start_side", "branch", "committed", "number"];
const PR_FIELDS: [&str; 6] = ["repo", "number", "base", "commit", "subject", "author"];
const LINE_KINDS: [&str; 2] = ["diff-comment", "github-comment"];

fn halt(h: Halt) -> Stop {
    match h {
        Halt::Refuse(m) => Stop::refuse(m),
        Halt::Unported => Stop::Unported,
    }
}

fn refuse<T>(m: impl Into<String>) -> Result<T, Halt> {
    Err(Halt::Refuse(m.into()))
}

/// `value.to_s` for scalars; what Ruby prints for anything else is not reproduced.
fn to_s(v: &Value) -> Result<String, Halt> {
    match v {
        Value::Null => Ok(String::new()),
        Value::String(s) => Ok(s.clone()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Number(n) if n.is_i64() || n.is_u64() => Ok(n.to_string()),
        _ => Err(Halt::Unported),
    }
}

/// `entry["rev"].to_i` where it is an integer or missing.
fn rev(entry: &Map<String, Value>) -> Result<i64, Halt> {
    match entry.get("rev") {
        None | Some(Value::Null) => Ok(0),
        Some(Value::Number(n)) if n.is_i64() => Ok(n.as_i64().unwrap()),
        _ => Err(Halt::Unported),
    }
}

fn id_of(e: &Value) -> Option<&str> {
    e.get("id").and_then(Value::as_str)
}

fn position(list: &[Value], id: &str) -> Option<usize> {
    list.iter().position(|e| id_of(e) == Some(id))
}

fn bumped(entry: &mut Map<String, Value>) -> Result<(), Halt> {
    let next = rev(entry)? + 1;
    entry.insert("rev".into(), json!(next));
    entry.insert("updatedAt".into(), json!(now_utc_iso()));
    Ok(())
}

fn as_map(v: &mut Value) -> Result<&mut Map<String, Value>, Halt> {
    v.as_object_mut().ok_or(Halt::Unported)
}

pub(crate) fn edit(slug: &str, id: &str, comment: &Value) -> R<Value> {
    let comment = to_s(comment).map_err(halt)?;
    if strip(&comment).is_empty() {
        return Err(Stop::refuse("a draft can't be blank — delete it instead"));
    }
    let entry = update(slug, |list| {
        let Some(at) = position(list, id) else { return refuse(format!("no draft {id} on {slug}")) };
        let entry = as_map(&mut list[at])?;
        if entry.get("author").and_then(Value::as_str) == Some("claude") && entry.get("comment") != Some(&Value::String(comment.clone())) {
            entry.insert("author".into(), json!("user"));
        }
        if entry.get("comment") != Some(&Value::String(comment.clone())) {
            entry.shift_remove("failed");
            entry.insert("comment".into(), json!(comment));
            bumped(entry)?;
        }
        Ok(Value::Object(entry.clone()))
    })
    .map_err(halt)?;
    Ok(merged("draft", entry))
}

pub(crate) fn delete(slug: &str, id: &str) -> R<Value> {
    let gone = update(slug, |list| {
        let before = list.len();
        list.retain(|e| id_of(e) != Some(id));
        Ok(list.len() != before)
    })
    .map_err(halt)?;
    Ok(merged("deleted", json!(gone)))
}

/// `drafts-discard`: exactly these ids at the revs they have now; without an id list, everything.
pub(crate) fn discard(slug: &str, ids: &Value) -> R<Value> {
    let ids = match ids {
        Value::Array(items) => {
            if items.iter().any(|i| matches!(i, Value::Number(n) if !(n.is_i64() || n.is_u64())) || i.is_array() || i.is_object()) {
                return Err(Stop::Unported);
            }
            Some(items.clone())
        }
        _ => None,
    };
    let gone = update(slug, |list| {
        let revs: Option<Vec<(Value, Value)>> = ids.as_ref().map(|ids| list.iter().filter(|e| ids.contains(e.get("id").unwrap_or(&Value::Null))).map(|e| (e.get("id").cloned().unwrap_or(Value::Null), e.get("rev").cloned().unwrap_or(Value::Null))).collect());
        let before = list.len();
        list.retain(|e| match &revs {
            None => false,
            Some(map) => {
                let id = e.get("id").cloned().unwrap_or(Value::Null);
                let want = map.iter().rev().find(|(k, _)| *k == id).map(|(_, v)| v.clone()).unwrap_or(Value::Null);
                want != e.get("rev").cloned().unwrap_or(Value::Null)
            }
        });
        Ok(before - list.len())
    })
    .map_err(halt)?;
    Ok(merged("discarded", json!(gone)))
}

/// `Drafts#move` to the chat; a move to the review checks the line with git and stays Ruby's.
pub(crate) fn move_to(slug: &str, id: &str, to: &Value) -> R<Value> {
    if to.as_str() == Some("github") {
        return Err(Stop::Unported);
    }
    if to.as_str() != Some("chat") {
        let shown = match to {
            Value::Null => "nil".to_string(),
            Value::Bool(b) => b.to_string(),
            Value::Number(n) if n.is_i64() || n.is_u64() => n.to_string(),
            Value::String(s) => crate::ruby_text::inspect_ascii(s).ok_or(Stop::Unported)?,
            _ => return Err(Stop::Unported),
        };
        return Err(Stop::refuse(format!("a draft moves to github or chat, not {shown}")));
    }
    let entry = update(slug, |list| {
        let Some(at) = position(list, id) else { return refuse(format!("no draft {id} on {slug}")) };
        let entry = as_map(&mut list[at])?;
        let kind = entry.get("kind").and_then(Value::as_str).unwrap_or("");
        if !LINE_KINDS.contains(&kind) {
            return refuse("only a diff comment moves between the review and the chat");
        }
        if kind != "diff-comment" {
            entry.insert("kind".into(), json!("diff-comment"));
            entry.shift_remove("failed");
            bumped(entry)?;
        }
        Ok(Value::Object(entry.clone()))
    })
    .map_err(halt)?;
    Ok(merged("draft", entry))
}

fn branch_name(s: &str) -> bool {
    let n = s.chars().count();
    (1..=255).contains(&n) && s.chars().all(|c| !(c.is_ascii_whitespace() || c == '\u{b}' || "~^:?*[\\".contains(c) || c.is_control()))
}

fn blank(v: Option<&Value>) -> bool {
    matches!(v, None | Some(Value::Null)) || v == Some(&Value::String(String::new()))
}

/// `draft-put` for a chat diff comment.
pub(crate) fn put(slug: &str, raw: &Map<String, Value>) -> R<Value> {
    let kind = match raw.get("kind") {
        None | Some(Value::Null) => String::new(),
        Some(v) => to_s(v).map_err(halt)?,
    };
    let kind = if kind.is_empty() { "diff-comment".to_string() } else { kind };
    if kind == "github-comment" {
        return Err(Stop::Unported);
    }
    if !LINE_KINDS.contains(&kind.as_str()) {
        return Err(Stop::refuse(format!("'{kind}' is not a diff comment kind")));
    }
    let mut fields = Map::new();
    for k in DIFF_FIELDS.iter().take(9) {
        if let Some(v) = raw.get(*k) {
            if !blank(Some(v)) {
                fields.insert((*k).into(), v.clone());
            }
        }
    }
    let path = fields.get("path").map(to_s).transpose().map_err(halt)?.unwrap_or_default();
    if strip(&path).is_empty() {
        return Err(Stop::refuse("a diff comment needs a path"));
    }
    if let Some(b) = fields.get("branch") {
        if !b.as_str().is_some_and(branch_name) {
            return Err(Stop::refuse("a diff comment's branch must be a branch name"));
        }
    }
    if fields.get("committed") != Some(&Value::Bool(true)) {
        fields.shift_remove("committed");
    }
    if !blank(raw.get("number")) {
        return Err(Stop::Unported); // a PR draft: the repo, number and commit checks
    }
    let comment = raw.get("comment").map(to_s).transpose().map_err(halt)?.unwrap_or_default();
    let address = |m: &Map<String, Value>| -> Result<Vec<String>, Halt> { ["range", "side", "line", "path", "number"].iter().map(|k| m.get(*k).map(to_s).transpose().map(Option::unwrap_or_default)).collect() };
    let wanted = address(&fields).map_err(halt)?;
    let stored = update(slug, |list| {
        let mut found = None;
        for (i, e) in list.iter().enumerate() {
            let kind = e.get("kind").and_then(Value::as_str).unwrap_or("");
            if LINE_KINDS.contains(&kind) && address(e.as_object().ok_or(Halt::Unported)?)? == wanted {
                found = Some(i);
                break;
            }
        }
        if strip(&comment).is_empty() {
            if let Some(i) = found {
                list.remove(i);
            }
            return Ok(Value::Null);
        }
        if let Some(i) = found {
            let entry = as_map(&mut list[i])?;
            let before = entry.clone();
            for k in DIFF_FIELDS.iter().chain(PR_FIELDS.iter()).chain(["pin", "failed"].iter()) {
                if !fields.contains_key(*k) {
                    entry.shift_remove(*k);
                }
            }
            for (k, v) in &fields {
                entry.insert(k.clone(), v.clone());
            }
            entry.insert("kind".into(), json!(kind));
            entry.insert("comment".into(), json!(comment));
            if *entry != before {
                bumped(entry)?;
            }
            return Ok(Value::Object(entry.clone()));
        }
        let at = now_utc_iso();
        let mut entry = Map::new();
        entry.insert("id".into(), json!(random_id()));
        entry.insert("kind".into(), json!(kind));
        entry.insert("comment".into(), json!(comment));
        entry.insert("rev".into(), json!(1));
        entry.insert("createdAt".into(), json!(at));
        entry.insert("updatedAt".into(), json!(at));
        for (k, v) in &fields {
            entry.insert(k.clone(), v.clone());
        }
        list.push(Value::Object(entry.clone()));
        Ok(Value::Object(entry))
    })
    .map_err(halt)?;
    Ok(merged("draft", stored))
}

/// `SecureRandom.hex(n)`.
pub(crate) fn random_hex(n: usize) -> String {
    use std::io::Read;
    let mut bytes = vec![0u8; n];
    let _ = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes));
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn random_id() -> String {
    random_hex(6)
}

fn merged(key: &str, v: Value) -> Value {
    let mut out = ok();
    out.as_object_mut().unwrap().insert(key.into(), v);
    out
}
