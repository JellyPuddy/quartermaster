//! `qm statusline`: the Claude Code status line (the command `settings.json`'s `statusLine` runs).
//!   Left:  ➜ dir git:(branch) ✗ | [Model]
//!   Right: ctx [bar] XX% | 5h [bar] XX% (2h15m) · wk [bar] XX% (3d4h)
//! Claude Code hands the account's rate limits only to this command, so it also writes them to
//! `<qm root>/rate-limits.json` for the GUI and the work-items page. It never creates qm's data
//! directory and never lets a failure reach the status line.

use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

use crate::outcome::{done, Outcome};

const GREEN: &str = "\x1b[0;32m";
const YELLOW: &str = "\x1b[0;33m";
const CYAN: &str = "\x1b[0;36m";
const BLUE: &str = "\x1b[0;34m";
const VIVID_BLUE: &str = "\x1b[1;94m";
const MAGENTA: &str = "\x1b[0;35m";
const RED: &str = "\x1b[0;31m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";
const SAFETY_MARGIN: i64 = 5;

fn dig<'a>(v: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut cur = v;
    for key in path {
        cur = cur.get(*key)?;
    }
    Some(cur)
}

fn truthy(v: Option<&Value>) -> Option<&Value> {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => None,
        some => some,
    }
}

/// `String#to_s` of what the input holds.
fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn write_rate_limits_snapshot(limits: &Value) {
    if !limits.is_object() {
        return;
    }
    let root = crate::data_root::root();
    if !root.is_dir() {
        return;
    }
    let window = |key: &str| match limits.get(key) {
        Some(w) if w.is_object() => json!({"used_percentage": w.get("used_percentage").cloned().unwrap_or(Value::Null), "resets_at": w.get("resets_at").cloned().unwrap_or(Value::Null)}),
        _ => Value::Null,
    };
    let snapshot = json!({"v": 1, "five_hour": window("five_hour"), "seven_day": window("seven_day"), "captured_at": crate::clock::now_utc_iso()});
    let tmp = root.join(format!(".rate-limits.json.{}.tmp", std::process::id()));
    let _ = std::fs::write(&tmp, serde_json::to_string(&snapshot).unwrap_or_default()).and_then(|_| std::fs::rename(&tmp, root.join("rate-limits.json")));
    let _ = std::fs::remove_file(&tmp);
}

/// True inside a chat qm runs in its own tmux server (`$TMUX` is "<socket path>,<pid>,<session>").
fn in_qm_chat() -> bool {
    let tmux = std::env::var("TMUX").unwrap_or_default();
    let socket = tmux.split(',').next().unwrap_or("");
    if socket.is_empty() {
        return false;
    }
    let name = std::path::Path::new(socket).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut names = vec!["qm".to_string()];
    names.extend(std::env::var("QM_TMUX_SOCKET").ok().filter(|s| !s.is_empty()));
    names.contains(&name)
}

fn hours_minutes(seconds: i64) -> String {
    let s = seconds.max(0);
    format!("{}h{}m", s / 3600, (s % 3600) / 60)
}

fn days_hours(seconds: i64) -> String {
    let s = seconds.max(0);
    if s < 86_400 {
        return hours_minutes(s);
    }
    format!("{}d{}h", s / 86_400, (s % 86_400) / 3600)
}

fn bar(pct: i64) -> String {
    let pct = pct.clamp(0, 100);
    let filled = ((pct * 8 + 50) / 100) as usize;
    let color = if pct >= 80 { RED } else if pct >= 50 { YELLOW } else { GREEN };
    format!("{color}{}{}{RESET}", "█".repeat(filled), "░".repeat(8 - filled))
}

fn visible_length(s: &str) -> i64 {
    regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap().replace_all(s, "").chars().count() as i64
}

/// `Float#round` / `Integer#round`.
fn round_pct(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f.round() as i64)),
        _ => None,
    }
}

/// `value.to_i` of a JSON number or string.
fn to_i(v: &Value) -> i64 {
    match v {
        Value::Number(n) => n.as_i64().unwrap_or_else(|| n.as_f64().unwrap_or(0.0) as i64),
        Value::String(s) => {
            let t = s.trim_start();
            let (sign, digits) = match t.strip_prefix('-') { Some(r) => (-1, r), None => (1, t.strip_prefix('+').unwrap_or(t)) };
            sign * digits.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse::<i64>().unwrap_or(0)
        }
        _ => 0,
    }
}

fn git(cwd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(["-C", cwd, "--no-optional-locks"]).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn terminal_width() -> i64 {
    let tput = Command::new("tput").arg("cols").stdin(Stdio::null()).stderr(Stdio::null()).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).and_then(|c| c.parse::<i64>().ok());
    tput.or_else(|| std::env::var("COLUMNS").ok().and_then(|c| c.trim().parse().ok())).unwrap_or(80)
}

/// The status line for one input document.
pub fn render(input: &Value) -> String {
    let cwd = text(truthy(dig(input, &["workspace", "current_dir"])).or_else(|| input.get("cwd")));
    let dir = std::path::Path::new(&cwd).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| if cwd.is_empty() { String::new() } else { "/".into() });
    let model = dig(input, &["model", "display_name"]).and_then(Value::as_str).unwrap_or("");
    if let Some(limits) = input.get("rate_limits") {
        write_rate_limits_snapshot(limits);
    }
    let qm_chat = in_qm_chat();
    let item_title = if qm_chat {
        None
    } else {
        let id = text(input.get("session_id"));
        (!id.is_empty()).then(|| crate::work_item::WorkItem::all().ok().and_then(|items| items.into_iter().find(|i| i.session_ids().iter().any(|s| *s == id)).map(|i| i.title().trim().to_string()))).flatten().filter(|t| !t.is_empty())
    };
    let item_line = item_title.map(|t| format!("\n{MAGENTA}◆{RESET} {DIM}{t}{RESET}")).unwrap_or_default();
    let used = truthy(dig(input, &["context_window", "used_percentage"]));
    let five_hour = if qm_chat { None } else { truthy(dig(input, &["rate_limits", "five_hour", "used_percentage"])) };
    let seven_day = if qm_chat { None } else { truthy(dig(input, &["rate_limits", "seven_day", "used_percentage"])) };
    let five_resets = truthy(dig(input, &["rate_limits", "five_hour", "resets_at"]));
    let seven_resets = truthy(dig(input, &["rate_limits", "seven_day", "resets_at"]));
    let now = chrono::Utc::now().timestamp();

    let mut git_part = String::new();
    if git(&cwd, &["rev-parse", "--is-inside-work-tree"]).is_some() {
        let mut branch = git(&cwd, &["symbolic-ref", "--short", "HEAD"]).unwrap_or_default();
        if branch.is_empty() {
            branch = git(&cwd, &["rev-parse", "--short", "HEAD"]).unwrap_or_default();
        }
        if !branch.is_empty() {
            let dirty = !git(&cwd, &["status", "--porcelain"]).unwrap_or_default().is_empty();
            git_part = if dirty { format!(" {BLUE}git:({RED}{branch}{BLUE}){RESET} {RED}✗{RESET}") } else { format!(" {BLUE}git:({RED}{branch}{BLUE}){RESET}") };
        }
    }
    let mut left = format!("{GREEN}➜{RESET} {CYAN}{dir}{RESET}{git_part}");
    if !model.is_empty() {
        left = format!("{left} | {VIVID_BLUE}[{model}]{RESET}");
    }

    let mut usage = String::new();
    if let Some(pct) = used.and_then(round_pct) {
        let chunk = format!("ctx [{}] {pct}%", bar(pct));
        usage = if pct >= 80 { format!("{RED}{chunk}{RESET}") } else { chunk };
    }
    let mut segment = |label: &str, value: Option<&Value>, resets: Option<&Value>, countdown: fn(i64) -> String, sep: &str| {
        let Some(pct) = value.and_then(round_pct) else { return };
        let mut chunk = format!("{label} [{}] {pct}%", bar(pct));
        if let Some(at) = resets {
            chunk = format!("{chunk} ({})", countdown(to_i(at) - now));
        }
        if !usage.is_empty() {
            usage = format!("{usage}{sep}");
        }
        usage += &if pct >= 80 { format!("{RED}{chunk}{RESET}") } else { chunk };
    };
    segment("5h", five_hour, five_resets, hours_minutes, " | ");
    segment("wk", seven_day, seven_resets, days_hours, " · ");

    if usage.is_empty() {
        return format!("{left}{item_line}");
    }
    let width = terminal_width() - SAFETY_MARGIN;
    let padding = (width - visible_length(&left) - visible_length(&usage)).max(1);
    format!("{left}{}{usage}{item_line}", " ".repeat(padding as usize))
}

pub fn run(stdin: &str) -> Outcome {
    // a document that isn't JSON leaves the line empty rather than breaking it
    let Ok(input) = serde_json::from_str::<Value>(stdin) else { return done(String::new()) };
    let rendered = render(&input);
    let _ = std::io::stdout().flush();
    done(rendered)
}
