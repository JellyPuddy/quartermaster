//! An automation's chat (`qm automation new` / `edit`, the GUI's automation-chat action): the item's ordinary
//! tmux chat, started or resumed with a brief qm writes — the item, its two local files, its runner's edit →
//! try → run loop and the house rules — as claude's argument. A live chat is only shown again: the brief comes
//! back for the caller to print, never typed into it.

use serde_json::{json, Value};

use crate::automation_store::{AutomationStore, Record};
use crate::error::{QmError, Res};
use crate::item_deletion::PLACEHOLDER;
use crate::launcher::{self, Mode, Plan};
use crate::run_log::RunLog;
use crate::tmux::Tmux;
use crate::work_item::WorkItem;

const HOUSE_RULES: &str = include_str!("../docs/automations-house-rules.md");
const ROUTINE_URL: &str = "https://claude.ai/code/routines/";
pub const RUNNERS: [&str; 2] = ["cloud", "local"];

/// A `kind: automation` item and its empty local files, under the work-item lock: a cloud one enabled, with no
/// routine until the first push; a local one disabled until the user enables it.
pub fn create(title: &str, project: &str, description: Option<&str>, runner: &str, store: &AutomationStore) -> Res<WorkItem> {
    if !RUNNERS.contains(&runner) {
        return Err(QmError::argument(format!("runner is {}, got {runner}", RUNNERS.join(" or "))));
    }
    let slug = WorkItem::slugify(title);
    if store.exists(&slug) {
        return Err(QmError::argument(format!("automation files for '{slug}' already exist in {}", store.dir().display())));
    }
    WorkItem::with_lock(|| {
        let mut item = WorkItem::create(title, project, None, None, description, None)?;
        item.make_automation(runner)?;
        let record: Record = json!({"runner": runner, "name": title, "enabled": runner == "cloud"}).as_object().cloned().unwrap_or_default();
        store.write(&item.slug, &record, "")?;
        Ok(item)
    })
}

/// The brief the item's chat starts with.
pub fn brief(item: &WorkItem, store: &AutomationStore) -> Res<String> {
    if item.runner().as_deref() == Some("local") {
        return local_brief(item, store);
    }
    let routine = match item.routine() {
        Some(id) => format!("Its routine is {id} ({ROUTINE_URL}{id})."),
        None => "It has no routine yet: the first push creates it.".to_string(),
    };
    let (slug, prompt, yml) = (&item.slug, store.prompt_path(&item.slug)?, store.yml_path(&item.slug)?);
    Ok(format!(
        "You are working on the qm automation \"{title}\" (work item {slug}, project {project}): a claude.ai cloud routine that qm manages. {routine}\n\n## Its files\n\n- Prompt: {prompt} (the routine's prompt, nothing else)\n- Settings: {yml} (name, cron in UTC, model, sources, connectors, allowed_tools, environment_id, enabled; keep `v:` and any key you don't know)\n\n## The loop\n\n1. Edit the two files.\n2. `qm automation push {slug}` sends them to the routine (the first push creates it).\n3. `qm automation run {slug}` runs it now.\n4. Read the run: its claude.ai link (`qm automation show {slug}`) or RemoteTrigger get_run_log.\n5. Refine and repeat.\n\nNever call RemoteTrigger create or update yourself: push is the only way a change reaches the routine.\n{tail}\n",
        title = item.title(),
        project = item.project().unwrap_or_default(),
        prompt = prompt.display(),
        yml = yml.display(),
        tail = brief_tail(item),
    ))
}

/// A local automation's brief: the same frame, its own loop — a dry-run tick, a run, its transcript — and
/// nothing to push.
pub fn local_brief(item: &WorkItem, store: &AutomationStore) -> Res<String> {
    let (slug, prompt, yml) = (&item.slug, store.prompt_path(&item.slug)?, store.yml_path(&item.slug)?);
    Ok(format!(
        "You are working on the qm automation \"{title}\" (work item {slug}, project {project}): a local automation, a Claude Code run that qm starts on this machine on a schedule. It runs unattended, with the user's own permissions. It was created disabled: its cron and guard don't run until it is enabled with `qm automation resume {slug}`.\n\n## Its files\n\n- Prompt: {prompt} (the run's prompt, nothing else; each guard item is appended to it as a final `## Item` section)\n- Settings: {yml} (name, cron in Europe/Amsterdam local time, enabled, when (the guard command), flow, repos (required for flow pr-review: the owner/name repos it may review; an unattended review reads PR text others wrote, so a PR in any other repo is refused), cwd, model, allowed_tools, permission_mode, timeout_minutes, notify; keep `v:` and any key you don't know)\n\n## The loop\n\n1. Edit the two files.\n2. `qm automation tick --dry-run {slug}` runs the guard and prints the items a run would be queued for; it writes nothing.\n3. `qm automation run {slug}` queues a run now; a tick starts it.\n4. Read the run: `qm automation runs {slug}` lists its runs with their session ids; `qm show-session SESSION_ID` shows one, and its transcript is `~/.claude/projects/*/SESSION_ID.jsonl`.\n5. Refine and repeat.\n\nNothing to push: qm reads the two files on every tick.\n{tail}\n",
        title = item.title(),
        project = item.project().unwrap_or_default(),
        prompt = prompt.display(),
        yml = yml.display(),
        tail = brief_tail(item),
    ))
}

/// The brief's end, the same for every runner: how to record decisions, the house rules verbatim, the item's
/// description and its notes (oldest first).
pub fn brief_tail(item: &WorkItem) -> String {
    let notes: Vec<String> = item.notes().into_iter().rev().map(|n| format!("- {} [{}]: {}", n.stamp, n.kind, n.text)).collect();
    let description = item.description();
    let description = if description.is_empty() || description == PLACEHOLDER { "_none yet_".to_string() } else { description };
    let notes = if notes.is_empty() { "_none yet_".to_string() } else { notes.join("\n") };
    format!("Record each decision as a note on the item: `qm note {} --kind decision \"...\"`.\n\n## House rules\n\n{}\n\n## Description\n\n{description}\n\n## Notes\n\n{notes}", item.slug, crate::ruby_text::strip(HOUSE_RULES))
}

/// The automation's item, or an error when the slug names a plain item.
pub fn automation(slug: &str) -> Res<WorkItem> {
    let item = WorkItem::find(slug)?;
    if !item.automation() {
        return Err(QmError::argument(format!("{} is not an automation (kind: automation)", item.slug)));
    }
    Ok(item)
}

/// Opens the item's chat: `{"ok", "mode"}` once started or resumed, `{"ok", "attached", "brief"}` when it
/// already runs.
pub fn open(slug: &str, store: &AutomationStore) -> Res<Value> {
    let item = automation(slug)?;
    let tmux = Tmux::new();
    if tmux.live(&item.slug) {
        return Ok(json!({"ok": true, "attached": true, "brief": brief(&item, store)?}));
    }
    let plan = plan(&item, store)?;
    if matches!(plan.mode, Mode::Live) {
        return Err(QmError::argument(format!("{} has a chat running outside the GUI — take it over once it ends", item.slug)));
    }
    tmux.open(&item.slug, &plan.cwd, &plan.argv, &plan.env).map_err(QmError::argument)?;
    Ok(json!({"ok": true, "mode": plan.mode.name()}))
}

/// The chat's launch plan with the brief as claude's last argument: a fresh chat when the item has none, else
/// its newest one resumed. A local automation's runs attach to its item too, but are never its chat (the
/// launcher skips them as well).
pub fn plan(item: &WorkItem, store: &AutomationStore) -> Res<Plan> {
    let brief = brief(item, store)?;
    let runs = RunLog::session_ids_for(item, store.dir());
    let fresh = item.session_ids().iter().all(|id| runs.contains(id));
    let mut plan = launcher::chat_plan(item, fresh, None, Some(&brief)).ok_or_else(|| QmError::argument("QM_CHAT_COMMAND is quoted in a way this qm can't read"))?;
    if !matches!(plan.mode, Mode::Live) && plan.argv.last() != Some(&brief) {
        plan.argv.push(brief);
    }
    Ok(plan)
}
