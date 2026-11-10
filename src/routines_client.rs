//! The claude.ai routines API (scheduled cloud Claude Code agents), called straight at api.anthropic.com with
//! Claude Code's own login. Off until `automations.token_source` is set; then each call reads the token from
//! the keychain through the command runner and drops it afterwards: never stored, logged, put in a message or
//! refreshed (a refresh would rotate Claude Code's refresh token and could log it out). Requests go out through
//! `curl` with their headers and body on its stdin, so the token never sits in an argument list. Every failure
//! is a `QmError` of a `RoutinesClient::…` class whose message is for the user. Request bodies are built in
//! `request_body` only, the one place to fix when the API's shape moves.

use std::path::PathBuf;

use serde_json::{json, Map, Value};

use crate::cli_format::short_path;
use crate::command_runner::{self, CmdResult};
use crate::error::{QmError, Res};
use crate::{data_root, project_config::ProjectConfig, random_id};

pub const API: &str = "https://api.anthropic.com";
const HEADERS: [(&str, &str); 3] = [("anthropic-version", "2023-06-01"), ("anthropic-beta", "ccr-triggers-2026-01-30"), ("content-type", "application/json")];
const KEYCHAIN: [&str; 5] = ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"];
pub const TOKEN_SOURCES: [&str; 1] = ["claude_code"];
pub const CONFIG_COMMAND: &str = "qm config set automations.token_source claude_code";
/// Local field → its top-level API key; the `JOB_FIELDS` go in `job_config`.
const BODY_KEYS: [(&str, &str); 4] = [("name", "name"), ("cron", "cron_expression"), ("enabled", "enabled"), ("connectors", "mcp_connections")];
pub const JOB_FIELDS: [&str; 5] = ["prompt", "model", "sources", "allowed_tools", "environment_id"];

pub const NOT_ENABLED: &str = "RoutinesClient::NotEnabled";
pub const TOKEN_EXPIRED: &str = "RoutinesClient::TokenExpired";
pub const API_CHANGED: &str = "RoutinesClient::ApiChanged";
pub const ROUTINE_MISSING: &str = "RoutinesClient::RoutineMissing";
pub const BAD_SHAPE: &str = "RoutinesClient::BadShape";
pub const NETWORK: &str = "RoutinesClient::Network";
pub const ERROR: &str = "RoutinesClient::Error";

const EXPIRED: &str = "Claude Code's login token expired — open any Claude Code session, then refresh";

fn failure(class: &'static str, message: impl Into<String>) -> QmError {
    QmError::new(class, message)
}

fn not_enabled() -> QmError {
    failure(NOT_ENABLED, format!("automations are off: run `{CONFIG_COMMAND}`"))
}

pub fn routine_url(id: &str) -> String {
    format!("https://claude.ai/code/routines/{id}")
}

pub fn run_url(session_id: &str) -> String {
    format!("https://claude.ai/code/{session_id}")
}

/// One HTTPS request: `(status, body)`, or what went wrong before an answer came.
pub trait Transport {
    fn call(&self, method: &str, url: &str, headers: &[(String, String)], body: Option<&str>) -> Result<(u16, String), String>;
}

/// `curl`, its options, headers and body read from stdin.
pub struct CurlTransport;

fn quoted(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

impl Transport for CurlTransport {
    fn call(&self, method: &str, url: &str, headers: &[(String, String)], body: Option<&str>) -> Result<(u16, String), String> {
        let mut config = format!("silent\nshow-error\nconnect-timeout = 10\nmax-time = 30\nurl = {}\nrequest = {}\nwrite-out = \"\\n%{{http_code}}\"\n", quoted(url), quoted(method));
        for (name, value) in headers {
            config.push_str(&format!("header = {}\n", quoted(&format!("{name}: {value}"))));
        }
        if let Some(body) = body {
            config.push_str(&format!("data-raw = {}\n", quoted(body)));
        }
        let result = command_runner::call_with_input(&["curl", "-K", "-"], &config);
        if !result.success {
            let detail = result.err.trim();
            return Err(if detail.is_empty() { "curl failed".to_string() } else { detail.to_string() });
        }
        let (text, code) = result.out.rsplit_once('\n').ok_or("curl answered nothing")?;
        Ok((code.trim().parse::<u16>().map_err(|_| "curl answered no status")?, text.to_string()))
    }
}

/// The routine API's calls, as the Automations service needs them.
pub trait Routines {
    fn list(&self) -> Res<Vec<Value>>;
    fn get(&self, id: &str) -> Res<Value>;
    fn create(&self, fields: &Map<String, Value>) -> Res<Value>;
    fn update(&self, id: &str, fields: &Map<String, Value>) -> Res<Value>;
    fn run(&self, id: &str) -> Res<Value>;
    fn runs(&self, id: &str, limit: usize) -> Res<Vec<Value>>;
    fn delete(&self, id: &str) -> Res<Deleted>;
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Deleted {
    Deleted,
    /// The API has no delete (404 or 405); what to do then is the caller's call.
    Unsupported,
}

/// A remote routine in the local shape: id, name, cron (UTC), enabled, prompt, model, sources, allowed_tools,
/// environment_id, connectors (its `mcp_connections` as given) and updated_at. The one remote-to-local mapping:
/// prompt and model fall back to `derived_state`.
pub fn fields(routine: &Value) -> Res<Map<String, Value>> {
    let Some(id) = routine.get("id").and_then(Value::as_str) else {
        return Err(failure(BAD_SHAPE, "routines API answered a routine without an id"));
    };
    let empty = Map::new();
    let ccr = routine.pointer("/job_config/ccr").and_then(Value::as_object).unwrap_or(&empty);
    let context = ccr.get("session_context").and_then(Value::as_object).unwrap_or(&empty);
    let derived = |key: &str| routine.pointer(&format!("/derived_state/{key}")).cloned().unwrap_or(Value::Null);
    let first = ccr.get("events").and_then(Value::as_array).and_then(|events| events.first());
    let prompt = match first.and_then(|event| event.pointer("/data/message/content")) {
        Some(p @ Value::String(_)) => p.clone(),
        _ => derived("prompt"),
    };
    let model = match context.get("model") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => derived("model"),
        Some(m) => m.clone(),
    };
    let get = |source: &Map<String, Value>, key: &str| source.get(key).cloned().unwrap_or(Value::Null);
    let mut out = Map::new();
    out.insert("id".into(), json!(id));
    out.insert("name".into(), routine.get("name").cloned().unwrap_or(Value::Null));
    out.insert("cron".into(), routine.get("cron_expression").cloned().unwrap_or(Value::Null));
    out.insert("enabled".into(), routine.get("enabled").cloned().unwrap_or(Value::Null));
    out.insert("prompt".into(), prompt);
    out.insert("model".into(), model);
    out.insert("sources".into(), get(context, "sources"));
    out.insert("allowed_tools".into(), get(context, "allowed_tools"));
    out.insert("environment_id".into(), get(ccr, "environment_id"));
    out.insert("connectors".into(), routine.get("mcp_connections").cloned().unwrap_or(Value::Null));
    out.insert("updated_at".into(), routine.get("updated_at").cloned().unwrap_or(Value::Null));
    Ok(out)
}

fn present<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    fields.get(key).filter(|v| !v.is_null())
}

/// The create/update body for local fields; only the fields given, so a partial update stays partial, and a
/// null top-level field is left out (the API would read null as a change). Any job field sends the whole
/// `job_config`. Given connectors (null counts as none) are sent as the routine's exact set: an empty list also
/// sends `clear_mcp_connections`, since the API reads an empty or missing `mcp_connections` as "leave them"
/// (on create: "attach all"). Callers that omit connectors leave them untouched.
pub fn request_body(fields: &Map<String, Value>, uuid: &str) -> Value {
    let mut body = Map::new();
    for (local, api) in BODY_KEYS {
        if let Some(v) = present(fields, local) {
            body.insert(api.into(), v.clone());
        }
    }
    if fields.contains_key("connectors") {
        let connectors = match present(fields, "connectors") {
            Some(c) => c.clone(),
            None => json!([]),
        };
        let empty = connectors.as_array().is_some_and(Vec::is_empty);
        body.insert("mcp_connections".into(), connectors);
        if empty {
            body.insert("clear_mcp_connections".into(), json!(true));
        }
    }
    if JOB_FIELDS.iter().any(|f| fields.contains_key(*f)) {
        body.insert("job_config".into(), job_config(fields, uuid));
    }
    Value::Object(body)
}

fn job_config(fields: &Map<String, Value>, uuid: &str) -> Value {
    let prompt = match present(fields, "prompt") {
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
        None => String::new(),
    };
    let event = json!({"data": {"message": {"content": prompt, "role": "user"}, "parent_tool_use_id": null, "session_id": "", "type": "user", "uuid": uuid}});
    let mut context = Map::new();
    context.insert("allowed_tools".into(), present(fields, "allowed_tools").cloned().unwrap_or(json!([])));
    if let Some(model) = present(fields, "model") {
        context.insert("model".into(), model.clone());
    }
    context.insert("sources".into(), present(fields, "sources").cloned().unwrap_or(json!([])));
    json!({"ccr": {"environment_id": fields.get("environment_id").cloned().unwrap_or(Value::Null), "events": [event], "session_context": context}})
}

pub struct RoutinesClient {
    transport: Box<dyn Transport>,
    keychain: Box<dyn Fn() -> CmdResult>,
    claude_json: PathBuf,
    token_source: Box<dyn Fn() -> Option<String>>,
}

impl RoutinesClient {
    /// The client of this process: curl, the keychain through the command runner, `~/.claude.json`, and
    /// config.yml's `automations.token_source` asked on every call.
    pub fn new() -> RoutinesClient {
        RoutinesClient {
            transport: Box::new(CurlTransport),
            keychain: Box::new(|| command_runner::call(&KEYCHAIN)),
            claude_json: data_root::expand_path("~/.claude.json"),
            token_source: Box::new(|| ProjectConfig::current().automations_token_source().map(String::from)),
        }
    }

    pub fn with_transport(mut self, transport: Box<dyn Transport>) -> RoutinesClient {
        self.transport = transport;
        self
    }

    pub fn with_keychain(mut self, keychain: Box<dyn Fn() -> CmdResult>) -> RoutinesClient {
        self.keychain = keychain;
        self
    }

    pub fn with_claude_json(mut self, path: PathBuf) -> RoutinesClient {
        self.claude_json = path;
        self
    }

    pub fn with_token_source(mut self, source: Box<dyn Fn() -> Option<String>>) -> RoutinesClient {
        self.token_source = source;
        self
    }

    fn routines(answer: &Value) -> Res<Vec<Value>> {
        let Some(list) = answer.get("data").and_then(Value::as_array) else {
            return Err(failure(BAD_SHAPE, "routines API answered a list without data"));
        };
        for routine in list {
            fields(routine)?;
        }
        Ok(list.clone())
    }

    /// A single-routine answer: the API wraps it as `{"trigger": routine}`; a bare routine is read as well.
    fn routine(answer: Value) -> Res<Value> {
        let routine = match answer.get("trigger") {
            Some(inner) => inner.clone(),
            None => answer,
        };
        fields(&routine)?;
        Ok(routine)
    }

    /// `missing`: the routine id a per-routine path names, so its 404 reads as that routine being gone rather
    /// than the API having moved.
    fn request(&self, method: &str, path: &str, body: Option<Value>, unsupported: &[u16], missing: Option<&str>) -> Res<Result<Value, Deleted>> {
        let token = self.token()?;
        let organization = self.organization()?;
        let mut headers: Vec<(String, String)> = vec![("Authorization".into(), format!("Bearer {token}"))];
        headers.extend(HEADERS.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        headers.push(("x-organization-uuid".into(), organization));
        let text_body = body.map(|b| serde_json::to_string(&b).unwrap_or_default());
        let (status, text) = self
            .transport
            .call(method, &format!("{API}{path}"), &headers, text_body.as_deref())
            .map_err(|e| failure(NETWORK, scrub(&format!("can't reach api.anthropic.com: {e}"), &token)))?;
        if unsupported.contains(&status) {
            return Ok(Err(Deleted::Unsupported));
        }
        check_status(status, &text, &token, missing)?;
        parse(&text).map(Ok)
    }

    fn token(&self) -> Res<String> {
        let enabled = (self.token_source)().is_some_and(|source| TOKEN_SOURCES.contains(&source.as_str()));
        if !enabled {
            return Err(not_enabled());
        }
        let result = (self.keychain)();
        if !result.success {
            return Err(failure(TOKEN_EXPIRED, "Claude Code's login wasn't found in the keychain — log in to Claude Code, then refresh"));
        }
        let oauth = serde_json::from_str::<Value>(&result.out).ok().and_then(|v| v.get("claudeAiOauth").cloned());
        let token = oauth.as_ref().and_then(|o| o.get("accessToken")).and_then(Value::as_str).filter(|t| !t.is_empty());
        let Some(token) = token else {
            return Err(failure(TOKEN_EXPIRED, "Claude Code's keychain login has no access token — log in to Claude Code, then refresh"));
        };
        if let Some(expires) = oauth.as_ref().and_then(|o| o.get("expiresAt")).and_then(Value::as_f64) {
            if expires / 1000.0 <= chrono::Utc::now().timestamp_millis() as f64 / 1000.0 {
                return Err(failure(TOKEN_EXPIRED, EXPIRED));
            }
        }
        Ok(token.to_string())
    }

    fn organization(&self) -> Res<String> {
        let shown = short_path(Some(&self.claude_json.to_string_lossy()));
        let Ok(text) = std::fs::read_to_string(&self.claude_json) else {
            return Err(failure(TOKEN_EXPIRED, format!("can't read {shown} — log in to Claude Code, then refresh")));
        };
        let uuid = serde_json::from_str::<Value>(&text).ok().and_then(|v| v.pointer("/oauthAccount/organizationUuid").and_then(Value::as_str).filter(|u| !u.is_empty()).map(String::from));
        uuid.ok_or_else(|| failure(TOKEN_EXPIRED, format!("no claude.ai organization in {shown} — log in to Claude Code, then refresh")))
    }
}

impl Default for RoutinesClient {
    fn default() -> Self {
        Self::new()
    }
}

fn scrub(message: &str, token: &str) -> String {
    if token.is_empty() { message.to_string() } else { message.replace(token, "[token]") }
}

fn check_status(status: u16, text: &str, token: &str, missing: Option<&str>) -> Res<()> {
    match status {
        401 => Err(failure(TOKEN_EXPIRED, EXPIRED)),
        404 if missing.is_some() => Err(failure(ROUTINE_MISSING, format!("routine {} isn't on claude.ai any more — delete the automation in qm", missing.unwrap_or("")))),
        404 => Err(failure(API_CHANGED, "routines API changed — check the `ccr-triggers-*` beta in the claude binary")),
        200..=299 => Ok(()),
        _ => {
            let detail = serde_json::from_str::<Value>(text).ok().and_then(|v| v.pointer("/error/message").and_then(Value::as_str).map(String::from));
            Err(failure(ERROR, scrub(&format!("routines API answered {status}{}", detail.map(|d| format!(": {d}")).unwrap_or_default()), token)))
        }
    }
}

fn parse(text: &str) -> Res<Value> {
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(text).map_err(|_| failure(BAD_SHAPE, "routines API answered something that isn't JSON"))
}

/// `URI.encode_www_form` of one value.
fn form_value(text: &str) -> String {
    text.bytes().map(|b| if b.is_ascii_alphanumeric() || matches!(b, b'*' | b'-' | b'.' | b'_') { (b as char).to_string() } else if b == b' ' { "+".into() } else { format!("%{b:02X}") }).collect()
}

fn done(answer: Res<Result<Value, Deleted>>) -> Res<Value> {
    answer.map(|a| a.unwrap_or(Value::Null))
}

impl Routines for RoutinesClient {
    fn list(&self) -> Res<Vec<Value>> {
        Self::routines(&done(self.request("GET", "/v1/code/triggers", None, &[], None))?)
    }

    fn get(&self, id: &str) -> Res<Value> {
        Self::routine(done(self.request("GET", &format!("/v1/code/triggers/{id}"), None, &[], Some(id)))?)
    }

    fn create(&self, fields: &Map<String, Value>) -> Res<Value> {
        Self::routine(done(self.request("POST", "/v1/code/triggers", Some(request_body(fields, &random_id::uuid())), &[], None))?)
    }

    fn update(&self, id: &str, fields: &Map<String, Value>) -> Res<Value> {
        Self::routine(done(self.request("POST", &format!("/v1/code/triggers/{id}"), Some(request_body(fields, &random_id::uuid())), &[], Some(id)))?)
    }

    fn run(&self, id: &str) -> Res<Value> {
        done(self.request("POST", &format!("/v1/code/triggers/{id}/run"), Some(json!({})), &[], Some(id)))
    }

    /// The routine's sessions, most recent first: id, title, status, the timestamps given and the claude.ai
    /// link; missing fields stay null.
    fn runs(&self, id: &str, limit: usize) -> Res<Vec<Value>> {
        let path = format!("/v1/code/sessions?trigger_id={}&limit={limit}", form_value(id));
        let answer = done(self.request("GET", &path, None, &[], Some(id)))?;
        let list = if answer.is_object() { answer.get("data") } else { Some(&answer) };
        let Some(list) = list.and_then(Value::as_array) else {
            return Err(failure(BAD_SHAPE, "routines API answered runs that aren't a list"));
        };
        Ok(list
            .iter()
            .filter_map(|s| s.get("id").and_then(Value::as_str).map(|sid| (s, sid)))
            .take(limit)
            .map(|(s, sid)| json!({"id": sid, "title": s.get("title"), "status": s.get("status"), "created_at": s.get("created_at"), "updated_at": s.get("updated_at"), "url": run_url(sid)}))
            .collect())
    }

    fn delete(&self, id: &str) -> Res<Deleted> {
        Ok(match self.request("DELETE", &format!("/v1/code/triggers/{id}"), None, &[404, 405], None)? {
            Err(unsupported) => unsupported,
            Ok(_) => Deleted::Deleted,
        })
    }
}
