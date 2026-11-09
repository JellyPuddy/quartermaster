//! The flows a local automation's run can take, by the yml's `flow:` name (default chat). Each flow has a
//! name, the item fields it needs and a start, which answers the chat that runs, or why the run can't start
//! yet and stays queued.

use serde_json::Value;

use crate::automation_store::{local_settings, validate_local, Entry, Record};
use crate::{chat_flow, pr_review_flow};

pub const DEFAULT: &str = "chat";
pub const NAMES: [&str; 2] = ["chat", "pr-review"];

/// What a flow's start answers: the chat that runs, or why the run stays queued.
#[derive(Debug, PartialEq)]
pub enum Reply {
    Started { item_slug: String, tmux: String },
    Waiting(String),
}

/// Why a start failed: a flow refusing an item its automation may not run (pr-review: a repo outside its repos
/// list), which the tick records as refused, or any other trouble, recorded as failed.
#[derive(Debug)]
pub enum FlowError {
    Refused(String),
    Other(String),
}

impl FlowError {
    pub fn message(&self) -> &str {
        match self {
            FlowError::Refused(m) | FlowError::Other(m) => m,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Flow {
    Chat,
    PrReview,
}

impl Flow {
    pub fn name(self) -> &'static str {
        match self {
            Flow::Chat => "chat",
            Flow::PrReview => "pr-review",
        }
    }

    /// The item fields the flow can't run without.
    pub fn needs(self) -> &'static [&'static str] {
        match self {
            Flow::Chat => &[],
            Flow::PrReview => &["url"],
        }
    }
}

pub fn fetch(name: Option<&str>) -> Result<Flow, String> {
    match name.unwrap_or(DEFAULT) {
        "chat" => Ok(Flow::Chat),
        "pr-review" => Ok(Flow::PrReview),
        other => Err(format!("unknown flow {} ({})", crate::ruby_text::inspect_ascii(other).unwrap_or_else(|| format!("{other:?}")), NAMES.join(", "))),
    }
}

/// Why the flow can't take this item, or None: an unknown flow, or a field its needs lists that the item
/// lacks or leaves blank. A cron run's item is null, so it lacks every field.
pub fn problem(name: Option<&str>, item: &Value) -> Option<String> {
    let flow = match fetch(name) {
        Ok(flow) => flow,
        Err(message) => return Some(message),
    };
    let blank = |field: &str| item.get(field).is_none_or(|v| to_s(v).trim().is_empty());
    let missing: Vec<&str> = flow.needs().iter().copied().filter(|f| !item.is_object() || blank(f)).collect();
    if missing.is_empty() {
        return None;
    }
    let what = if item.is_object() { format!("item {}", crate::ruby_text::inspect_ascii(&to_s(item.get("key").unwrap_or(&Value::Null))).unwrap_or_default()) } else { "a run without an item".into() };
    Some(format!("{what} lacks {}, which the {} flow needs", missing.join(", "), flow.name()))
}

/// Ruby's `to_s` of a JSON value.
fn to_s(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Why the automation may not run this item through the flow, or None; only a flow with a refusal rule
/// (pr-review) refuses.
pub fn refusal(name: Option<&str>, record: &Record, item: &Value) -> Option<String> {
    match fetch(name) {
        Ok(Flow::PrReview) => pr_review_flow::refusal(record, item),
        Ok(Flow::Chat) => None,
        Err(message) => Some(message),
    }
}

/// Starts the run through the automation's flow; fails when the item doesn't suit it or the yml (hand-edited
/// past the store) is invalid.
pub fn start(automation: &Entry, item: &Value, prompt: &str, run_id: &str, session_id: &str) -> Result<Reply, FlowError> {
    validate_local(&automation.record).map_err(|e| FlowError::Other(e.message))?;
    let settings = local_settings(&automation.record);
    let name = settings.get("flow").and_then(Value::as_str);
    if let Some(reason) = problem(name, item) {
        return Err(FlowError::Other(reason));
    }
    match fetch(name).map_err(FlowError::Other)? {
        Flow::Chat => chat_flow::start(automation, item, prompt, run_id, session_id).map_err(FlowError::Other),
        Flow::PrReview => pr_review_flow::start(automation, item, prompt, session_id),
    }
}

/// The claude flags a local automation's yml sets, before the prompt. `--allowedTools` takes one comma-joined
/// value: the flag is variadic and would swallow the prompt after it.
pub fn flags(record: &Record, session_id: &str) -> Vec<String> {
    let tools: Vec<&str> = record.get("allowed_tools").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).collect();
    let text = |key: &str| record.get(key).filter(|v| !v.is_null()).map(to_s);
    let mut out = vec!["--session-id".to_string(), session_id.to_string()];
    if let Some(model) = text("model") {
        out.extend(["--model".to_string(), model]);
    }
    if let Some(mode) = text("permission_mode") {
        out.extend(["--permission-mode".to_string(), mode]);
    }
    if !tools.is_empty() {
        out.extend(["--allowedTools".to_string(), tools.join(",")]);
    }
    out
}
