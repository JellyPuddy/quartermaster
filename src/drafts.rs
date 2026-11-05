//! The item's unsent drafts (`drafts/<slug>.json`, docs/areas/drafts.md): read only here.
//! Writing them — `qm draft add`, the GUI — stays Ruby's.

use serde_json::{Map, Value};

use crate::data_root;

/// `Drafts#entries`: the file's entries, or none when it is missing or unreadable as Ruby would read
/// it. `None` when an entry isn't an object, or holds a number Ruby would print differently.
pub fn entries(slug: &str) -> Option<Vec<Map<String, Value>>> {
    let Ok(text) = std::fs::read_to_string(data_root::root().join("drafts").join(format!("{slug}.json"))) else { return Some(vec![]) };
    let Ok(Value::Object(data)) = serde_json::from_str::<Value>(&text) else { return Some(vec![]) };
    let Some(Value::Array(list)) = data.get("entries") else { return Some(vec![]) };
    let mut out = vec![];
    for entry in list {
        let Value::Object(map) = entry else { return None };
        if has_float(entry) {
            return None;
        }
        out.push(map.clone());
    }
    Some(out)
}

fn has_float(v: &Value) -> bool {
    match v {
        Value::Number(n) => !(n.is_i64() || n.is_u64()),
        Value::Array(items) => items.iter().any(has_float),
        Value::Object(map) => map.values().any(has_float),
        _ => false,
    }
}

/// `JSON.pretty_generate` as the json 2.7 gem writes it: two-space indent, and an empty array or
/// object opens and closes on lines of their own (`[\n\n]`, `{\n}`).
pub fn pretty(v: &Value) -> String {
    let mut out = String::new();
    write(v, 0, &mut out);
    out
}

fn write(v: &Value, depth: usize, out: &mut String) {
    let pad = |n: usize| "  ".repeat(n);
    match v {
        Value::Array(items) => {
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&pad(depth + 1));
                write(item, depth + 1, out);
            }
            out.push('\n');
            out.push_str(&pad(depth));
            out.push(']');
        }
        Value::Object(map) if map.is_empty() => {
            out.push_str("{\n");
            out.push_str(&pad(depth));
            out.push('}');
        }
        Value::Object(map) => {
            out.push_str("{\n");
            for (i, (key, value)) in map.iter().enumerate() {
                if i > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&pad(depth + 1));
                out.push_str(&serde_json::to_string(key).unwrap());
                out.push_str(": ");
                write(value, depth + 1, out);
            }
            out.push('\n');
            out.push_str(&pad(depth));
            out.push('}');
        }
        scalar => out.push_str(&serde_json::to_string(scalar).unwrap()),
    }
}
