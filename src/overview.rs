//! `qm overview`: the phone page's snapshot of the user's work items (`--json`), the published page's
//! URL (`--url`) and whether the repo's page differs from what was last published (`--page`,
//! `--page-published`).

use serde_json::{json, Map, Value};

use crate::chat_attention::{ChatAttention, STATES as CHAT_STATES};
use crate::cli_format::puts;
use crate::data_root;
use crate::gui_state::{iso, rate_limits};
use crate::outcome::{abort, done, Outcome};
use crate::ruby_text::{rstrip, strip};
use crate::work_item::{WorkItem, STATES};

const STATE_ORDER: [&str; 2] = ["in_progress", "fridge"];
const MAX_ITEMS: usize = 60;
const TITLE_CHARS: usize = 160;
const NOTE_CHARS: usize = 280;
const WAITING_SHOWN: usize = 3;
const WAITING_CHARS: usize = 120;
const MAX_BYTES: usize = 200 * 1024;
const CONFIG_KEY: &str = "overview_artifact";

fn page() -> std::path::PathBuf {
    crate::delegate::checkout().join("skills/work-items/page.html")
}

fn published_file() -> std::path::PathBuf {
    data_root::root().join("overview-page.sha256")
}

fn clip(text: &str, limit: usize) -> String {
    if text.chars().count() > limit { format!("{}…", rstrip(&text.chars().take(limit).collect::<String>())) } else { text.to_string() }
}

fn label(state: &str) -> &'static str {
    match state {
        "in_progress" => "in progress",
        "fridge" => "fridge",
        _ => "resolved",
    }
}

/// The `Overview#snapshot` document.
pub fn snapshot() -> Result<Value, crate::error::QmError> {
    let all: Vec<WorkItem> = WorkItem::all()?.into_iter().filter(|i| !i.automation()).collect();
    let log = crate::session_log::SessionLog::read();
    let chats = ChatAttention::new().entries()?;
    let panes = crate::tmux::Tmux::new().sessions();
    let mut rows: Vec<(Value, (usize, f64, f64, String))> = vec![];
    for item in all.iter().filter(|i| STATE_ORDER.contains(&i.state().unwrap_or_default().as_str())) {
        let chat = chats.iter().rev().find(|c| c.slug == item.slug);
        let activity = match chat.and_then(|c| c.activity) {
            Some(a) => Some(a),
            None => log.item_sessions(item).ok().and_then(|s| s.first().map(|s| s.last_ts())).and_then(|ts| crate::clock::parse_f64(&ts)),
        };
        let rank = chat.map(|c| c.rank()).unwrap_or(4.0);
        let waiting: Vec<String> = chat.and_then(|c| c.waiting_on.clone()).unwrap_or_default().into_iter().take(WAITING_SHOWN).map(|w| clip(&w.unwrap_or_default(), WAITING_CHARS)).collect();
        let notes: Vec<Value> = item.injectable_notes().iter().filter(|n| n.is_open()).map(|n| json!({"position": n.position, "stamp": n.stamp, "text": clip(&n.text, NOTE_CHARS)})).collect();
        let state = item.state().unwrap_or_default();
        let data = json!({
            "slug": item.slug,
            "title": clip(&item.title(), TITLE_CHARS),
            "state": state,
            "project": item.project(),
            "branches": item.branches(),
            "chat": {
                "state": chat.map(|c| c.state.clone()).unwrap_or_else(|| "none".into()),
                "since": chat.and_then(|c| c.since).map(iso),
                "snoozed": chat.is_some_and(|c| c.snoozed),
                "waitingOn": waiting,
            },
            "paneLive": panes.contains(&item.slug),
            "lastActivity": activity.map(iso),
            "openNotes": notes,
            "board": item.board(),
        });
        let order = STATE_ORDER.iter().position(|s| *s == state).unwrap_or(0);
        rows.push((data, (order, rank, -activity.unwrap_or(0.0), item.slug.clone())));
    }
    rows.sort_by(|a, b| {
        let (x, y) = (&a.1, &b.1);
        x.0.cmp(&y.0).then(x.1.partial_cmp(&y.1).unwrap_or(std::cmp::Ordering::Equal)).then(x.2.partial_cmp(&y.2).unwrap_or(std::cmp::Ordering::Equal)).then(x.3.cmp(&y.3))
    });
    let mut rows: Vec<Value> = rows.into_iter().map(|r| r.0).collect();
    let mut counts = Map::new();
    for s in STATES {
        counts.insert(s.into(), json!(all.iter().filter(|i| i.state().as_deref() == Some(s)).count()));
    }
    rows.truncate(MAX_ITEMS);
    let shown_total: i64 = STATE_ORDER.iter().map(|s| counts[*s].as_i64().unwrap_or(0)).sum();
    let mut dropped = shown_total - rows.len() as i64;
    let limits = rate_limits();
    loop {
        let doc = document(&rows, &counts, dropped, &limits);
        if rows.is_empty() || serde_json::to_string(&doc).map(|t| t.len()).unwrap_or(0) <= MAX_BYTES {
            return Ok(doc);
        }
        rows.pop();
        dropped += 1;
    }
}

fn document(rows: &[Value], counts: &Map<String, Value>, omitted: i64, limits: &Value) -> Value {
    let mut chats = Map::new();
    for s in CHAT_STATES {
        chats.insert(s.into(), json!(rows.iter().filter(|r| r["chat"]["state"] == s).count()));
    }
    json!({
        "v": 1,
        "generatedAt": iso(crate::clock::now_f64()),
        "counts": {"states": counts, "chats": chats, "shown": rows.len(), "omitted": omitted},
        "rateLimits": limits,
        "items": rows,
    })
}

fn summary(doc: &Value) -> String {
    let counts = &doc["counts"];
    let states: Vec<String> = STATE_ORDER.iter().map(|s| format!("{} {}", counts["states"][*s], label(s))).collect();
    let chats: Vec<String> = ["blocked", "your_turn", "waiting"].iter().filter_map(|s| counts["chats"][*s].as_i64().filter(|n| *n > 0).map(|n| format!("{n} {}", s.replace('_', " ")))).collect();
    let shown = counts["shown"].as_i64().unwrap_or(0);
    let mut line = format!("{shown} item{}: {}", if shown == 1 { "" } else { "s" }, states.join(", "));
    if counts["omitted"].as_i64().unwrap_or(0) > 0 {
        line.push_str(&format!(" ({} left out)", counts["omitted"]));
    }
    if chats.is_empty() { line } else { format!("{line} · {}", chats.join(", ")) }
}

/// Atomic: a second run may hand the file on while this one writes.
fn write(path: &str, text: &str) -> std::io::Result<()> {
    let full = data_root::expand_path(path);
    let dir = full.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    std::fs::create_dir_all(&dir)?;
    let name = full.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let result = std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, path));
    let _ = std::fs::remove_file(&tmp);
    result
}

fn artifact_url() -> Option<String> {
    let config = crate::project_config::ProjectConfig::current();
    if let Some(crate::project_config::LoadFailure::Syntax(message)) = config.failure() {
        data_root::log_error("overview-config", "Psych::SyntaxError", message);
    }
    config.overview_artifact().map(String::from)
}

fn page_digest() -> Option<String> {
    std::fs::read(page()).ok().map(|b| crate::sha256::hex(&b))
}

pub fn run(a: &[String]) -> Outcome {
    let usage = || abort("usage: qm overview --json [PATH] | --url | --page | --page-published");
    match a.first().map(String::as_str) {
        Some("--json") => {
            let doc = match snapshot() {
                Ok(d) => d,
                Err(e) => return abort(&format!("qm: {}", e.message)),
            };
            let text = serde_json::to_string(&doc).unwrap_or_default();
            match a.get(1) {
                Some(path) => match write(path, &text) {
                    Ok(()) => done(puts(&format!("{} → {path}", summary(&doc)))),
                    Err(_) => Outcome::Refused,
                },
                None => done(puts(&text)),
            }
        }
        Some("--url") => match artifact_url() {
            Some(url) => done(puts(&url)),
            None => abort(&format!("qm overview: no {CONFIG_KEY} configured — publish skills/work-items/page.html, then run `qm config set {CONFIG_KEY} <its claude.ai URL>`")),
        },
        Some("--page") => {
            let published = std::fs::read_to_string(published_file()).ok().map(|t| strip(&t).to_string());
            match page_digest() {
                Some(d) if Some(&d) == published.as_ref() => done(String::new()),
                Some(_) => done(puts(&page().to_string_lossy())),
                None => Outcome::Refused,
            }
        }
        Some("--page-published") => match page_digest() {
            Some(d) => match write(&published_file().to_string_lossy(), &d) {
                Ok(()) => done(String::new()),
                Err(_) => Outcome::Refused,
            },
            None => Outcome::Refused,
        },
        _ => usage(),
    }
}
