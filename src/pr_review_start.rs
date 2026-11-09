//! A PR's review runs in a chat of its own — a separate item, so it never lands in the PR's own chat — with
//! the review skill as its first prompt. The item links no branch: auto-matching a branch to two items is
//! ambiguous. It starts in the main checkout; the skill reads the PR from GitHub. The GUI's Review button and
//! the pr-review automation flow share it; nothing here needs a GUI.

use serde_json::{json, Value};

use crate::error::Res;
use crate::launcher::{self, Mode};
use crate::pr_items;
use crate::tmux::Tmux;
use crate::work_item::WorkItem;

fn text<'a>(pr: &'a Value, key: &str) -> &'a str {
    pr.get(key).and_then(Value::as_str).unwrap_or("")
}

fn project_for(pr: &Value) -> String {
    pr_items::project_for_repo(text(pr, "repo")).unwrap_or_else(|| crate::project_map::NO_PROJECT.to_string())
}

/// The PR's Review item, made when it has none.
pub fn item_for(pr: &Value) -> Res<WorkItem> {
    let items = WorkItem::all()?;
    if let Some(item) = pr_items::review_item(pr, &items) {
        return WorkItem::find(&item.slug);
    }
    let title = format!("Review {}: {}", pr_items::pr_label(pr), text(pr, "title"));
    pr_items::find_or_create_item(&title, &project_for(pr), None, &format!("Review of pull request {}.", pr_items::pr_summary(pr)))
}

/// Whether the PR's Review chat runs, in a pane or outside one. Starts and creates nothing.
pub fn live(pr: &Value) -> Res<bool> {
    let items = WorkItem::all()?;
    let Some(item) = pr_items::review_item(pr, &items) else { return Ok(false) };
    Ok(Tmux::new().live(&item.slug) || launcher::chat_plan(item, true, None, None).is_some_and(|plan| matches!(plan.mode, Mode::Live)))
}

/// Opens the Review item's chat: `{"slug", "attached": true}` when its pane already runs, else `{"slug",
/// "mode": "start"}`. `extra_argv` goes before the kickoff prompt, which stays the last argument;
/// `kickoff_suffix` is appended to the kickoff as a paragraph of its own. The error is the user's message.
pub fn start(pr: &Value, extra_argv: &[String], kickoff_suffix: Option<&str>) -> Result<Value, String> {
    let mut item = item_for(pr).map_err(|e| e.message)?;
    let tmux = Tmux::new();
    if tmux.live(&item.slug) {
        return Ok(json!({"slug": item.slug, "attached": true}));
    }
    if item.state().as_deref() == Some("resolved") {
        item.update_state("in_progress").map_err(|e| e.message)?;
    }
    let plan = launcher::chat_plan(&item, true, None, None).ok_or("QM_CHAT_COMMAND is quoted in a way this qm can't read")?;
    if matches!(plan.mode, Mode::Live) {
        return Err(format!("{} has a chat running outside the GUI — review from there, or end it first", item.slug));
    }
    let argv: Vec<String> = plan.argv.iter().cloned().chain(extra_argv.iter().cloned()).chain([kickoff(pr, &item.slug, kickoff_suffix)]).collect();
    tmux.open(&item.slug, &plan.cwd, &argv, &plan.env)?;
    Ok(json!({"slug": item.slug, "mode": "start"}))
}

fn kickoff(pr: &Value, slug: &str, suffix: Option<&str>) -> String {
    let skill = crate::project_config::ProjectConfig::current().review_skill(Some(&project_for(pr)));
    let text = pr_items::review_kickoff(&skill, pr, slug);
    match suffix.map(crate::ruby_text::strip).filter(|s| !s.is_empty()) {
        Some(suffix) => format!("{text}\n\n{suffix}"),
        None => text,
    }
}
