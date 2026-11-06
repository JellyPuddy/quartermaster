//! The `/api/state` payload: every item as the board and chat view render it, the inbox, the chat
//! view's attention list, the dev server and the sessions' tmux panes. A port of `GuiState#build`
//! for a GUI that has no jobs, notifier or caffeinate child of its own yet. What belongs to parts
//! not ported — status boards, benchmarks, loose chats, build progress — is empty when the data
//! says it would be empty in Ruby, and `Unported` (a 501) when it would not.

use std::sync::Mutex;

use serde_json::{json, Map, Value};

use crate::attention::Attention;
use crate::chat_attention::ChatAttention;
use crate::cli_format::short_path;
use crate::data_root;
use crate::drafts;
use crate::item_usage::{dollars, human_tokens, ItemUsage};
use crate::issue_drafts;
use crate::pr_status::PrStatus;
use crate::price_table::PriceTable;
use crate::ruby_num::Num;
use crate::session_log::{Session, SessionLog};
use crate::usage_ledger::UsageLedger;
use crate::work_item::WorkItem;

pub struct Unported;
type R<T> = Result<T, Unported>;

const MAINLINE: [&str; 3] = ["main", "master", "develop"];

/// The working or blocked chats' transcripts of the last build: the pulse watches their sizes.
static MID_TURN: Mutex<Vec<String>> = Mutex::new(Vec::new());
static LEDGER: Mutex<Option<UsageLedger>> = Mutex::new(None);

fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// `GuiState.relative_when`: "3h ago", a date past ten days; None for what Ruby can't parse.
pub fn relative_when(ts: Option<&str>) -> R<Option<String>> {
    let Some(ts) = ts.filter(|t| !t.is_empty()) else { return Ok(None) };
    let Some(then) = crate::clock::parse(ts) else { return Err(Unported) };
    let seconds = crate::clock::now_f64() - crate::clock::parse_f64(ts).unwrap_or(0.0);
    Ok(Some(if seconds < 60.0 {
        "just now".to_string()
    } else if seconds < 3600.0 {
        format!("{}m ago", (seconds / 60.0) as i64)
    } else if seconds < 86_400.0 {
        format!("{}h ago", (seconds / 3600.0) as i64)
    } else {
        let days = (seconds / 86_400.0) as i64;
        if days <= 10 { format!("{days}d ago") } else { then.date_naive().to_string() }
    }))
}

/// `Time.at(seconds).utc.iso8601`.
fn iso(seconds: f64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(seconds.floor() as i64, 0).map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)).unwrap_or_default()
}

/// `Float#round(4)` as Ruby rounds it (half away from zero, corrected for the representation).
fn round4(x: f64) -> f64 {
    let s = 1e4;
    let mut f = (x * s).round();
    if x > 0.0 {
        if (f + 0.5) / s <= x {
            f += 1.0;
        }
    } else if (f - 0.5) / s >= x {
        f -= 1.0;
    }
    f / s
}

fn rounded(n: Num) -> Value {
    match n {
        Num::Int(i) => json!(i as i64),
        Num::Float(f) => serde_json::Number::from_f64(round4(f)).map(Value::Number).unwrap_or(Value::Null),
    }
}

fn real(path: &str) -> std::path::PathBuf {
    data_root::normalize(path)
}

/// The sizes the pulse watches, joined as `GuiState#pulse` joins them.
pub fn pulse() -> String {
    let size = |p: std::path::PathBuf| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
    let mut parts = vec![size(data_root::root().join("events.jsonl")), size(SessionLog::path())];
    parts.extend(MID_TURN.lock().unwrap().iter().map(|p| size(p.into())));
    let mut out: Vec<String> = parts.iter().map(u64::to_string).collect();
    out.extend(["0".to_string(), drafts::signature(), issue_drafts::signature(), "0".to_string()]);
    out.join(":")
}

pub fn events_pulse() -> String {
    let size = std::fs::metadata(data_root::root().join("events.jsonl")).map(|m| m.len()).unwrap_or(0);
    format!("{size}:{}:{}:0", drafts::signature(), issue_drafts::signature())
}

fn config_raw() -> Map<String, Value> {
    let text = std::fs::read_to_string(data_root::config_file()).unwrap_or_default();
    match serde_yaml::from_str::<serde_yaml::Value>(&text) {
        Ok(v) => match serde_json::to_value(v) {
            Ok(Value::Object(m)) => m,
            _ => Map::new(),
        },
        _ => Map::new(),
    }
}

/// `RateLimits#payload`: the account's limits as the status line last wrote them.
fn rate_limits() -> Value {
    let Ok(raw) = std::fs::read_to_string(data_root::root().join("rate-limits.json")) else { return Value::Null };
    let Ok(Value::Object(doc)) = serde_json::from_str::<Value>(&raw) else { return Value::Null };
    let when = |v: Option<&Value>| -> Option<String> {
        match v {
            Some(Value::Number(n)) => n.as_f64().map(iso),
            Some(Value::String(s)) => crate::clock::parse_f64(s).map(iso),
            _ => None,
        }
    };
    let Some(captured) = when(doc.get("captured_at")) else { return Value::Null };
    let window = |key: &str| -> Value {
        match doc.get(key) {
            Some(Value::Object(w)) if w.get("used_percentage").is_some_and(Value::is_number) => json!({"usedPercentage": w["used_percentage"], "resetsAt": when(w.get("resets_at"))}),
            _ => Value::Null,
        }
    };
    let (five, seven) = (window("five_hour"), window("seven_day"));
    if five.is_null() && seven.is_null() {
        return Value::Null;
    }
    json!({"fiveHour": five, "sevenDay": seven, "capturedAt": captured})
}

fn pf_payload(status: &Option<crate::pf::Status>, server: Option<&crate::project_config::DevServer>) -> Value {
    let mut payload = match status {
        Some(s) => {
            let root = s.root.clone();
            json!({"mode": s.mode, "root": root, "running": s.running, "switching": s.switching,
                   "worktree": root.as_deref().map(|r| std::path::Path::new(r).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()),
                   "short": root.as_deref().map(|r| short_path(Some(r)))})
        }
        None => json!({"running": false}),
    };
    payload["command"] = json!(server.map(|s| s.command.clone()));
    // a data root that is not the live one is fenced off from the dev server
    let live = data_root::root() == data_root::expand_path("~/.claude/quartermaster");
    if !live {
        payload["off"] = json!(format!("the dev server is off in this GUI: {} is not the live qm data root", short_path(Some(&data_root::root().to_string_lossy()))));
    }
    payload
}

fn same_checkout(path: &str, paths: &[String]) -> bool {
    let target = real(path);
    paths.iter().any(|p| real(p) == target)
}

fn note_json(n: &crate::note::Note) -> Value {
    json!({"stamp": n.stamp, "kind": n.kind, "text": n.text, "position": n.position})
}

/// The issue drafts' summary (`IssueDrafts#summary`), nil without any.
fn issues_payload(item: &WorkItem) -> R<Value> {
    if !issue_drafts::dir(&item.slug).is_dir() {
        return Ok(Value::Null);
    }
    if !issue_drafts::supported(&item.slug) {
        return Err(Unported);
    }
    let names = issue_drafts::files(&item.slug).ok_or(Unported)?;
    if names.is_empty() {
        return Ok(Value::Null);
    }
    let loaded = issue_drafts::load(&item.slug).ok_or(Unported)?;
    loaded.record().map_err(|_| Unported)?;
    let count = loaded.issues.len() + loaded.errors.len();
    if count == 0 {
        return Ok(Value::Null);
    }
    let open = loaded.issues.iter().filter(|i| i.number.is_none()).count();
    let mut ordered: Vec<&issue_drafts::Issue> = loaded.issues.iter().filter(|i| i.number.is_none()).collect();
    ordered.extend(loaded.issues.iter().filter(|i| i.number.is_some()));
    let versions: Map<String, Value> = ordered.iter().map(|i| (i.file.clone(), json!(i.version))).collect();
    Ok(json!({"count": count, "open": open, "errors": loaded.errors.len(), "versions": versions}))
}

fn usage_payload(item: &WorkItem, log: &SessionLog, ledger: &mut UsageLedger, prices: &PriceTable) -> R<Value> {
    let usage = match ItemUsage::for_item(item, log, ledger, prices) {
        Ok(u) => u,
        Err(e) => {
            data_root::log_error("gui-usage", e.class, &e.message);
            return Ok(Value::Null);
        }
    };
    if usage.is_empty() {
        return Ok(Value::Null);
    }
    let mut rows = vec![];
    for r in &usage.rows {
        let models: Map<String, Value> = r.models.iter().map(|(m, n)| (m.clone(), json!(n))).collect();
        rows.push(json!({
            "id": r.id, "aside": r.aside, "when": relative_when(r.when.as_deref())?.unwrap_or_else(|| "—".into()), "known": r.known, "agents": r.agents,
            "tokens": r.tokens, "unpriced": r.unpriced, "models": models,
            "cost": rounded(r.cost), "tokensLabel": human_tokens(r.tokens), "costLabel": dollars(r.cost)
        }));
    }
    Ok(json!({"tokens": usage.tokens(), "cost": rounded(usage.cost()), "lowerBound": usage.lower_bound(), "partial": usage.partial(), "unpriced": usage.unpriced(), "line": usage.line(), "sessions": rows}))
}

struct Context<'a> {
    log: &'a SessionLog,
    attention: &'a Attention,
    live_ids: Vec<String>,
    pf: &'a Option<crate::pf::Status>,
    panes: &'a [String],
    prices: &'a PriceTable,
    aside_counts: Vec<(String, usize)>,
}

fn item_payload(item: &mut WorkItem, c: &Context, ledger: &mut UsageLedger) -> R<Value> {
    if item.board().is_some() {
        return Err(Unported); // the status board's rows are BoardMirror's
    }
    // first, so the payload's branches already include auto-linked ones
    crate::gh_stack::sync(item);
    let config = crate::project_config::ProjectConfig::current();
    let root = crate::project_map::root_for(item.project().as_deref());
    let by_branch = root.as_deref().map(crate::branch_diff::branch_worktrees).unwrap_or_default();
    let branches = item.branches();
    let checkouts: Vec<(String, String)> = branches.iter().filter_map(|b| by_branch.iter().find(|(k, _)| k == b).filter(|(_, p)| std::path::Path::new(p).is_dir()).map(|(k, p)| (k.clone(), p.clone()))).collect();
    let worktrees: Map<String, Value> = checkouts.iter().map(|(b, p)| (b.clone(), json!(short_path(Some(p))))).collect();
    let resolved = item.state().as_deref() == Some("resolved");
    let status = PrStatus::new(crate::clock::now_f64() as i64);
    let own: Vec<String> = branches.iter().filter(|b| !MAINLINE.contains(&b.as_str())).cloned().collect();
    let mut pr_states = Map::new();
    let mut pr_links = Map::new();
    if !resolved {
        for b in &own {
            if let Some(s) = status.state_for(item, b) {
                pr_states.insert(b.clone(), json!(s));
            }
        }
        for b in &own {
            if let Some(l) = status.link_for(item, b) {
                pr_links.insert(b.clone(), Value::Object(l));
            }
        }
    }
    let mut chains = crate::gh_stack::chains(item, &pr_states, &pr_links);
    for chain in &mut chains {
        for layer in chain["layers"].as_array_mut().into_iter().flatten() {
            let wt = layer["branch"].as_str().and_then(|b| worktrees.get(b)).cloned().unwrap_or(Value::Null);
            layer.as_object_mut().unwrap().insert("worktree".into(), wt);
        }
    }
    let mut sessions = vec![];
    for s in c.log.item_sessions(item).map_err(|_| Unported)? {
        sessions.push(json!({"id": s.id, "tier": s.tier(), "when": relative_when(s.last_ts_opt().as_deref())?.unwrap_or_else(|| "—".into()), "prompt": s.first_prompt()}));
    }
    let badges: Vec<Value> = c
        .attention
        .entries_for(item)
        .map_err(|_| Unported)?
        .iter()
        .map(|e| json!({"type": match e.kind { "degrade" => "degrading", "stale" => "stale", _ => "merged" }, "label": e.message}))
        .collect();
    let activity = c.attention.activity_at(item).map_err(|_| Unported)?;
    let updated = chrono::DateTime::from_timestamp(activity.floor() as i64, 0).map(|t| t.with_timezone(&chrono::Local).date_naive().to_string()).unwrap_or_default();
    let ids = item.session_ids();
    let paths: Vec<String> = checkouts.iter().map(|(_, p)| p.clone()).collect();
    let served = c.pf.as_ref().is_some_and(|p| p.running && p.root.as_deref().is_some_and(|r| same_checkout(r, &paths)));
    let served_branch = match c.pf {
        Some(p) if p.running && p.root.is_some() => {
            let target = real(p.root.as_deref().unwrap());
            checkouts.iter().find(|(_, path)| real(path) == target).map(|(b, _)| b.clone())
        }
        _ => None,
    };
    let aside = crate::chats_commands::aside_name(&item.slug);
    let entries = drafts::entries(&item.slug).ok_or(Unported)?;
    let mut out = Map::new();
    // WorkItem#to_h
    for (k, v) in [
        ("slug", json!(item.slug)),
        ("title", json!(item.title())),
        ("state", json!(item.state())),
        ("project", json!(item.project())),
        ("branches", json!(item.branches())),
        ("temp_branches", json!(item.temp_branches())),
        ("issue_number", json!(item.issue_number())),
        ("board", json!(item.board())),
        ("pf_mode", json!(item.pf_mode())),
        ("board_answers_dir", json!(item.board_answers_dir())),
        ("session_ids", json!(ids)),
        ("sessions", json!(item.sessions_count())),
        ("description", json!(item.description())),
        ("notes", Value::Array(item.notes().iter().map(note_json).collect())),
        ("snapshots", Value::Array(item.snapshots())),
        ("updated", json!(updated)),
        ("live", json!(ids.iter().any(|i| c.live_ids.contains(i)))),
        ("badges", Value::Array(badges)),
        ("note", item.headline_note().map(|n| note_json(&n)).unwrap_or(Value::Null)),
        ("injected", json!(item.injectable_notes().iter().map(|n| n.position).collect::<Vec<_>>())),
        ("worktrees", Value::Object(worktrees)),
        ("chains", Value::Array(chains)),
        ("prStates", Value::Object(pr_states)),
        ("benchmarkable", json!(false)),
        ("benchmarked", json!({})),
        ("served", json!(served)),
        ("servedBranch", json!(served_branch)),
        ("pane", json!(c.panes.contains(&item.slug))),
        ("aside", json!(c.panes.contains(&aside))),
        ("asideCount", json!(c.aside_counts.iter().find(|(s, _)| *s == item.slug).map(|(_, n)| *n).unwrap_or(0))),
        ("boardRows", json!([])),
        ("rotations", json!(item.rotation_count())),
        ("sessionList", Value::Array(sessions)),
        ("usage", usage_payload(item, c.log, ledger, c.prices)?),
        ("drafts", Value::Array(entries.into_iter().map(Value::Object).collect())),
        ("issues", issues_payload(item)?),
    ] {
        out.insert(k.into(), v);
    }
    let _ = config;
    Ok(Value::Object(out))
}

/// What a state build can't reproduce from the data alone: gates for the parts not ported.
fn gates(items: &[WorkItem], log: &SessionLog) -> R<()> {
    let raw = config_raw();
    if raw.get("loose_starters").is_some_and(|v| !matches!(v, Value::Null)) {
        return Err(Unported);
    }
    if let Some(Value::Object(projects)) = raw.get("projects") {
        if projects.values().any(|p| p.as_object().is_some_and(|m| m.contains_key("benchmark"))) {
            return Err(Unported);
        }
    }
    let runs = std::fs::read_dir(data_root::root().join("benchmarks")).map(|d| d.filter_map(|e| e.ok()).any(|e| e.path().join("meta.json").exists())).unwrap_or(false);
    if runs {
        return Err(Unported);
    }
    // build progress: a live session's sub-agent workflow runs
    for item in items {
        for id in item.session_ids() {
            if let Some(s) = log.session_for(&id).filter(|s| s.live) {
                if let Some(t) = s.transcript() {
                    let dir = t.to_string_lossy().trim_end_matches(".jsonl").to_string();
                    if std::fs::read_dir(format!("{dir}/subagents/workflows")).map(|mut d| d.next().is_some()).unwrap_or(false) {
                        return Err(Unported);
                    }
                }
            }
        }
    }
    Ok(())
}

/// `TurnNotifier.unlinked_title`: the first prompt, shortened, else the fallback.
pub(crate) fn unlinked_title(session: Option<&Session>, fallback: &str) -> String {
    let prompt = session.and_then(|s| s.first_prompt()).unwrap_or_default();
    let prompt = crate::ruby_text::strip(&prompt);
    if prompt.is_empty() {
        return fallback.to_string();
    }
    if prompt.chars().count() > 60 {
        format!("{}…", prompt.chars().take(59).collect::<String>())
    } else {
        prompt.to_string()
    }
}

/// `LooseChat#session_of`: the chat's live session, else its newest (a /clear restarts it under the same id).
pub(crate) fn loose_session(log: &SessionLog, id: &str) -> Option<Session> {
    let mine: Vec<Session> = log.sessions().into_iter().filter(|s| s.loose_id().as_deref() == Some(id)).collect();
    let newest = |list: Vec<&Session>| -> Option<Session> {
        let mut best: Option<&Session> = None;
        for s in list {
            if best.is_none_or(|b| s.started_ts() > b.started_ts()) {
                best = Some(s);
            }
        }
        best.cloned()
    };
    newest(mine.iter().filter(|s| s.live).collect()).or_else(|| newest(mine.iter().collect()))
}

/// `LooseChat#chats`: the live loose chats among the tmux sessions, titled by their first prompt.
fn loose_payload(panes: &[String], log: &SessionLog) -> Vec<Value> {
    let mut attention = ChatAttention::new();
    panes
        .iter()
        .filter_map(|name| {
            let id = name.strip_prefix("loose--")?;
            let session = loose_session(log, id);
            let turn = session.as_ref().map(|s| attention.turn_for(s));
            Some(json!({
                "name": name, "id": id, "session": session.as_ref().map(|s| s.id.clone()),
                "title": unlinked_title(session.as_ref(), "New loose chat"),
                "project": session.as_ref().and_then(|s| s.project()),
                "cwd": session.as_ref().and_then(|s| s.cwd()).map(|c| short_path(Some(&c))),
                "state": turn.as_ref().map(|t| t.state.clone()).unwrap_or_else(|| "none".into()),
                "since": turn.as_ref().and_then(|t| t.since).map(iso),
                "tool": turn.as_ref().and_then(|t| t.tool.clone())
            }))
        })
        .collect()
}

fn chat_attention() -> R<Vec<Value>> {
    let mut attention = ChatAttention::new();
    let entries = attention.entries().map_err(|_| Unported)?;
    let log = SessionLog::read();
    *MID_TURN.lock().unwrap() = entries.iter().filter(|e| e.state == "working" || e.state == "blocked").filter_map(|e| e.session_id.as_deref().and_then(|id| log.session_for(id)).and_then(|s| s.transcript()).map(|p| p.to_string_lossy().into_owned())).collect();
    let now = crate::clock::now_f64();
    Ok(entries
        .iter()
        .map(|e| {
            let tokens = e.context_tokens;
            let level = tokens.and_then(|t| if t >= 250_000 { Some("red") } else if t >= 150_000 { Some("amber") } else { None });
            let rotate = tokens.and_then(|t| if t >= 150_000 { Some("threshold") } else if t > 50_000 && e.last_assistant_at.is_some_and(|l| now - l > 3600.0) { Some("cold") } else { None });
            json!({"slug": e.slug, "session": e.session_id, "state": e.state, "since": e.since.map(iso), "tool": e.tool, "snoozed": e.snoozed,
                   "waitingOn": e.waiting_on, "contextTokens": tokens, "cacheWarmUntil": e.cache_warm_until.map(iso), "lastAssistantAt": e.last_assistant_at.map(iso),
                   "ctxLevel": level, "rotate": rotate})
        })
        .collect())
}

/// `GuiState#build`.
pub fn build(token: &str) -> R<Value> {
    let pulse_now = pulse();
    let log = SessionLog::read();
    crate::pr_status::start_build();
    let attention = Attention::new(std::time::SystemTime::now());
    let live_ids: Vec<String> = log.sessions().into_iter().filter(|s| s.live).map(|s| s.id).collect();
    let config = crate::project_config::ProjectConfig::current();
    let status = crate::pf::status(config.dev_server());
    let panes = crate::tmux::Tmux::new().sessions();
    let prices = PriceTable::load();
    let mut aside_counts: Vec<(String, usize)> = vec![];
    for s in log.sessions() {
        if let Some(slug) = s.aside_for() {
            match aside_counts.iter_mut().find(|(k, _)| *k == slug) {
                Some((_, n)) => *n += 1,
                None => aside_counts.push((slug, 1)),
            }
        }
    }
    let mut work_items = WorkItem::all().map_err(|_| Unported)?;
    gates(&work_items, &log)?;
    let context = Context { log: &log, attention: &attention, live_ids, pf: &status, panes: &panes, prices: &prices, aside_counts };
    let mut guard = LEDGER.lock().unwrap();
    let ledger = guard.get_or_insert_with(UsageLedger::new);
    let mut items = vec![];
    for item in work_items.iter_mut() {
        items.push(item_payload(item, &context, ledger)?);
    }
    ledger.save();
    drop(guard);

    let raw = config_raw();
    let names: Vec<&str> = config.roots().into_iter().map(|(n, _)| n).collect();
    let mut projects: Vec<String> = names.iter().map(|s| s.to_string()).collect();
    if !projects.iter().any(|p| p == "No project") {
        projects.push("No project".into());
    }
    let default_project = match raw.get("default_project") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(_) => return Err(Unported),
    };
    let default_project = if names.contains(&default_project.as_str()) { json!(default_project) } else { json!(names.first()) };

    let open_loose: Vec<&str> = panes.iter().filter_map(|n| n.strip_prefix("loose--")).collect();
    let mut inbox_sessions: Vec<Session> = log.inbox().map_err(|_| Unported)?.into_iter().filter(|s| !s.loose_id().is_some_and(|id| open_loose.contains(&id.as_str()))).collect();
    inbox_sessions.sort_by_key(|s| s.last_ts());
    inbox_sessions.reverse();
    let mut inbox = vec![];
    for s in &inbox_sessions {
        inbox.push(json!({"id": s.id, "prompt": s.first_prompt().unwrap_or_else(|| "(no prompt captured)".into()), "when": relative_when(s.last_ts_opt().as_deref())?.unwrap_or_else(|| "—".into()), "cwd": short_path(Some(s.cwd().as_deref().unwrap_or("?")))}));
    }
    let attention_rows = chat_attention()?;
    let mut out = Map::new();
    for (k, v) in [
        ("items", Value::Array(items)),
        ("inbox", Value::Array(inbox)),
        ("projects", json!(projects)),
        ("defaultProject", default_project),
        ("looseStarters", json!([])),
        ("attention", Value::Array(attention_rows)),
        ("loose", Value::Array(loose_payload(&panes, &log))),
        ("pulse", json!(pulse_now)),
        ("refreshing", json!(crate::pr_status::refreshing())),
        ("distilling", json!([])),
        ("distilled", json!([])),
        ("pf", pf_payload(&status, config.dev_server())),
        ("jobs", Value::Array(crate::gui_jobs::running())),
        ("buildActive", json!([])),
        ("buildProgress", json!({})),
        ("panes", json!(panes)),
        ("terminalToken", json!(token)),
        ("asideModels", json!(["sonnet", "opus", "haiku"])),
        ("caffeinate", json!({"on": false, "pid": null, "mode": "off"})),
        ("benchmark", Value::Null),
        ("notifications", json!([])),
        ("rateLimits", rate_limits()),
        ("finished", Value::Array(crate::gui_jobs::take_finished())),
    ] {
        out.insert(k.into(), v);
    }
    let _ = text(&Value::Null);
    Ok(Value::Object(out))
}
