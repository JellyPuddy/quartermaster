//! RoutinesClient against a stand-in keychain and a stand-in HTTP transport: no test reaches the network or
//! the real keychain.

use quartermaster::command_runner::CmdResult;
use quartermaster::routines_client::{self as rc, Deleted, Routines, RoutinesClient, Transport};
use serde_json::{json, Map, Value};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

const LIST: &str = include_str!("fixtures/routines-list-response.json");
const GET: &str = include_str!("fixtures/routine-get-response.json");
const TOKEN: &str = "sk-ant-oat01-SECRET-TOKEN";
const ORG: &str = "0f1e2d3c-org-uuid";
const ID: &str = "trig_01AAAAAAAAAAAAAAAAAAAAAAAA";

type Answer = Result<(u16, String), String>;

#[derive(Clone, Debug)]
struct Request {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<Value>,
}

/// Answers each request from a script (the last answer repeats) and records it.
struct Stub {
    answers: RefCell<Vec<Answer>>,
    requests: Rc<RefCell<Vec<Request>>>,
}

impl Transport for Stub {
    fn call(&self, method: &str, url: &str, headers: &[(String, String)], body: Option<&str>) -> Answer {
        self.requests.borrow_mut().push(Request { method: method.into(), url: url.into(), headers: headers.to_vec(), body: body.map(|b| serde_json::from_str(b).unwrap()) });
        let mut answers = self.answers.borrow_mut();
        if answers.len() > 1 { answers.remove(0) } else { answers[0].clone() }
    }
}

struct World {
    dir: tempfile::TempDir,
    requests: Rc<RefCell<Vec<Request>>>,
    keychain_calls: Rc<RefCell<usize>>,
}

fn ok(status: u16, body: &str) -> Answer {
    Ok((status, body.to_string()))
}

fn credentials(expires_in_ms: i64) -> String {
    json!({"claudeAiOauth": {"accessToken": TOKEN, "refreshToken": "sk-ant-ort01-REFRESH", "expiresAt": chrono::Utc::now().timestamp_millis() + expires_in_ms}}).to_string()
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("claude.json"), json!({"oauthAccount": {"organizationUuid": ORG}}).to_string()).unwrap();
        World { dir, requests: Rc::default(), keychain_calls: Rc::default() }
    }

    fn claude_json(&self) -> PathBuf {
        self.dir.path().join("claude.json")
    }

    fn client(&self, answers: Vec<Answer>) -> RoutinesClient {
        self.client_with(answers, credentials(3_600_000), true, Some("claude_code"))
    }

    fn client_with(&self, answers: Vec<Answer>, out: String, success: bool, source: Option<&'static str>) -> RoutinesClient {
        let calls = self.keychain_calls.clone();
        RoutinesClient::new()
            .with_transport(Box::new(Stub { answers: RefCell::new(answers), requests: self.requests.clone() }))
            .with_keychain(Box::new(move || {
                *calls.borrow_mut() += 1;
                CmdResult { out: out.clone(), err: String::new(), success }
            }))
            .with_claude_json(self.claude_json())
            .with_token_source(Box::new(move || source.map(String::from)))
    }

    fn last(&self) -> Request {
        self.requests.borrow().last().unwrap().clone()
    }
}

fn list_first() -> Value {
    serde_json::from_str::<Value>(LIST).unwrap()["data"][0].clone()
}

fn get_routine() -> Value {
    serde_json::from_str::<Value>(GET).unwrap()["trigger"].clone()
}

fn map(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn wrapped(routine: &Value) -> String {
    json!({"trigger": routine}).to_string()
}

fn headers(request: &Request) -> Vec<(&str, &str)> {
    request.headers.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
}

#[test]
fn list_sends_the_verified_headers_and_returns_the_routines() {
    let w = World::new();
    let routines = w.client(vec![ok(200, LIST)]).list().unwrap();
    assert_eq!(routines.iter().map(|r| r["id"].as_str().unwrap()).collect::<Vec<_>>(), [ID]);
    let request = w.last();
    let sent = headers(&request);
    assert_eq!((request.method.as_str(), request.url.as_str(), request.body.as_ref()), ("GET", "https://api.anthropic.com/v1/code/triggers", None));
    for pair in [("Authorization", format!("Bearer {TOKEN}")), ("anthropic-version", "2023-06-01".into()), ("anthropic-beta", "ccr-triggers-2026-01-30".into()), ("x-organization-uuid", ORG.into()), ("content-type", "application/json".into())] {
        assert!(sent.contains(&(pair.0, pair.1.as_str())), "{pair:?} in {sent:?}");
    }
}

#[test]
fn the_token_is_read_from_the_keychain_on_every_call() {
    let w = World::new();
    let client = w.client(vec![ok(200, LIST)]);
    client.list().unwrap();
    client.list().unwrap();
    assert_eq!(*w.keychain_calls.borrow(), 2);
}

#[test]
fn fields_read_a_routine_into_the_local_shape() {
    let routine = list_first();
    let fields = rc::fields(&routine).unwrap();
    assert_eq!(
        Value::Object(fields),
        json!({"id": ID, "name": "Shipped digest (DM)", "cron": "0 7 * * 1,4", "enabled": true, "prompt": "PROMPT", "model": "claude-sonnet-5-5",
               "sources": [{"git_repository": {"url": "https://github.com/example-org/example-app"}}], "allowed_tools": ["Bash", "Read", "Glob", "Grep"],
               "environment_id": "env_01BBBBBBBBBBBBBBBBBBBBBBBB", "connectors": routine["mcp_connections"], "updated_at": "2026-10-27T12:21:01.911143Z"})
    );
}

#[test]
fn get_run_and_partial_update_hit_their_endpoints() {
    let w = World::new();
    let client = w.client(vec![ok(200, GET)]);
    let routine = client.get(ID).unwrap();
    let request = w.last();
    assert_eq!((request.method.as_str(), request.url.as_str()), ("GET", format!("https://api.anthropic.com/v1/code/triggers/{ID}").as_str()));
    assert_eq!(routine, get_routine());
    assert_eq!(rc::fields(&list_first()).unwrap(), rc::fields(&routine).unwrap());

    assert_eq!(client.update(ID, &map(json!({"enabled": false}))).unwrap()["id"], ID);
    let request = w.last();
    assert_eq!((request.method.as_str(), request.url.as_str(), request.body), ("POST", format!("https://api.anthropic.com/v1/code/triggers/{ID}").as_str(), Some(json!({"enabled": false}))));

    client.update(ID, &map(json!({"cron": "0 6 * * 1"}))).unwrap();
    assert_eq!(w.last().body, Some(json!({"cron_expression": "0 6 * * 1"})));

    client.run(ID).unwrap();
    let request = w.last();
    assert_eq!((request.method.as_str(), request.url.as_str()), ("POST", format!("https://api.anthropic.com/v1/code/triggers/{ID}/run").as_str()));
}

#[test]
fn create_mirrors_the_fixtures_job_config() {
    let w = World::new();
    let routine = list_first();
    let client = w.client(vec![ok(200, &wrapped(&routine))]);
    let mut fields = rc::fields(&routine).unwrap();
    fields.remove("id");
    fields.remove("updated_at");
    assert_eq!(client.create(&fields).unwrap(), routine);
    let request = w.last();
    let body = request.body.unwrap();
    assert_eq!((request.method.as_str(), request.url.as_str()), ("POST", "https://api.anthropic.com/v1/code/triggers"));
    assert_eq!((&body["name"], &body["cron_expression"], &body["enabled"], &body["mcp_connections"]), (&json!("Shipped digest (DM)"), &json!("0 7 * * 1,4"), &json!(true), &routine["mcp_connections"]));
    let ccr = &body["job_config"]["ccr"];
    let expected = &routine["job_config"]["ccr"];
    assert_eq!(ccr["environment_id"], expected["environment_id"]);
    assert_eq!(ccr["session_context"], expected["session_context"]);
    let event = &ccr["events"][0]["data"];
    assert_eq!(event["message"], json!({"content": "PROMPT", "role": "user"}));
    assert_eq!(event["type"], "user");
    let uuid = event["uuid"].as_str().unwrap();
    assert!(uuid.len() == 36 && uuid.matches('-').count() == 4, "{uuid}");
}

#[test]
fn an_empty_connector_list_clears_the_routines_connectors() {
    let w = World::new();
    let client = w.client(vec![ok(200, &wrapped(&list_first()))]);
    client.create(&map(json!({"name": "Bare", "connectors": []}))).unwrap();
    let body = w.last().body.unwrap();
    assert_eq!((&body["mcp_connections"], &body["clear_mcp_connections"]), (&json!([]), &json!(true)));

    client.update(ID, &map(json!({"enabled": false, "connectors": null}))).unwrap();
    assert_eq!(w.last().body, Some(json!({"enabled": false, "mcp_connections": [], "clear_mcp_connections": true})));
}

#[test]
fn a_connector_list_is_sent_exactly_without_the_clear_flag() {
    let w = World::new();
    let slack = json!({"connector_uuid": "00000000-0000-4000-8000-000000000002", "name": "Slack", "url": "https://mcp.slack.com/mcp"});
    w.client(vec![ok(200, &wrapped(&list_first()))]).create(&map(json!({"name": "Digest", "connectors": [slack]}))).unwrap();
    let body = w.last().body.unwrap();
    assert_eq!(body["mcp_connections"], json!([slack]));
    assert!(body.get("clear_mcp_connections").is_none());
}

#[test]
fn updating_the_prompt_sends_the_whole_job_config() {
    let w = World::new();
    let routine = list_first();
    let fields = rc::fields(&routine).unwrap();
    let mut job = Map::new();
    for key in ["prompt", "model", "sources", "allowed_tools", "environment_id"] {
        job.insert(key.into(), fields[key].clone());
    }
    job.insert("prompt".into(), json!("New prompt"));
    w.client(vec![ok(200, &wrapped(&routine))]).update(ID, &job).unwrap();
    let body = w.last().body.unwrap();
    assert_eq!(body.as_object().unwrap().keys().collect::<Vec<_>>(), ["job_config"]);
    assert_eq!(body["job_config"]["ccr"]["events"][0]["data"]["message"]["content"], "New prompt");
    assert_eq!(body["job_config"]["ccr"]["session_context"], routine["job_config"]["ccr"]["session_context"]);
}

#[test]
fn a_bare_routine_is_still_read_and_anything_else_is_a_bad_shape() {
    let w = World::new();
    let routine = list_first();
    assert_eq!(w.client(vec![ok(200, &routine.to_string())]).get(ID).unwrap(), routine);
    for answer in [r#"{"trigger":"trig_x"}"#, r#"{"trigger":{"name":"no id"}}"#, "{}", "[]"] {
        let error = w.client(vec![ok(200, answer)]).get(ID).unwrap_err();
        assert_eq!((error.class, error.message.as_str()), (rc::BAD_SHAPE, "routines API answered a routine without an id"), "{answer}");
    }
}

#[test]
fn runs_tolerate_missing_fields_and_link_to_claude_ai() {
    let w = World::new();
    let sessions = json!({"data": [{"id": "cse_1", "title": "Digest", "status": "completed", "created_at": "2026-11-05T07:10:10Z", "updated_at": "2026-11-05T07:10:47Z"}, {"id": "cse_2"}]});
    let runs = w.client(vec![ok(200, &sessions.to_string())]).runs(ID, 1).unwrap();
    assert_eq!(w.last().url, format!("https://api.anthropic.com/v1/code/sessions?trigger_id={ID}&limit=1"));
    assert_eq!(runs, vec![json!({"id": "cse_1", "title": "Digest", "status": "completed", "created_at": "2026-11-05T07:10:10Z", "updated_at": "2026-11-05T07:10:47Z", "url": "https://claude.ai/code/cse_1"})]);
    assert_eq!(rc::routine_url(ID), format!("https://claude.ai/code/routines/{ID}"));
    let both = w.client(vec![ok(200, &sessions.to_string())]).runs(ID, 10).unwrap();
    assert_eq!(both[1], json!({"id": "cse_2", "title": null, "status": null, "created_at": null, "updated_at": null, "url": "https://claude.ai/code/cse_2"}));
}

#[test]
fn delete_reports_unsupported_on_404_or_405() {
    let w = World::new();
    assert_eq!(w.client(vec![ok(200, "{}")]).delete(ID).unwrap(), Deleted::Deleted);
    assert_eq!(w.client(vec![ok(404, "{}")]).delete(ID).unwrap(), Deleted::Unsupported);
    let request = w.last();
    assert_eq!((request.method.as_str(), request.url.as_str()), ("DELETE", format!("https://api.anthropic.com/v1/code/triggers/{ID}").as_str()));
    assert_eq!(w.client(vec![ok(405, "")]).delete(ID).unwrap(), Deleted::Unsupported);
}

#[test]
fn errors_are_typed_with_user_facing_messages() {
    let w = World::new();
    let expired = w.client(vec![ok(401, "{}")]).list().unwrap_err();
    assert_eq!((expired.class, expired.message.as_str()), (rc::TOKEN_EXPIRED, "Claude Code's login token expired — open any Claude Code session, then refresh"));
    let changed = w.client(vec![ok(404, "{}")]).list().unwrap_err();
    assert_eq!((changed.class, changed.message.as_str()), (rc::API_CHANGED, "routines API changed — check the `ccr-triggers-*` beta in the claude binary"));
    let created = w.client(vec![ok(404, "{}")]).create(&map(json!({"name": "x"}))).unwrap_err();
    assert_eq!((created.class, created.message), (rc::API_CHANGED, changed.message));
    for answer in ["<html>", r#"{"items":[]}"#, r#"{"data":[1]}"#] {
        assert_eq!(w.client(vec![ok(200, answer)]).list().unwrap_err().class, rc::BAD_SHAPE, "{answer}");
    }
    let down = w.client(vec![Err("curl: (6) Could not resolve host".into())]).list().unwrap_err();
    assert_eq!(down.class, rc::NETWORK);
    assert!(down.message.contains("api.anthropic.com"), "{}", down.message);
    let other = w.client(vec![ok(500, r#"{"error":{"message":"boom"}}"#)]).list().unwrap_err();
    assert_eq!(other.class, rc::ERROR);
    assert!(other.message.contains("500") && other.message.contains("boom"), "{}", other.message);
}

#[test]
fn a_404_on_one_routine_means_it_is_missing() {
    let w = World::new();
    let calls: Vec<(&str, Box<dyn Fn(&RoutinesClient) -> Result<(), quartermaster::error::QmError>>)> = vec![
        ("get", Box::new(|c| c.get(ID).map(|_| ()))),
        ("update", Box::new(|c| c.update(ID, &map(json!({"enabled": false}))).map(|_| ()))),
        ("run", Box::new(|c| c.run(ID).map(|_| ()))),
        ("runs", Box::new(|c| c.runs(ID, 10).map(|_| ()))),
    ];
    for (name, call) in calls {
        let missing = call(&w.client(vec![ok(404, "{}")])).unwrap_err();
        assert_eq!(missing.class, rc::ROUTINE_MISSING, "{name}");
        assert_eq!(missing.message, format!("routine {ID} isn't on claude.ai any more — delete the automation in qm"));
        assert!(!missing.message.contains(TOKEN));
    }
}

#[test]
fn off_by_default_and_then_the_keychain_is_never_read() {
    let w = World::new();
    let error = w.client_with(vec![ok(200, LIST)], credentials(3_600_000), true, None).list().unwrap_err();
    assert_eq!((error.class, error.message.as_str()), (rc::NOT_ENABLED, "automations are off: run `qm config set automations.token_source claude_code`"));
    assert_eq!(*w.keychain_calls.borrow(), 0);
    assert!(w.requests.borrow().is_empty());
    let other = w.client_with(vec![ok(200, LIST)], credentials(3_600_000), true, Some("api_key")).list().unwrap_err();
    assert_eq!(other.class, rc::NOT_ENABLED);
}

#[test]
fn a_missing_or_expired_login_fails_before_any_request() {
    let w = World::new();
    assert_eq!(w.client_with(vec![ok(200, LIST)], String::new(), false, Some("claude_code")).list().unwrap_err().class, rc::TOKEN_EXPIRED);
    assert_eq!(w.client_with(vec![ok(200, LIST)], "not json".into(), true, Some("claude_code")).list().unwrap_err().class, rc::TOKEN_EXPIRED);
    assert_eq!(w.client_with(vec![ok(200, LIST)], credentials(-1000), true, Some("claude_code")).list().unwrap_err().class, rc::TOKEN_EXPIRED);
    std::fs::write(w.claude_json(), "{}").unwrap();
    assert_eq!(w.client(vec![ok(200, LIST)]).list().unwrap_err().class, rc::TOKEN_EXPIRED);
    std::fs::remove_file(w.claude_json()).unwrap();
    assert_eq!(w.client(vec![ok(200, LIST)]).list().unwrap_err().class, rc::TOKEN_EXPIRED);
    assert!(w.requests.borrow().is_empty());
}

#[test]
fn the_token_never_reaches_an_error_message() {
    let w = World::new();
    let answers: Vec<Answer> = vec![ok(401, "{}"), ok(404, "{}"), ok(500, &format!(r#"{{"error":{{"message":"bad Bearer {TOKEN}"}}}}"#)), ok(200, "nope"), Err(format!("connection refused, Bearer {TOKEN}"))];
    for answer in answers {
        let error = w.client(vec![answer]).list().unwrap_err();
        assert!(!error.message.contains(TOKEN) && !error.message.contains("REFRESH"), "{}", error.message);
    }
}
