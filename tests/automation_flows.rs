//! The flows a local automation's run takes. tmux is the real one on a throwaway socket, claude a stand-in
//! recording its arguments and gh a stand-in on PATH, so the argv and env each flow hands tmux is what's
//! asserted.

mod common;
use common::chat::*;
use quartermaster::automation_flows::{self as flows, FlowError, Reply};
use quartermaster::automation_store::{Entry, Record};
use quartermaster::chat_flow;
use quartermaster::pr_review_start;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

const SID: &str = "11111111-2222-3333-4444-555555555555";
const URL: &str = "https://github.com/acme/WebApp/pull/42";

fn pr() -> Value {
    json!({"url": URL, "number": 42, "title": "Add the thing", "repo": "acme/WebApp", "author": "someone", "head": "feature-x", "base": "main"})
}

fn entry(record: Value) -> Entry {
    let mut full: Record = json!({"runner": "local"}).as_object().unwrap().clone();
    full.extend(record.as_object().unwrap().clone());
    Entry { slug: "nightly-triage".into(), record: full, prompt: "Triage the inbox.\n".into() }
}

fn review() -> Value {
    json!({"flow": "pr-review", "repos": ["acme/WebApp"]})
}

fn merged(base: Value, more: Value) -> Value {
    let mut map = base.as_object().unwrap().clone();
    map.extend(more.as_object().unwrap().clone());
    Value::Object(map)
}

fn cache_prs(world: &ChatWorld, prs: Vec<Value>) {
    std::fs::write(world.root().join("pr-inbox.json"), json!({"prs": prs, "ts": chrono::Utc::now().timestamp()}).to_string()).unwrap();
}

fn start(entry: &Entry, item: &Value, prompt: &str) -> Result<Reply, FlowError> {
    flows::start(entry, item, prompt, "r1", SID)
}

fn home() -> String {
    std::env::var("HOME").unwrap()
}

fn item(key: &str) -> Value {
    json!({"key": key, "url": key})
}

#[test]
fn a_chat_run_opens_its_own_tmux_session_with_the_session_id_flags_and_prompt_last() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    let cwd = tempfile::tempdir().unwrap();
    let record = json!({"flow": "chat", "cwd": cwd.path(), "model": "sonnet", "permission_mode": "acceptEdits", "allowed_tools": ["Bash(gh:*)", "Read"]});
    let reply = flows::start(&entry(record), &Value::Null, "Triage the inbox.\n", "ab12cd34", SID).unwrap();
    assert_eq!(reply, Reply::Started { item_slug: "nightly-triage".into(), tmux: "nightly-triage--run-ab12cd34".into() });
    let started = &world.wait_started(1)[0];
    assert_eq!(world.sessions(), ["nightly-triage--run-ab12cd34"]);
    assert_eq!(started.item, "nightly-triage");
    assert_eq!(std::fs::canonicalize(&started.cwd).unwrap(), std::fs::canonicalize(cwd.path()).unwrap());
    assert_eq!(started.args, ["--session-id", SID, "--model", "sonnet", "--permission-mode", "acceptEdits", "--allowedTools=Bash(gh:*),Read", "Triage the inbox.\n"]);
}

#[test]
fn a_chat_run_without_flags_passes_only_the_session_id() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    start(&entry(json!({"cwd": home()})), &Value::Null, "Go.").unwrap();
    assert_eq!(world.wait_started(1)[0].args, ["--session-id", SID, "Go."]);
}

#[test]
fn a_chat_run_honours_the_chat_command_swap() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    let standin = std::env::var("QM_CHAT_COMMAND").unwrap();
    std::env::set_var("QM_CHAT_COMMAND", format!("{standin} --model haiku"));
    start(&entry(json!({"cwd": home()})), &Value::Null, "Go.").unwrap();
    assert_eq!(world.wait_started(1)[0].args, ["--model", "haiku", "--session-id", SID, "Go."]);
}

#[test]
fn a_chat_run_starts_in_the_automations_project_root_by_default() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, repo) = with_webapp("flows");
    WorkItem::create("Nightly triage", "WebApp", None, None, None, None).unwrap();
    start(&entry(json!({})), &Value::Null, "Go.").unwrap();
    assert_eq!(std::fs::canonicalize(&world.wait_started(1)[0].cwd).unwrap(), std::fs::canonicalize(repo).unwrap());
}

#[test]
fn a_chat_run_without_a_project_starts_at_home() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    start(&entry(json!({})), &Value::Null, "Go.").unwrap();
    assert_eq!(std::fs::canonicalize(&world.wait_started(1)[0].cwd).unwrap(), std::fs::canonicalize(home()).unwrap());
}

#[test]
fn a_json_item_is_appended_pretty_printed_under_an_item_heading() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    start(&entry(json!({"cwd": home()})), &json!({"key": "issue-7", "title": "Crash on save"}), "Fix it.\n").unwrap();
    assert_eq!(world.wait_started(1)[0].args.last().unwrap(), "Fix it.\n\n## Item\n\n{\n  \"key\": \"issue-7\",\n  \"title\": \"Crash on save\"\n}");
}

#[test]
fn a_plain_guard_line_is_appended_as_the_line() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    start(&entry(json!({"cwd": home()})), &json!({"key": "logs/a.txt", "line": "logs/a.txt"}), "Read it.").unwrap();
    assert_eq!(world.wait_started(1)[0].args.last().unwrap(), "Read it.\n\n## Item\n\nlogs/a.txt");
}

#[test]
fn a_json_item_that_only_looks_like_a_plain_line_stays_json() {
    let item = json!({"key": "k1", "line": "something else"});
    assert_eq!(chat_flow::prompt_with_item("Go.", &item), "Go.\n\n## Item\n\n{\n  \"key\": \"k1\",\n  \"line\": \"something else\"\n}");
    assert_eq!(chat_flow::prompt_with_item("Go.", &Value::Null), "Go.");
    assert_eq!(chat_flow::prompt_with_item("", &json!({"key": "a", "line": "a"})), "## Item\n\na", "the leading blank lines of an empty prompt go");
}

#[test]
fn a_run_whose_tmux_session_already_runs_fails() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    assert!(world.tmux(&["new-session", "-d", "-s", "nightly-triage--run-r1", "sleep", "60"]).0);
    let error = start(&entry(json!({"cwd": home()})), &Value::Null, "Go.").unwrap_err();
    assert!(error.message().contains("already running"), "{}", error.message());
    assert!(world.started().is_empty());
}

#[test]
fn problem_checks_the_item_against_the_flows_needs() {
    assert_eq!(flows::problem(Some("chat"), &Value::Null), None);
    assert_eq!(flows::problem(None, &json!({"key": "x"})), None);
    assert_eq!(flows::problem(Some("pr-review"), &json!({"key": "pr", "url": URL})), None);
    let lacks = Some("item \"pr\" lacks url, which the pr-review flow needs".to_string());
    assert_eq!(flows::problem(Some("pr-review"), &json!({"key": "pr"})), lacks);
    assert_eq!(flows::problem(Some("pr-review"), &json!({"key": "pr", "url": " "})), lacks);
    assert_eq!(flows::problem(Some("pr-review"), &Value::Null).as_deref(), Some("a run without an item lacks url, which the pr-review flow needs"));
    assert_eq!(flows::problem(Some("branch-stats"), &Value::Null).as_deref(), Some("unknown flow \"branch-stats\" (chat, pr-review)"));
}

#[test]
fn start_refuses_an_item_the_flow_cant_take() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    let error = start(&entry(json!({"flow": "pr-review"})), &json!({"key": "x"}), "").unwrap_err();
    assert!(error.message().contains("lacks url"), "{}", error.message());
    assert!(world.sessions().is_empty());
}

#[test]
fn start_refuses_a_hand_edited_yml_with_bypass_permissions() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let world = ChatWorld::new("flows");
    let error = start(&entry(json!({"cwd": home(), "permission_mode": "bypassPermissions"})), &Value::Null, "Go.").unwrap_err();
    assert!(error.message().contains("bypassPermissions is refused"), "{}", error.message());
    assert!(world.sessions().is_empty());
}

#[test]
fn a_pr_review_run_opens_the_review_items_chat_with_flags_and_the_prompt_as_extra_instructions() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, repo) = with_webapp("flows");
    cache_prs(&world, vec![pr()]);
    let reply = start(&entry(merged(review(), json!({"model": "opus"}))), &item(URL), "Focus on the migrations.").unwrap();
    let slug = "review-webapp-42-add-the-thing";
    assert_eq!(reply, Reply::Started { item_slug: slug.into(), tmux: slug.into() });
    let started = &world.wait_started(1)[0];
    assert_eq!(world.sessions(), [slug]);
    assert_eq!(started.args[..4], ["--session-id", SID, "--model", "opus"]);
    let parts: Vec<&str> = started.args[4].split("\n\n").collect();
    assert_eq!(parts[0], format!("/review-app-pr {URL}"));
    assert!(parts[1].contains(&format!("qm draft add {slug}")));
    assert_eq!(parts[2], "Focus on the migrations.");
    assert_eq!(started.item, slug);
    assert_eq!(std::fs::canonicalize(&started.cwd).unwrap(), std::fs::canonicalize(repo).unwrap());
    assert!(world.gh_calls().is_empty(), "a cached PR needs no gh call");
}

#[test]
fn a_pr_review_run_waits_while_the_review_chat_is_open() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("flows");
    cache_prs(&world, vec![pr()]);
    let slug = pr_review_start::item_for(&pr()).unwrap().slug;
    assert!(world.tmux(&["new-session", "-d", "-s", &slug, "sleep", "60"]).0);
    let reply = start(&entry(review()), &item(URL), "").unwrap();
    assert_eq!(reply, Reply::Waiting("Review chat for WebApp#42 is open".into()));
    assert!(world.started().is_empty());
}

#[test]
fn a_pr_review_run_fetches_a_pr_the_inbox_doesnt_hold() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("flows");
    cache_prs(&world, vec![]);
    let view = json!({"number": 42, "title": "Add the thing", "url": URL, "headRefName": "feature-x", "baseRefName": "main", "author": {"login": "someone"}});
    world.gh(&view.to_string(), "", 0);
    let reply = start(&entry(review()), &item(URL), "").unwrap();
    assert_eq!(world.gh_calls(), [["pr", "view", URL, "--json", "number,title,url,headRefName,baseRefName,author"]]);
    let Reply::Started { item_slug, .. } = reply else { panic!("{reply:?}") };
    assert_eq!(item_slug, "review-webapp-42-add-the-thing");
    assert!(WorkItem::find(&item_slug).unwrap().description().contains("by @someone: `feature-x` → `main`"));
}

#[test]
fn a_pr_review_run_refuses_a_repo_its_automation_doesnt_list() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("flows");
    cache_prs(&world, vec![pr()]);
    world.gh("", "", 0);
    for record in [json!({"flow": "pr-review"}), json!({"flow": "pr-review", "repos": ["acme/other"]})] {
        let error = start(&entry(record), &item(URL), "").unwrap_err();
        assert!(matches!(error, FlowError::Refused(_)));
        assert!(error.message().contains("repo acme/WebApp isn't in this automation's repos"), "{}", error.message());
    }
    assert!(world.sessions().is_empty() && world.gh_calls().is_empty());
}

#[test]
fn refusal_matches_repos_case_insensitively_and_refuses_a_non_pr_url() {
    let record = entry(json!({"repos": ["ACME/webapp"]})).record;
    assert_eq!(flows::refusal(Some("pr-review"), &record, &json!({"key": "k", "url": URL})), None);
    assert_eq!(flows::refusal(Some("pr-review"), &record, &json!({"key": "k", "url": "https://github.com/acme"})).as_deref(), Some("\"https://github.com/acme\" isn't a GitHub pull request URL"));
    assert_eq!(flows::refusal(Some("chat"), &Record::new(), &json!({"key": "k"})), None);
    assert_eq!(flows::refusal(Some("pr-review"), &Record::new(), &json!({"key": "k", "url": URL})).as_deref(), Some("repo acme/WebApp isn't in this automation's repos (it has no repos list)"));
}

#[test]
fn a_pr_gh_cant_find_fails_the_run() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (world, _) = with_webapp("flows");
    cache_prs(&world, vec![]);
    world.gh("", "no pull requests found", 1);
    let error = start(&entry(review()), &item(URL), "").unwrap_err();
    assert!(matches!(error, FlowError::Other(_)) && error.message().contains("no pull requests found"), "{}", error.message());
    assert!(world.sessions().is_empty());
}

#[test]
fn flags_join_allowed_tools_into_one_value() {
    let record = entry(json!({"allowed_tools": ["A", "B(x:*)"]})).record;
    assert_eq!(flows::flags(&record, "sid"), ["--session-id", "sid", "--allowedTools=A,B(x:*)"]);
}
