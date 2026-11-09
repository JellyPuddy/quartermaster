use std::io::Write;

use crate::clock;
use crate::data_root;

/// One `{v, at, kind, name}` line per use — kind and name only, never arguments. Best effort.
pub fn record(kind: &str, name: &str) {
    let line = serde_json::json!({"v": 1, "at": clock::now_utc_iso(), "kind": kind, "name": name});
    let path = data_root::root().join("feature-use.jsonl");
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
        writeln!(f, "{line}")
    };
    if let Err(e) = write() {
        if e.kind() == std::io::ErrorKind::NotFound {
            let _ = std::fs::create_dir_all(data_root::root());
            if write().is_ok() {
                return;
            }
        }
        data_root::log_error("feature-use", "IOError", &e.to_string());
    }
}

/// A `qm` run by its command word; hooks, the status line (it runs on every refresh) and `QM_SKIP` runs are plumbing, not uses.
pub fn command(word: Option<&str>) {
    let Some(word) = word else { return };
    if word.starts_with("hook-") || word == "statusline" || std::env::var_os("QM_SKIP").is_some() {
        return;
    }
    record("cli", word);
}

const KINDS: [&str; 3] = ["action", "get", "cli"];

const KNOWN_ACTIONS: &[&str] = &[
    "/api/ask", "/api/cleanup-plan", "/api/drop", "/api/grep", "ack", "adopt", "aside-close", "aside-open", "aside-promote", "aside-reopen", "attach", "board-answer", "branch-stats-commentary", "build-progress", "caffeinate", "cleanup", "describe", "detach", "diff-viewed", "dismiss", "distill", "draft-delete", "draft-edit", "draft-move", "draft-place", "draft-put", "drafts-discard", "drafts-load", "drafts-send", "ide", "issue-acknowledge", "issue-comment-put", "issue-preview", "issue-start", "issues-clear-created", "issues-create", "item-from-session", "move", "new", "note", "page-annotations", "pane-resume", "pane-start", "pane-warp", "pf-mode", "pf-stop", "pf-switch", "pr", "pr-chat", "pr-ide", "pr-pf", "pr-review", "pr-thread-resolve", "pr-unrequire", "restack", "resume", "resume-session", "retag", "retitle", "review-post", "review-preview", "rotate", "run-update", "snooze", "start", "state", "terminal", "thread-reply-put", "work-on",
];
const KNOWN_GETS: &[&str] = &["/api/asides", "/api/attention", "/api/branch-stats", "/api/diff", "/api/diff-file", "/api/history", "/api/issues", "/api/pr-threads", "/api/prs", "/api/session", "/api/workspace"];
const KNOWN_CLI: &[&str] = &[
    "ack", "ask", "attach", "attach-session", "attention", "bench-run", "board", "board-answer", "board-rows", "caffeinate", "choose-project", "choose-snooze", "choose-state", "cleanup", "cycle-filter", "describe", "detach", "dismiss", "distill", "draft", "feature-use", "grep", "gui", "help", "ide", "inbox", "inbox-rows", "inbox-view", "install-hooks", "issues-dir", "item-from-session", "link-branch", "list", "loose", "move", "new", "note", "open-chat", "overview", "pane-resume", "pane-start", "pf-mode", "pf-status", "pf-stop", "pf-switch", "pr", "pr-requires", "resume", "retag", "retitle", "rotate", "session-item", "session-rows", "sessions", "sessions-view", "show", "show-session", "snooze", "start", "start-issue", "state", "statusline", "sweep", "term", "unlink-branch", "viewer", "viewer-rows", "work-on",
];

fn known(kind: &str) -> &'static [&'static str] {
    match kind {
        "action" => KNOWN_ACTIONS,
        "get" => KNOWN_GETS,
        "cli" => KNOWN_CLI,
        _ => &[],
    }
}

struct Use {
    kind: String,
    name: String,
    at: chrono::DateTime<chrono::FixedOffset>,
}

fn uses(path: &std::path::Path) -> Vec<Use> {
    let Ok(text) = std::fs::read_to_string(path) else { return vec![] };
    text.lines()
        .filter_map(|line| {
            let v: serde_json::Value = serde_json::from_str(line).ok()?;
            let at = chrono::DateTime::parse_from_rfc3339(v.get("at")?.as_str()?).ok()?;
            Some(Use { kind: v.get("kind")?.as_str()?.to_string(), name: v.get("name")?.as_str()?.to_string(), at })
        })
        .collect()
}

fn date(t: chrono::DateTime<chrono::FixedOffset>) -> String {
    t.with_timezone(&chrono::Local).format("%Y-%m-%d").to_string()
}

/// `qm feature-use [--days N]`: per kind, the names used in the window, then the known names nobody used.
/// `Err` is the `ArgumentError` message; `Ok(None)` an option Ruby's parser reads in its own way.
pub fn report(args: &[String]) -> Result<Option<String>, String> {
    let mut days: i64 = 30;
    let mut extra: Vec<&String> = vec![];
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        let (name, inline) = match a.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (a.as_str(), None),
        };
        if name.starts_with("--") && name.len() >= 3 && "--days".starts_with(name) {
            let value = match inline {
                Some(v) => v,
                None => {
                    i += 1;
                    match args.get(i) {
                        Some(v) => v.clone(),
                        None => return Err(format!("missing argument: {name}")),
                    }
                }
            };
            let digits = value.strip_prefix('-').unwrap_or(&value);
            if digits.is_empty() || digits.len() > 17 || !digits.bytes().all(|b| b.is_ascii_digit()) || (digits.len() > 1 && digits.starts_with('0')) {
                return if value.is_empty() || !value.bytes().all(|b| b.is_ascii_graphic()) { Ok(None) } else if digits.starts_with('0') || digits.contains('_') { Ok(None) } else { Err(format!("invalid argument: {name} {value}")) };
            }
            days = value.parse().map_err(|_| "invalid argument".to_string())?;
        } else if a.starts_with('-') && a != "-" {
            return Err(format!("invalid option: {a}"));
        } else {
            extra.push(a);
        }
        i += 1;
    }
    if let Some(first) = extra.first() {
        return Err(format!("unexpected argument: {first} (did you mean --days {first}?)"));
    }
    if days <= 0 {
        return Err("--days must be positive".into());
    }
    let all = uses(&data_root::root().join("feature-use.jsonl"));
    let since = chrono::Utc::now() - chrono::Duration::seconds(days.saturating_mul(86_400));
    let window: Vec<&Use> = all.iter().filter(|u| u.at >= since).collect();
    let start = all.first().map(|u| date(u.at)).unwrap_or_else(|| "— nothing logged yet".into());
    let mut lines = vec![format!("Feature use, last {days} days (log starts {start})")];
    for kind in KINDS {
        let mut tally: Vec<(String, usize, chrono::DateTime<chrono::FixedOffset>)> = vec![];
        for u in window.iter().filter(|u| u.kind == kind) {
            match tally.iter_mut().find(|(n, _, _)| *n == u.name) {
                Some(t) => {
                    t.1 += 1;
                    t.2 = t.2.max(u.at);
                }
                None => tally.push((u.name.clone(), 1, u.at)),
            }
        }
        tally.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let total: usize = tally.iter().map(|t| t.1).sum();
        lines.push(String::new());
        lines.push(format!("{kind} ({total} use{})", if total == 1 { "" } else { "s" }));
        for (name, n, last) in &tally {
            lines.push(format!("  {n:>5}  {:<24} last {}", name, date(*last)));
        }
    }
    lines.push(String::new());
    lines.push(format!("Never used in the last {days} days"));
    for kind in KINDS {
        let unused: Vec<&str> = known(kind).iter().copied().filter(|n| !window.iter().any(|u| u.kind == kind && u.name == *n)).collect();
        lines.push(format!("  {kind}: {}", if unused.is_empty() { "—".to_string() } else { unused.join(", ") }));
    }
    Ok(Some(lines.join("\n")))
}

/// Whether `word` is a command qm dispatches (the hooks aside).
pub fn is_known_cli(word: &str) -> bool {
    KNOWN_CLI.contains(&word) || word.starts_with("hook-")
}
