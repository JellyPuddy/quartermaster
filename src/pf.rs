//! A project's dev server (config.yml `dev_server:`), driven through its command: what it serves
//! right now. It serves one checkout at a time, so this is a single shared resource, not per item.
//! Only the read-only status is ported; switching and stopping stay in Ruby.

use serde_json::Value;

use crate::command_runner;
use crate::data_root;
use crate::project_config::{DevServer, ProjectConfig};

pub struct Status {
    pub root: Option<String>,
    pub running: bool,
}

/// The dev server qm reads: the first one any project configures.
pub fn configured_server(config: &ProjectConfig) -> Option<&DevServer> {
    config.dev_server()
}

/// The status URL answers from inside the running server — authoritative, but only while it is up.
fn from_endpoint(server: &DevServer) -> Option<Status> {
    let url = server.status_url.as_deref()?;
    let result = command_runner::call(&["curl", "-s", "--max-time", "0.5", url]);
    if !result.success {
        return None;
    }
    let data: Value = serde_json::from_str(&result.out).ok()?;
    let obj = data.as_object()?;
    obj.get("mode").filter(|m| !matches!(m, Value::Null | Value::Bool(false)))?;
    Some(Status { root: obj.get("root").and_then(Value::as_str).map(String::from), running: true })
}

/// `<command> status` exits non-zero when nothing runs; the state file, written on every switch and
/// never cleared on stop, names what it was (or still is) serving.
fn from_files(server: &DevServer) -> Status {
    let root = server
        .state_file
        .as_deref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|t| crate::ruby_text::strip(&t).split_once(' ').map(|(_, r)| r.trim_start_matches(' ').to_string()));
    let running = command_runner::call(&[server.command.as_str(), "status"]).success;
    Status { root, running }
}

pub fn status(server: Option<&DevServer>) -> Option<Status> {
    let server = server?;
    from_endpoint(server).or_else(|| Some(from_files(server)))
}

/// Whether the status says it is serving `path` right now.
pub fn serves(status: &Option<Status>, path: &str) -> bool {
    match status {
        Some(Status { running: true, root: Some(root) }) => data_root::normalize(root) == data_root::normalize(path),
        _ => false,
    }
}
