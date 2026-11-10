//! The chats list's Loose group and Runs group among the live tmux sessions: loose chats (`loose--<id>`, titled
//! by their first prompt), then local automations' run chats (`run_chats`).

use serde_json::{json, Value};

use crate::chat_attention::ChatAttention;
use crate::cli_format::short_path;
use crate::gui_state::{iso, loose_session, unlinked_title};
use crate::session_log::SessionLog;

/// `LooseChat#chats`: the live loose chats among the tmux sessions.
fn loose(panes: &[String], log: &SessionLog) -> Vec<Value> {
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

/// Loose chats, then the run chats of local automations.
pub fn chats(panes: &[String], log: &SessionLog) -> Vec<Value> {
    let mut rows = loose(panes, log);
    rows.extend(crate::run_chats::chats(panes, &crate::automation_store::dir(), &mut ChatAttention::new()));
    rows
}
