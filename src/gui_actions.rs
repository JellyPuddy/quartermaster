//! `POST /api/action`, ported command by command (`GuiActions#dispatch`). A command not ported yet
//! answers `None` (the server says 501) before anything is read or written, so a half-ported action
//! never runs; a value whose Ruby behavior this port does not reproduce does the same.

use std::sync::Mutex;

use serde_json::{json, Map, Value};

use crate::attention::Attention;
use crate::data_root;
use crate::error::{QmError, UNEMITTABLE};
use crate::note::DEFAULT_NOTE_KIND;
use crate::ruby_text::strip;
use crate::work_item::{WorkItem, STATES};

/// Ruby runs actions under one mutex.
static ACTION_LOCK: Mutex<()> = Mutex::new(());

/// Every command Ruby's dispatcher knows, ported or not: the rest are `unknown action`.
const KNOWN: &[&str] = &[
    "resume", "resume-session", "start", "state", "move", "note", "retag", "describe", "retitle", "pr", "distill", "snooze", "ack", "new", "attach", "detach",
    "item-from-session", "dismiss", "work-on", "pf-switch", "ide", "terminal", "adopt", "restack", "pf-stop", "pf-mode", "run-update", "pane-start", "pane-resume",
    "pane-warp", "rotate", "aside-open", "aside-close", "aside-promote", "aside-reopen", "page-annotations", "drafts-load", "diff-viewed", "draft-put", "draft-move",
    "review-post", "thread-reply-put", "pr-thread-resolve", "review-preview", "draft-place", "issue-comment-put", "draft-edit", "draft-delete", "drafts-discard",
    "drafts-send", "issues-clear-created", "issue-acknowledge", "issues-create", "build-progress", "branch-stats-commentary", "board-answer", "issue-preview",
    "issue-start", "pr-chat", "pr-review", "pr-pf", "pr-ide", "pr-unrequire", "cleanup", "caffeinate", "benchmark-start", "benchmark-cancel", "benchmark-rerun",
    "loose-start", "loose-close", "loose-promote",
];

type R<T> = Result<T, Stop>;

/// Either the action's own refusal (a JSON reply) or "Ruby's job".
pub(crate) enum Stop {
    Reply(Value),
    Unported,
}

pub(crate) fn fail(message: impl Into<String>) -> Stop {
    Stop::Reply(json!({"ok": false, "error": message.into()}))
}

/// What `Ruby ... rescue` makes of an error: ArgumentError is the user's, the rest also lands in qm.log.
impl Stop {
    pub(crate) fn refuse(message: impl Into<String>) -> Stop {
        fail(message)
    }
}

fn error(e: QmError) -> Stop {
    if e.class == UNEMITTABLE {
        return Stop::Unported;
    }
    if e.class != "ArgumentError" {
        data_root::log_error("gui-action", e.class, &e.message);
    }
    fail(e.message)
}

pub(crate) fn ok() -> Value {
    json!({"ok": true})
}

/// `value.to_s` for the scalars a page sends; anything else is left to Ruby.
fn to_s(v: &Value) -> R<String> {
    match v {
        Value::Null => Ok(String::new()),
        Value::String(s) => Ok(s.clone()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Number(n) if n.is_i64() || n.is_u64() => Ok(n.to_string()),
        _ => Err(Stop::Unported),
    }
}

struct Args<'a>(Option<&'a Map<String, Value>>);

impl Args<'_> {
    fn get(&self, key: &str) -> R<&Value> {
        static NULL: Value = Value::Null;
        match self.0 {
            Some(m) => Ok(m.get(key).unwrap_or(&NULL)),
            None => Err(Stop::Unported),
        }
    }
    fn text(&self, key: &str) -> R<String> {
        to_s(self.get(key)?)
    }
    /// A string the action passes on as it is (nil and other types behave differently in Ruby).
    fn string(&self, key: &str) -> R<String> {
        match self.get(key)? {
            Value::String(s) => Ok(s.clone()),
            _ => Err(Stop::Unported),
        }
    }
}

fn find(slug: &str) -> R<WorkItem> {
    WorkItem::find(slug).map_err(error)
}

/// `Some(reply)`, or `None` when the command is not ported (or not as this input).
pub fn dispatch(payload: &Value) -> Option<Value> {
    let _guard = ACTION_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    match run(payload) {
        Ok(v) => Some(v),
        Err(Stop::Reply(v)) => Some(v),
        Err(Stop::Unported) => None,
    }
}

fn run(payload: &Value) -> R<Value> {
    let empty = Map::new();
    let obj = match payload {
        Value::Object(o) => o,
        Value::String(_) => &empty,
        Value::Array(_) | Value::Number(_) if payload.is_array() || payload.as_i64().is_some() || payload.as_u64().is_some() => {
            let message = "no implicit conversion of String into Integer";
            data_root::log_error("gui-action", "TypeError", message);
            return Err(fail(message));
        }
        _ => return Err(Stop::Unported),
    };
    let cmd = match obj.get("cmd") {
        None | Some(Value::Null) => String::new(),
        Some(v) => to_s(v)?,
    };
    let known = matches!(obj.get("cmd"), Some(Value::String(_))) && KNOWN.contains(&cmd.as_str());
    if !known {
        return Err(fail(format!("unknown action '{cmd}'")));
    }
    let slug = match obj.get("slug") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(_) => return Err(Stop::Unported),
    };
    let args = match obj.get("args") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => Args(Some(&empty)),
        Some(Value::Object(o)) => Args(Some(o)),
        Some(_) => Args(None),
    };
    match cmd.as_str() {
        "note" => note(&slug, &args),
        "retag" => retag(&slug, &args),
        "describe" => {
            let text = args.text("text")?;
            find(&slug)?.describe(&text).map_err(error)?;
            Ok(ok())
        }
        "retitle" => {
            let title = strip(&args.text("title")?).to_string();
            if title.is_empty() {
                return Err(fail("title is empty"));
            }
            find(&slug)?.retitle(&title).map_err(error)?;
            Ok(ok())
        }
        "move" => {
            let mut item = find(&slug)?;
            item.move_to(&args.string("project")?).map_err(error)?;
            Ok(ok())
        }
        "state" => state(&slug, &args),
        "snooze" => {
            let mut item = find(&slug)?;
            let duration = match args.get("duration")? {
                Value::String(s) => s.clone(),
                other => to_s(other)?,
            };
            item.snooze(&duration).map_err(error)?;
            Ok(ok())
        }
        "ack" => {
            let mut item = find(&slug)?;
            let ids = Attention::new(std::time::SystemTime::now()).acknowledge_all(&mut item, None).map_err(error)?;
            Ok(json!({"ok": true, "acked": ids.len()}))
        }
        "detach" => {
            let mut item = find(&slug)?;
            let session = match args.get("session")? {
                Value::Null => return Ok(Value::Bool(false)),
                Value::String(s) => s.clone(),
                _ => return Err(Stop::Unported),
            };
            // Ruby answers `false` itself when nothing was attached
            Ok(if item.detach_session(&session).map_err(error)? { ok() } else { Value::Bool(false) })
        }
        "diff-viewed" => {
            let item = find(&slug)?;
            let slug = item.slug.clone();
            if !slug_shaped(&slug) {
                return Err(fail(format!("'{slug}' is not a work item slug")));
            }
            let viewed = matches!(args.get("viewed")?, Value::Bool(true));
            match crate::viewed_marks::set(&slug, args.get("path")?, args.get("digest")?, viewed) {
                Ok(v) => Ok(json!({"ok": true, "viewed": v})),
                Err(crate::viewed_marks::Halt::Refuse(m)) => Err(fail(m)),
                Err(crate::viewed_marks::Halt::Unported) => Err(Stop::Unported),
            }
        }
        "issue-acknowledge" | "issues-clear-created" => {
            let item = find(&slug)?;
            let slug = item.slug.clone();
            if !slug_shaped(&slug) {
                return Err(fail(format!("'{slug}' is not a work item slug")));
            }
            issues(&cmd, &slug, &args)
        }
        "pane-start" | "pane-resume" => pane(&slug, cmd == "pane-start", &args),
        "pf-mode" => {
            let mut item = find(&slug)?;
            item.update_pf_mode(&args.text("mode")?).map_err(error)?;
            Ok(ok())
        }
        "draft-edit" | "draft-delete" | "drafts-discard" | "draft-put" | "draft-move" => drafts(&cmd, &slug, &args),
        _ => Err(Stop::Unported),
    }
}

fn issues(cmd: &str, slug: &str, args: &Args) -> R<Value> {
    use crate::issue_drafts as i;
    if cmd == "issue-acknowledge" {
        let name = match args.get("file")? {
            Value::String(s) => s.clone(),
            other => {
                to_s(other)?;
                return Err(fail(format!("'{}' is not an issue file", to_s(other)?)));
            }
        };
        if !i::is_issue_file(&name) {
            return Err(fail(format!("'{name}' is not an issue file")));
        }
        let acknowledged = i::acknowledge(slug, &name).map_err(|_| Stop::Unported)?;
        return Ok(json!({"ok": true, "acknowledged": acknowledged}));
    }
    if !crate::drafts::writable(slug) {
        return Err(Stop::Unported);
    }
    let loaded = i::load(slug).ok_or(Stop::Unported)?;
    loaded.record().map_err(|_| Stop::Unported)?;
    let created: Vec<String> = loaded.issues.iter().filter(|x| x.number.is_some()).map(|x| x.file.clone()).collect();
    for name in &created {
        i::delete(slug, name).map_err(|_| Stop::Unported)?;
    }
    Ok(json!({"ok": true, "cleared": created}))
}

/// `gui_pane`: the item's chat in a tmux session of its own — already running is `attached`, a live
/// session outside the GUI refuses, else Start or Resume opens it.
fn pane(slug: &str, fresh: bool, args: &Args) -> R<Value> {
    let item = find(slug)?;
    let tmux = crate::tmux::Tmux::new();
    if tmux.live(slug) {
        return Ok(json!({"ok": true, "attached": true}));
    }
    let session = if fresh {
        None
    } else {
        let given = args.text("session")?;
        (!strip(&given).is_empty()).then_some(given)
    };
    let plan = crate::launcher::chat_plan(&item, fresh, session.as_deref()).ok_or(Stop::Unported)?;
    if matches!(plan.mode, crate::launcher::Mode::Live) {
        return Err(fail(format!("{slug} has a chat running outside the GUI — take it over here once it ends")));
    }
    match tmux.open(slug, &plan.cwd, &plan.argv, &plan.env) {
        Ok(_) => Ok(json!({"ok": true, "mode": plan.mode.name()})),
        Err(message) => Err(fail(message)),
    }
}

fn slug_shaped(slug: &str) -> bool {
    slug.chars().next().is_some_and(|c| c.is_ascii_alphanumeric()) && slug.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

/// The draft actions open the item first (`drafts_of`), then its drafts, whose slug must be a slug.
fn drafts(cmd: &str, slug: &str, args: &Args) -> R<Value> {
    let item = find(slug)?;
    let slug = item.slug.clone();
    if !slug_shaped(&slug) {
        return Err(fail(format!("'{slug}' is not a work item slug")));
    }
    use crate::gui_draft_actions as d;
    match cmd {
        "draft-edit" => d::edit(&slug, &args.text("id")?, args.get("comment")?),
        "draft-delete" => d::delete(&slug, &args.text("id")?),
        "drafts-discard" => d::discard(&slug, args.get("ids")?),
        "draft-move" => d::move_to(&slug, &args.text("id")?, args.get("to")?),
        _ => match args.0 {
            Some(raw) => d::put(&slug, raw),
            None => Err(Stop::Unported),
        },
    }
}

fn note(slug: &str, args: &Args) -> R<Value> {
    let text = strip(&args.text("text")?).to_string();
    if text.is_empty() {
        return Err(fail("note text is empty"));
    }
    let kind = match args.get("kind")? {
        Value::Null => DEFAULT_NOTE_KIND.to_string(),
        Value::String(s) if s.is_empty() => DEFAULT_NOTE_KIND.to_string(),
        Value::String(s) => s.clone(),
        _ => return Err(Stop::Unported),
    };
    find(slug)?.add_note(&text, &kind).map_err(error)?;
    Ok(ok())
}

fn retag(slug: &str, args: &Args) -> R<Value> {
    let mut item = find(slug)?;
    let position = match args.get("position")? {
        Value::Null => 0,
        Value::Number(n) => n.as_u64().ok_or(Stop::Unported)? as usize,
        Value::String(s) if s == "0" || (s.starts_with(|c: char| ('1'..='9').contains(&c)) && s.bytes().all(|c| c.is_ascii_digit())) => s.parse().map_err(|_| Stop::Unported)?,
        _ => return Err(Stop::Unported),
    };
    let kind = args.string("kind")?;
    item.update_note_kind(position, &kind).map_err(error)?;
    Ok(ok())
}

fn state(slug: &str, args: &Args) -> R<Value> {
    let mut item = find(slug)?;
    let state = match args.get("state")? {
        Value::String(s) => s.clone(),
        _ => return Err(fail(format!("state must be one of: {}", STATES.join(", ")))),
    };
    if state == "resolved" && crate::cleanup_command::leaves_to_ruby(&item.slug) {
        return Err(Stop::Unported); // the plan lists issue drafts, and only Ruby reads some of those
    }
    item.update_state(&state).map_err(error)?;
    if state != "resolved" {
        return Ok(ok());
    }
    // the plan is the page's offer to clean up: a failing plan must never fail the resolve
    let plan = match crate::cleanup::plan_item(&item) {
        Ok(plan) => plan,
        Err(e) => {
            data_root::log_error("cleanup-offer", e.class, &e.message);
            return Ok(ok());
        }
    };
    if plan.is_empty() {
        return Ok(ok());
    }
    let mut reply = ok();
    reply.as_object_mut().unwrap().insert("cleanup".into(), plan_payload(&plan));
    Ok(reply)
}

/// `Cleanup::Plan#to_h` with each entry's path also shown short, as the dialog prints it.
pub(crate) fn plan_payload(plan: &crate::cleanup::Plan) -> Value {
    let entries: Vec<Value> = plan
        .entries
        .iter()
        .map(|e| {
            let mut m = Map::new();
            m.insert("id".into(), json!(e.id));
            m.insert("kind".into(), json!(e.kind));
            m.insert("repo".into(), json!(e.repo));
            m.insert("path".into(), json!(e.path));
            m.insert("branch".into(), json!(e.branch));
            m.insert("item".into(), json!(e.item));
            m.insert("status".into(), json!(e.status));
            m.insert("reasons".into(), json!(e.reasons));
            m.insert("notes".into(), json!(e.notes));
            m.insert("ticked".into(), json!(e.ticked));
            m.insert("db_names".into(), json!(e.db_names));
            m.insert("db_status".into(), if e.is_worktree() { json!(e.db_status) } else { Value::Null });
            m.insert("requires".into(), json!(e.requires));
            m.insert("title".into(), json!(e.title));
            if let Some(path) = &e.path {
                m.insert("short".into(), json!(crate::cli_format::short_path(Some(path))));
            }
            Value::Object(m)
        })
        .collect();
    json!({"scope": plan.scope, "summary": plan.summary(), "notes": plan.notes, "entries": entries})
}
