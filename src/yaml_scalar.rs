use serde_yaml::Value;

/// A YAML node as the text Ruby's `to_s` would give it.
pub fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => String::new(),
        other => serde_yaml::to_string(other).unwrap_or_default().trim().to_string(),
    }
}

/// `Array(value)`: a sequence's items, a scalar as one item, null as none.
pub fn array(v: Option<&Value>) -> Vec<&Value> {
    match v {
        Some(Value::Sequence(items)) => items.iter().collect(),
        Some(Value::Null) | None => vec![],
        Some(other) => vec![other],
    }
}

pub fn get<'a>(map: &'a serde_yaml::Mapping, key: &str) -> Option<&'a Value> {
    match map.get(key) {
        Some(Value::Null) | None => None,
        Some(v) => Some(v),
    }
}

/// A non-blank string value, stripped.
pub fn string(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) if !crate::ruby_text::strip(s).is_empty() => Some(crate::ruby_text::strip(s).to_string()),
        _ => None,
    }
}

/// A boolean as Psych (YAML 1.1) reads a plain scalar: `yes`, `true` and `on` are true, `no`, `false` and `off`
/// false, in any case; `y` and `n` stay strings. serde_yaml reads only `true` and `false`.
pub fn psych_bool(text: &str) -> Option<bool> {
    match text.to_ascii_lowercase().as_str() {
        "yes" | "true" | "on" => Some(true),
        "no" | "false" | "off" => Some(false),
        _ => None,
    }
}

/// A key the user switches with a boolean, read the Psych way; `None` when it holds neither a boolean nor a
/// spelling of one.
pub fn switch(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(b) => Some(*b),
        Value::String(s) => psych_bool(s),
        _ => None,
    }
}
