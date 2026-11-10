//! `qm doctor`: is qm wired up and capturing? Each check is one line marked ✓ (fine), ! (works, but worth
//! knowing) or ✗ (broken, with how to fix it). Reads only; it writes nothing.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, FixedOffset};
use serde_json::Value;

use crate::error_log::ErrorLog;
use crate::outcome::Outcome;
use crate::{clock, data_root, delegate, event_log};

/// The events `qm install-hooks` hands to hooks/record-event.sh.
const RECORD_EVENTS: [&str; 6] = ["UserPromptSubmit", "PermissionRequest", "Stop", "StopFailure", "PostToolUseFailure", "PostToolUse"];
const OK: &str = "✓";
const WARN: &str = "!";
const FAIL: &str = "✗";
const INSTALL_HINT: &str = "merge the snippet `qm install-hooks` prints";

pub struct Check {
    pub mark: &'static str,
    pub name: &'static str,
    pub detail: String,
    pub hint: Option<String>,
}

impl Check {
    fn new(mark: &'static str, name: &'static str, detail: impl Into<String>, hint: Option<&str>) -> Check {
        Check { mark, name, detail: detail.into(), hint: hint.map(String::from) }
    }

    pub fn line(&self) -> String {
        let hint = self.hint.as_ref().filter(|_| self.mark != OK).map(|h| format!(" — {h}")).unwrap_or_default();
        format!("{} {}: {}{hint}", self.mark, self.name, self.detail)
    }
}

pub struct Doctor {
    settings_path: PathBuf,
    now: DateTime<FixedOffset>,
}

impl Doctor {
    pub fn new() -> Doctor {
        let settings = std::env::var("QM_CLAUDE_SETTINGS").unwrap_or_else(|_| "~/.claude/settings.json".into());
        Doctor { settings_path: data_root::expand_path(&settings), now: chrono::Local::now().fixed_offset() }
    }

    pub fn checks(&self) -> Vec<Check> {
        let (hooks, launcher) = self.hook_checks();
        let mut checks = hooks;
        checks.extend([binary_check(launcher), root_check(), self.errors_check(), self.capture_check()]);
        checks
    }

    /// The three hook checks, and the launcher the SessionStart hook runs (when settings name one).
    fn hook_checks(&self) -> (Vec<Check>, Option<PathBuf>) {
        let settings = std::fs::read_to_string(&self.settings_path).map_err(|e| if e.kind() == std::io::ErrorKind::NotFound { "Errno::ENOENT" } else { "IOError" }).and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| "JSON::ParserError")).and_then(|v| if v.is_object() { Ok(v) } else { Err("TypeError") });
        let settings = match settings {
            Ok(v) => v,
            Err(class) => {
                let broken = |name| Check::new(FAIL, name, format!("can't read {} ({class})", self.settings_path.display()), Some(INSTALL_HINT));
                return (vec![broken("SessionStart hook"), broken("SessionEnd hook"), broken("record-event.sh hook")], None);
            }
        };
        let hooks = settings.get("hooks").cloned().unwrap_or(Value::Null);
        let (start, launcher) = self.session_hook(&hooks, "SessionStart", "hook-session-start");
        let (end, _) = self.session_hook(&hooks, "SessionEnd", "hook-session-end");
        (vec![start, end, self.record_event_hook(&hooks)], launcher)
    }

    fn session_hook(&self, hooks: &Value, event: &str, word: &str) -> (Check, Option<PathBuf>) {
        let name = if event == "SessionStart" { "SessionStart hook" } else { "SessionEnd hook" };
        let words = commands(hooks, event).iter().map(|c| c.split_whitespace().map(String::from).collect::<Vec<_>>()).find(|argv| argv.iter().any(|w| w == word));
        let Some(words) = words else { return (Check::new(FAIL, name, format!("not registered in {}", self.settings_path.display()), Some(INSTALL_HINT)), None) };
        let file = data_root::expand_path(&words[0]);
        (file_check(name, &file), Some(file))
    }

    fn record_event_hook(&self, hooks: &Value) -> Check {
        let name = "record-event.sh hook";
        let found: Vec<(&str, Option<String>)> = RECORD_EVENTS.iter().map(|e| (*e, commands(hooks, e).iter().filter_map(|c| c.split_whitespace().next().map(String::from)).find(|f| Path::new(f).file_name().is_some_and(|n| n == "record-event.sh")))).collect();
        let missing: Vec<&str> = found.iter().filter(|(_, f)| f.is_none()).map(|(e, _)| *e).collect();
        if !missing.is_empty() {
            return Check::new(FAIL, name, format!("not registered on {}", missing.join(", ")), Some(INSTALL_HINT));
        }
        let mut files: Vec<PathBuf> = vec![];
        for (_, f) in &found {
            let file = data_root::expand_path(f.as_deref().unwrap_or_default());
            if !files.contains(&file) {
                files.push(file);
            }
        }
        files.iter().map(|f| file_check(name, f)).find(|c| c.mark == FAIL).unwrap_or_else(|| Check::new(OK, name, format!("on all {} events", RECORD_EVENTS.len()), None))
    }

    fn errors_check(&self) -> Check {
        let errors = ErrorLog::new().at(self.now);
        let since = errors.since().with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M").to_string();
        let summary = errors.summary();
        let count = summary["count"].as_u64().unwrap_or(0);
        if count == 0 {
            return Check::new(OK, "qm.log errors", format!("none since {since}"), None);
        }
        // the summary lists newest first
        let last = summary["entries"][0]["lines"][0].as_str().unwrap_or_default();
        Check::new(WARN, "qm.log errors", format!("{count} error{} since {since}, last: {last}", if count == 1 { "" } else { "s" }), Some(&format!("details in {}", data_root::root().join("qm.log").display())))
    }

    fn capture_check(&self) -> Check {
        let log = data_root::root().join("qm.log");
        let hint = format!("capture may have stopped: check the hooks above and that qm is built (`cargo build --release`), then {}", log.display());
        let last = [crate::session_log::SessionLog::read().last_activity_ts(), event_log::last_ts()].into_iter().flatten().filter_map(|ts| clock::parse(&ts)).max();
        let Some(last) = last else { return Check::new(WARN, "Capture", "nothing captured yet", Some(&hint)) };
        let detail = format!("last event {}", last.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M"));
        Check::new(if self.now - last > Duration::hours(24) { WARN } else { OK }, "Capture", detail, Some(&hint))
    }
}

impl Default for Doctor {
    fn default() -> Self {
        Self::new()
    }
}

fn commands(hooks: &Value, event: &str) -> Vec<String> {
    let groups = hooks.get(event).and_then(Value::as_array).cloned().unwrap_or_default();
    groups.iter().filter_map(|g| g.get("hooks").and_then(Value::as_array)).flatten().filter_map(|h| h.get("command").and_then(Value::as_str).map(String::from)).collect()
}

fn file_check(name: &'static str, file: &Path) -> Check {
    if file.exists() {
        return Check::new(OK, name, file.display().to_string(), None);
    }
    Check::new(FAIL, name, format!("points at {}, which does not exist", file.display()), Some(INSTALL_HINT))
}

/// A hook's launcher with no built binary behind it exits 0 and captures nothing.
fn binary_check(launcher: Option<PathBuf>) -> Check {
    let launcher = launcher.unwrap_or_else(delegate::checkout_launcher);
    let dir = std::fs::canonicalize(&launcher).ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default();
    let bin = std::env::var_os("QM_BIN").map(PathBuf::from).unwrap_or_else(|| dir.join("target/release/qm"));
    if is_executable(&bin) {
        return Check::new(OK, "qm binary", bin.display().to_string(), None);
    }
    Check::new(FAIL, "qm binary", format!("{} is missing or not executable, so every hook exits without capturing", bin.display()), Some(&format!("run `cargo build --release` in {}", dir.display())))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn root_check() -> Check {
    let root = data_root::root();
    let writable = std::ffi::CString::new(root.as_os_str().as_encoded_bytes()).is_ok_and(|c| root.is_dir() && unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0);
    if writable {
        return Check::new(OK, "Data root", root.display().to_string(), None);
    }
    Check::new(FAIL, "Data root", format!("{} is missing or not writable", root.display()), Some("create it and make it writable for you"))
}

/// One line per check; exit 1 on any ✗.
pub fn run() -> Outcome {
    let checks = Doctor::new().checks();
    let mut out = String::new();
    for c in &checks {
        out.push_str(&c.line());
        out.push('\n');
    }
    Outcome::Done { code: i32::from(checks.iter().any(|c| c.mark == FAIL)), stdout: out, stderr: String::new() }
}
