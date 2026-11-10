//! A local automation's `when:` guard: a shell command run through the command runner in the automation's cwd,
//! given 60 s. Each non-empty stdout line is one item: a JSON object with a string `key` as it is, any other
//! line as `{key: line, line: line}`. A JSON object without a string key is refused on its own; a non-zero exit
//! or a timeout fails the whole guard.

use serde_json::{json, Map, Value};

use crate::command_runner;

pub const TIMEOUT: u64 = 60;

/// The guard failed as a whole: its message says why.
#[derive(Debug)]
pub struct Failed(pub String);

/// (items, problems): problems are `{"error", "item"}` for refused lines.
pub fn run(command: &str, cwd: &str) -> Result<(Vec<Value>, Vec<Value>), Failed> {
    if !std::path::Path::new(cwd).is_dir() {
        return Err(Failed(format!("guard failed: the working directory {cwd} doesn't exist")));
    }
    let result = command_runner::call_bounded(&["sh", "-c", command], Some(cwd), TIMEOUT);
    if !result.success {
        return Err(Failed(failure(&result.err)));
    }
    Ok(parse(&result.out))
}

pub fn parse(out: &str) -> (Vec<Value>, Vec<Value>) {
    let (mut items, mut problems) = (vec![], vec![]);
    for line in out.lines().map(crate::ruby_text::strip).filter(|l| !l.is_empty()) {
        let object = if line.starts_with('{') { serde_json::from_str::<Value>(line).ok().filter(Value::is_object) } else { None };
        match object {
            None => {
                let mut plain = Map::new();
                plain.insert("key".into(), json!(line));
                plain.insert("line".into(), json!(line));
                items.push(Value::Object(plain));
            }
            Some(object) if object.get("key").and_then(Value::as_str).is_some_and(|k| !crate::ruby_text::strip(k).is_empty()) => items.push(object),
            Some(_) => problems.push(json!({"error": "a guard's JSON item needs a string key", "item": line})),
        }
    }
    (items, problems)
}

fn failure(err: &str) -> String {
    let lines: Vec<&str> = crate::ruby_text::strip(err).split_inclusive('\n').collect();
    let tail: String = lines[lines.len().saturating_sub(3)..].concat();
    let detail = crate::ruby_text::strip(&tail);
    let detail = if detail.is_empty() { "exited non-zero with nothing on stderr" } else { detail };
    format!("guard failed: {}", crate::ruby_text::prefix(detail, 300))
}
