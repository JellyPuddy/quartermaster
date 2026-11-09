//! `qm delete` and the GUI's Delete: removes a work item made by accident. Without force it only removes one
//! that holds nothing beyond what `qm new` gives it, so a slip of the slug can't throw away real work. Its
//! chats on the qm socket are killed through the command runner; the append-only logs keep every line, and
//! its sessions simply become unlinked (their ids lived in the item file). Worktrees, branches, issue drafts
//! and plans are left to `qm cleanup` and `qm sweep`.

use serde_json::{json, Value};

use crate::chats_commands::aside_name;
use crate::error::QmError;
use crate::outcome::{abort, done, Outcome};
use crate::work_item::WorkItem;

/// The Description `qm new` writes when given none.
const PLACEHOLDER: &str = "_TODO_";

/// Why a delete did not happen.
pub enum Refused {
    /// The guard: what the item holds, and the message that names it.
    NotEmpty { held: Vec<String>, message: String },
    Other(QmError),
}

impl Refused {
    pub fn message(&self) -> &str {
        match self {
            Refused::NotEmpty { message, .. } => message,
            Refused::Other(e) => &e.message,
        }
    }
}

fn counted(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

/// What the item holds that an accidental one wouldn't: empty means it is safe to delete without force. One
/// session is allowed — the one that created it by mistake.
pub fn held(item: &WorkItem) -> Vec<String> {
    let mut held = vec![];
    let (notes, branches) = (item.notes().len(), item.branches().len());
    if notes > 0 {
        held.push(counted(notes, "note", "notes"));
    }
    if branches > 0 {
        held.push(counted(branches, "branch", "branches"));
    }
    if item.session_count() > 1 {
        held.push(counted(item.session_count(), "session", "sessions"));
    }
    if item.board().is_some() {
        held.push("board set".to_string());
    }
    let description = item.description();
    if !description.is_empty() && description != PLACEHOLDER {
        held.push("a description".to_string());
    }
    held
}

/// Returns the tmux sessions it killed.
pub fn call(slug: &str, force: bool) -> Result<Vec<String>, Refused> {
    if !crate::cleanup_command::valid_slug(slug) {
        return Err(Refused::Other(QmError::argument(format!("'{slug}' is not a work item slug"))));
    }
    WorkItem::with_lock(|| {
        let item = match WorkItem::find(slug) {
            Ok(item) => item,
            Err(e) => return Ok(Err(Refused::Other(e))),
        };
        let held = held(&item);
        if !held.is_empty() && !force {
            let cleanup = if item.branches().is_empty() { String::new() } else { format!("; qm cleanup {slug} first removes its worktrees and branches") };
            let message = format!("'{slug}' holds {} — qm delete {slug} --force deletes it anyway{cleanup}", held.join(", "));
            return Ok(Err(Refused::NotEmpty { held, message }));
        }
        std::fs::remove_file(WorkItem::path_for(&item.slug))?;
        Ok(Ok(kill_chats(&item.slug)))
    })
    .map_err(Refused::Other)?
}

/// The item's chat and its aside; a session that isn't running fails the kill, which is no error.
fn kill_chats(slug: &str) -> Vec<String> {
    let socket = crate::tmux::Tmux::new().socket();
    [slug.to_string(), aside_name(slug)]
        .into_iter()
        .filter(|name| crate::command_runner::call(&["tmux", "-L", &socket, "kill-session", "-t", &format!("={name}")]).success)
        .collect()
}

/// The GUI's reply: a refusal carries `needs_force` and what the item holds, so the page can offer "Delete anyway".
pub fn gui_reply(slug: &str, force: bool) -> Value {
    match call(slug, force) {
        Ok(killed) => json!({"ok": true, "deleted": slug, "killed": killed}),
        Err(Refused::NotEmpty { held, message }) => json!({"ok": false, "needs_force": true, "held": held, "error": message}),
        Err(Refused::Other(e)) => json!({"ok": false, "error": e.message}),
    }
}

/// `qm delete SLUG [--force]`: `Some(outcome)` for the word `delete`, `None` for every other command.
pub fn run(command: &str, args: &[String]) -> Option<Outcome> {
    if command != "delete" {
        return None;
    }
    let force = args.iter().any(|a| a == "--force");
    let rest: Vec<&String> = args.iter().filter(|a| *a != "--force").collect();
    let [slug] = rest[..] else { return Some(abort("usage: qm delete SLUG [--force]")) };
    Some(match call(slug, force) {
        Ok(_) => done(format!("deleted {slug}\n")),
        Err(refused) => abort(&format!("qm: {}", refused.message())),
    })
}
