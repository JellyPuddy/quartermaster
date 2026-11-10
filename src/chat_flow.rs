//! A local automation's run as a chat of its own: tmux session `<slug>--run-<run id>` on qm's socket, running
//! claude as a chat does (QM_ITEM is the automation, every CLAUDE* var unset by `Tmux`) with qm's session id,
//! the yml's flags and the prompt as claude's argument.

use serde_json::Value;

use crate::automation_flows::{flags, Reply};
use crate::automation_store::Entry;
use crate::run_fold::Run;
use crate::tmux::Tmux;
use crate::work_item::WorkItem;

pub const SEPARATOR: &str = "--run-";

pub fn tmux_name(slug: &str, run_id: &str) -> String {
    format!("{slug}{SEPARATOR}{run_id}")
}

/// The prompt file, then the item as given under a final `## Item`.
pub fn prompt_with_item(prompt: &str, item: &Value) -> String {
    if item.is_null() {
        return prompt.to_string();
    }
    let text = format!("{}\n\n## Item\n\n{}", crate::ruby_text::rstrip(prompt), item_text(item));
    text.trim_start_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r']).to_string()
}

/// A guard's plain line comes back as that line; a JSON item pretty-printed.
pub fn item_text(item: &Value) -> String {
    if let Value::Object(map) = item {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        if keys == ["key", "line"] && map["key"] == map["line"] {
            return map["line"].as_str().map(String::from).unwrap_or_else(|| map["line"].to_string());
        }
    }
    serde_json::to_string_pretty(item).unwrap_or_default()
}

fn command() -> Result<Vec<String>, String> {
    crate::launcher::chat_command().ok_or_else(|| "QM_CHAT_COMMAND is quoted in a way this qm can't read".to_string())
}

pub fn start(automation: &Entry, item: &Value, prompt: &str, run_id: &str, session_id: &str) -> Result<Reply, String> {
    let name = tmux_name(&automation.slug, run_id);
    let mut argv = command()?;
    argv.extend(flags(&automation.record, session_id));
    argv.push(prompt_with_item(prompt, item));
    let env = [("QM_ITEM".to_string(), automation.slug.clone())];
    if !Tmux::new().open(&name, &cwd(automation), &argv, &env)? {
        return Err(format!("tmux session {name} is already running"));
    }
    Ok(Reply::Started { item_slug: automation.slug.clone(), tmux: name })
}

/// An ended run's session again (the tab's Resume): `--resume` in a tmux of the run's own name; answers that name.
pub fn resume(automation: &Entry, run: &Run) -> Result<String, String> {
    let name = tmux_name(&automation.slug, &run.id);
    let session = run.session_id.clone().ok_or_else(|| format!("run {} has no session to resume", run.id))?;
    let mut argv = command()?;
    argv.extend(["--resume".to_string(), session]);
    let env = [("QM_ITEM".to_string(), automation.slug.clone())];
    if !Tmux::new().open(&name, &cwd(automation), &argv, &env)? {
        return Err(format!("run {}'s chat is already open", run.id));
    }
    Ok(name)
}

/// The yml's cwd, else the automation's project root, else home.
pub fn cwd(automation: &Entry) -> String {
    let set = automation.record.get("cwd").and_then(Value::as_str).unwrap_or("");
    if !set.is_empty() {
        return crate::data_root::expand_path(set).to_string_lossy().into_owned();
    }
    let project = WorkItem::find(&automation.slug).ok().and_then(|item| item.project());
    let root = project.and_then(|p| crate::project_map::root_for(Some(&p)));
    match root {
        Some(root) if std::path::Path::new(&root).is_dir() => root,
        _ => crate::data_root::home(),
    }
}
