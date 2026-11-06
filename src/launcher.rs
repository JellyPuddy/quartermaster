//! What a chat pane runs for an item (`Launcher#chat_plan`): a live session refuses, Start is a fresh
//! `QM_ITEM` chat, Resume follows the newest resumable session in its own cwd, else rehydrates.

use std::path::Path;

use crate::branch_diff::start_cwd;
use crate::data_root;
use crate::session_log::{Session, SessionLog};
use crate::work_item::WorkItem;

pub enum Mode {
    Live,
    Resume,
    Start,
}

impl Mode {
    pub fn name(&self) -> &'static str {
        match self {
            Mode::Live => "live",
            Mode::Resume => "resume",
            Mode::Start => "start",
        }
    }
}

pub struct Plan {
    pub mode: Mode,
    pub cwd: String,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// `Shellwords.split(ENV.fetch("QM_CHAT_COMMAND", "claude"))`, for the plain words Ruby and this port
/// read alike; `None` for quoting or escapes.
fn chat_command() -> Option<Vec<String>> {
    let value = std::env::var("QM_CHAT_COMMAND").unwrap_or_else(|_| "claude".into());
    if value.chars().any(|c| !(c.is_ascii_alphanumeric() || "_./=:@%+,-".contains(c) || c == ' ')) {
        return None;
    }
    Some(value.split(' ').filter(|w| !w.is_empty()).map(String::from).collect())
}

/// `project_dir`: Claude Code's directory for a cwd — every non-alphanumeric character a dash.
fn project_dir(path: &str) -> std::path::PathBuf {
    let dashed: String = path.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    data_root::transcripts_dir().join(dashed)
}

/// Where `claude --resume ID` can find the session: the nearest existing ancestor of the recorded cwd
/// that maps to the directory its transcript is filed under, else the cwd itself when it exists.
fn resume_cwd(session: &Session) -> Option<String> {
    let cwd = session.cwd().unwrap_or_default();
    if let Some(dir) = session.transcript().and_then(|t| t.parent().map(Path::to_path_buf)) {
        let mut at = Some(Path::new(&cwd));
        while let Some(candidate) = at {
            if candidate.is_dir() && project_dir(&candidate.to_string_lossy()) == dir {
                return Some(candidate.to_string_lossy().into_owned());
            }
            at = candidate.parent().filter(|p| !p.as_os_str().is_empty());
        }
    }
    Path::new(&cwd).is_dir().then_some(cwd)
}

/// `Launcher#chat_plan`; `None` when `QM_CHAT_COMMAND` is quoted in a way only Ruby reads.
pub fn chat_plan(item: &WorkItem, fresh: bool, session_id: Option<&str>) -> Option<Plan> {
    let command = chat_command()?;
    let ids = item.session_ids();
    let log = SessionLog::read();
    let sessions = log.sessions();
    if sessions.iter().any(|s| ids.contains(&s.id) && s.live) {
        return Some(Plan { mode: Mode::Live, cwd: String::new(), argv: vec![], env: vec![] });
    }
    let fresh_plan = || Plan { mode: Mode::Start, cwd: start_cwd(item), argv: command.clone(), env: vec![("QM_ITEM".into(), item.slug.clone())] };
    if fresh {
        return Some(fresh_plan());
    }
    let mut mine: Vec<&Session> = sessions.iter().filter(|s| ids.contains(&s.id) && session_id.is_none_or(|w| s.id == w)).collect();
    mine.sort_by_key(|s| s.last_ts());
    mine.reverse();
    let resumable = mine.iter().find_map(|s| (s.tier() == "resumable").then(|| resume_cwd(s).map(|c| (s.id.clone(), c))).flatten());
    match resumable {
        Some((id, cwd)) => Some(Plan { mode: Mode::Resume, cwd, argv: command.iter().cloned().chain(["--resume".to_string(), id]).collect(), env: vec![] }),
        None if mine.iter().any(|s| s.live) => Some(Plan { mode: Mode::Live, cwd: String::new(), argv: vec![], env: vec![] }),
        None => Some(fresh_plan()),
    }
}
