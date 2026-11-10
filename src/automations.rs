//! What the CLI and the GUI do with automations: each one is a local store entry plus a `kind: automation` work
//! item of the same slug. The local files are the source of truth and push is the one path that changes a
//! routine: it refuses when the routine moved since the last sync (unless forced), records the routine's new
//! updated_at, appends a history note naming what changed and moves the item's state with the routine (enabled
//! → active, paused → fridge). Every network call goes through the `Routines` client, whose errors are
//! user-facing.

use serde_json::{json, Map, Value};

use crate::automation_store::{from_routine, AutomationStore, Entry};
use crate::error::{QmError, Res};
use crate::local_automations::{self, item_or_none, LocalAutomations};
use crate::routines_client::{self as rc, Deleted, Routines};
use crate::work_item::WorkItem;

pub use crate::automation_fields::{drift, STALE};
use crate::automation_fields::{changed_fields, check_fresh, connectors_of, describe_change, draft_description, fields_of, get, label, record, update_fields, LIST_FIELDS};

/// A store entry and its work item (none when the item is gone).
pub struct Row {
    pub slug: String,
    pub entry: Entry,
    pub item: Option<WorkItem>,
}

/// A cloud row with its routine (none when it isn't on claude.ai) and whether it drifted.
pub struct Status {
    pub row: Row,
    pub remote: Option<Value>,
    pub drift: bool,
}

pub struct Overview {
    pub rows: Vec<Status>,
    /// Routines with no local files.
    pub unmanaged: Vec<Value>,
}

pub struct CloudDetail {
    pub slug: String,
    pub entry: Entry,
    pub item: Option<WorkItem>,
    pub remote: Option<Value>,
    pub drift: bool,
    pub runs: Vec<Value>,
}

pub enum Detail {
    Cloud(Box<CloudDetail>),
    Local(Box<local_automations::Detail>),
}

#[derive(Debug)]
pub struct Pushed {
    pub created: bool,
    pub changes: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Removed {
    Deleted,
    /// The API has no delete: the routine is paused and its files stay.
    Paused,
    /// Never pushed: only the files went.
    Local,
}

pub struct Automations<'a> {
    client: &'a dyn Routines,
    store: AutomationStore,
    local: LocalAutomations,
}

fn arg(message: impl Into<String>) -> QmError {
    QmError::argument(message)
}


fn text<'a>(entry: &'a Entry, key: &str) -> Option<&'a str> {
    entry.record.get(key).and_then(Value::as_str)
}

impl<'a> Automations<'a> {
    pub fn new(client: &'a dyn Routines, store: AutomationStore) -> Automations<'a> {
        let local = LocalAutomations::new(store.dir());
        Automations { client, store, local }
    }

    pub fn store(&self) -> &AutomationStore {
        &self.store
    }

    pub fn local_automations(&self) -> &LocalAutomations {
        &self.local
    }

    /// Every local automation, without touching the network.
    pub fn local(&self) -> Res<Vec<Row>> {
        Ok(self.store.list()?.into_iter().map(|entry| Row { slug: entry.slug.clone(), item: item_or_none(&entry.slug), entry }).collect())
    }

    /// The cloud rows merged with one list call; `runner: local` rows have no routine and are left out.
    pub fn overview(&self, rows: Vec<Row>) -> Res<Overview> {
        let routines = self.client.list()?;
        let rows: Vec<Row> = rows.into_iter().filter(|row| !local_automations::local(&row.entry)).collect();
        let managed: Vec<String> = rows.iter().filter_map(|row| text(&row.entry, "routine").map(String::from)).collect();
        let statuses = rows
            .into_iter()
            .map(|row| {
                let remote = text(&row.entry, "routine").and_then(|id| routines.iter().find(|r| r["id"] == id)).cloned();
                let drift = drift(&row.entry, remote.as_ref());
                Status { row, remote, drift }
            })
            .collect();
        let unmanaged = routines.into_iter().filter(|r| !managed.iter().any(|id| r["id"] == id.as_str())).collect();
        Ok(Overview { rows: statuses, unmanaged })
    }

    /// One automation with its routine and its last `limit` runs.
    pub fn detail(&self, slug: &str, limit: usize) -> Res<Detail> {
        let entry = self.entry(slug)?;
        if local_automations::local(&entry) {
            return Ok(Detail::Local(Box::new(self.local.detail(slug)?)));
        }
        let id = text(&entry, "routine").map(String::from);
        let remote = id.as_deref().map(|id| self.client.get(id)).transpose()?;
        let runs = match &id {
            Some(id) => self.client.runs(id, limit)?,
            None => vec![],
        };
        Ok(Detail::Cloud(Box::new(CloudDetail { slug: slug.to_string(), drift: drift(&entry, remote.as_ref()), item: item_or_none(slug), remote, runs, entry })))
    }

    /// Takes a routine with no local files under qm: the store entry and a `kind: automation` item whose
    /// description is the routine's name and its prompt's first paragraph.
    pub fn adopt(&self, id: &str, project: &str, slug: Option<&str>) -> Res<Entry> {
        if let Some(entry) = slug.map(|s| self.store.read(s)).transpose()?.flatten() {
            refuse_local(&entry)?;
        }
        if let Some(managed) = self.store.find_by_routine(id)? {
            return Err(arg(format!("{id} is already managed by qm as '{}'", managed.slug)));
        }
        let routine = self.client.get(id)?;
        let (record, prompt) = from_routine(&routine)?;
        let name = record.get("name").and_then(Value::as_str);
        let slug = slug.map(String::from).unwrap_or_else(|| WorkItem::slugify(name.unwrap_or("")));
        if self.store.exists(&slug) {
            return Err(arg(format!("automation '{slug}' already exists")));
        }
        let mut item = WorkItem::create_automation(&slug, name.unwrap_or(id), project, Some(&draft_description(name, &prompt)), Some(id))?;
        let entry = self.store.write(&slug, &record, &prompt)?;
        item.update_state(if record.get("enabled") == Some(&json!(true)) { "active" } else { "fridge" })?;
        Ok(entry)
    }

    /// A cloud `kind: automation` item under `slug`; `routine` is written once the routine exists.
    pub fn create_item(&self, slug: &str, title: &str, project: &str) -> Res<WorkItem> {
        WorkItem::create_automation(slug, title, project, None, None)
    }

    /// Sends the local files: creates the routine on the first push, else updates what differs. `recreate` makes a
    /// new routine for one deleted on claude.ai, and only then.
    pub fn push(&self, slug: &str, force: bool, recreate: bool) -> Res<Pushed> {
        let entry = self.entry(slug)?;
        refuse_local(&entry)?;
        let Some(id) = text(&entry, "routine").map(String::from) else {
            if recreate {
                return Err(arg(format!("{slug} has no routine yet: `qm automation push {slug}` creates it")));
            }
            return self.create(&entry, None);
        };
        let remote = match self.client.get(&id) {
            Ok(remote) => remote,
            Err(e) if e.class == rc::ROUTINE_MISSING && recreate => return self.create(&entry, Some(&id)),
            Err(e) if e.class == rc::ROUTINE_MISSING => {
                return Err(arg(format!("{slug}: {} (`qm automation delete {slug}`) or re-create it (`qm automation push {slug} --recreate`)", e.message)))
            }
            Err(e) => return Err(e),
        };
        if recreate {
            return Err(arg(format!("{slug}: routine {id} is still on claude.ai — `qm automation push {slug}` updates it")));
        }
        if !force {
            check_fresh(&entry, &remote)?;
        }
        let local = fields_of(&entry);
        let remote_fields = rc::fields(&remote)?;
        let changes: Vec<&str> = changed_fields(&local, &remote_fields).into_iter().filter(|f| !(get(&local, f).is_null() && !LIST_FIELDS.contains(f))).collect();
        let updated = if changes.is_empty() { remote } else { self.client.update(&id, &update_fields(&entry, &changes))? };
        self.store.write(slug, &record(json!({"remote_updated_at": get(updated.as_object().unwrap_or(&Map::new()), "updated_at")})), &entry.prompt)?;
        let notes = changes.iter().map(|f| describe_change(f, &entry)).collect();
        self.finish_push(slug, entry.record.get("enabled"), notes, false, None)
    }

    /// The routine overwrites the local files (each kept as `.bak`).
    pub fn pull(&self, slug: &str) -> Res<Vec<&'static str>> {
        let entry = self.entry(slug)?;
        refuse_local(&entry)?;
        let id = text(&entry, "routine").ok_or_else(|| arg(format!("{slug} has no routine yet: `qm automation push {slug}` creates it")))?;
        let (record, prompt) = from_routine(&self.client.get(id)?)?;
        let pulled = Entry { slug: slug.to_string(), record: record.clone(), prompt: prompt.clone() };
        let changes: Vec<&'static str> = changed_fields(&fields_of(&entry), &fields_of(&pulled)).into_iter().map(label).collect();
        self.store.write(slug, &record, &prompt)?;
        let mut item = WorkItem::find(slug)?;
        item.add_note(&format!("pulled from claude.ai: {}", if changes.is_empty() { "no changes".to_string() } else { changes.join(", ") }), "history")?;
        sync_state(&mut item, record.get("enabled"))?;
        Ok(changes)
    }

    pub fn pause(&self, slug: &str) -> Res<()> {
        if self.is_local(slug)? { self.local.pause(slug) } else { self.set_enabled(slug, false) }
    }

    /// `skip_existing` (local only): the guard's current items are marked seen; answers how many.
    pub fn resume(&self, slug: &str, skip_existing: bool) -> Res<usize> {
        if self.is_local(slug)? {
            return self.local.resume(slug, skip_existing, chrono::Utc::now());
        }
        if skip_existing {
            return Err(arg(format!("{slug}: --skip-existing is for local automations (they have a guard)")));
        }
        self.set_enabled(slug, true).map(|_| 0)
    }

    /// Runs the routine now (the API's reply); a local automation queues a manual run instead: see
    /// `LocalAutomations::run`.
    pub fn run(&self, slug: &str) -> Res<Value> {
        let entry = self.entry(slug)?;
        if local_automations::local(&entry) {
            return Ok(json!(self.local.run(slug, chrono::Utc::now())?));
        }
        let id = text(&entry, "routine").ok_or_else(|| arg(format!("{slug} has no routine yet: `qm automation push {slug}` creates it")))?;
        self.client.run(id)
    }

    /// Deletes the routine, or pauses it when the API has no delete; the item is resolved either way. A local
    /// automation is `LocalAutomations::delete`: refused while a run is live.
    pub fn delete(&self, slug: &str) -> Res<Removed> {
        let entry = self.entry(slug)?;
        if local_automations::local(&entry) {
            self.local.delete(slug)?;
            return Ok(Removed::Deleted);
        }
        let outcome = match text(&entry, "routine") {
            None => Removed::Local,
            Some(id) => match self.client.delete(id)? {
                Deleted::Deleted => Removed::Deleted,
                Deleted::Unsupported => self.pause_for_delete(&entry, id)?,
            },
        };
        if outcome != Removed::Paused {
            self.store.delete_local(slug)?;
        }
        if let Some(mut item) = item_or_none(slug) {
            item.add_note(if outcome == Removed::Paused { "paused on claude.ai (no delete in the API)" } else { "deleted" }, "history")?;
            item.update_state("resolved")?;
        }
        Ok(outcome)
    }

    fn entry(&self, slug: &str) -> Res<Entry> {
        self.store.read(slug)?.ok_or_else(|| arg(format!("no automation '{slug}'")))
    }

    fn is_local(&self, slug: &str) -> Res<bool> {
        Ok(local_automations::local(&self.entry(slug)?))
    }

    fn pause_for_delete(&self, entry: &Entry, id: &str) -> Res<Removed> {
        let mut fields = record(json!({"enabled": false}));
        fields.extend(connectors_of(entry));
        match self.client.update(id, &fields) {
            Ok(updated) => {
                let stamp = get(updated.as_object().unwrap_or(&Map::new()), "updated_at");
                self.store.write(&entry.slug, &record(json!({"enabled": false, "remote_updated_at": stamp})), &entry.prompt)?;
                Ok(Removed::Paused)
            }
            Err(e) if e.class == rc::ROUTINE_MISSING => Ok(Removed::Deleted),
            Err(e) => Err(e),
        }
    }

    /// The first push, or a re-create (`was` the deleted routine's id): the new routine's id and updated_at
    /// replace the stored ones.
    fn create(&self, entry: &Entry, was: Option<&str>) -> Res<Pushed> {
        let mut fields: Map<String, Value> = fields_of(entry).into_iter().filter(|(_, v)| !v.is_null()).collect();
        fields.extend(connectors_of(entry));
        let routine = self.client.create(&fields)?;
        let id = routine["id"].as_str().unwrap_or("").to_string();
        self.store.write(&entry.slug, &from_routine(&routine)?.0, &entry.prompt)?;
        let item = WorkItem::with_lock(|| {
            let mut fresh = WorkItem::find(&entry.slug)?;
            fresh.set_routine(&id)?;
            Ok(fresh)
        })?;
        let change = match was {
            Some(old) => format!("re-created routine {id} (was {old})"),
            None => format!("created routine {id}"),
        };
        self.finish_push(&entry.slug, entry.record.get("enabled"), vec![change], true, Some(item))
    }

    fn finish_push(&self, slug: &str, enabled: Option<&Value>, changes: Vec<String>, created: bool, item: Option<WorkItem>) -> Res<Pushed> {
        let mut item = match item {
            Some(item) => item,
            None => WorkItem::find(slug)?,
        };
        if !changes.is_empty() {
            item.add_note(&format!("pushed: {}", changes.join("; ")), "history")?;
        }
        sync_state(&mut item, enabled)?;
        Ok(Pushed { created, changes })
    }

    fn set_enabled(&self, slug: &str, enabled: bool) -> Res<()> {
        let entry = self.entry(slug)?;
        self.store.write(slug, &record(json!({"enabled": enabled})), &entry.prompt)?;
        self.push(slug, false, false).map(|_| ())
    }
}

fn refuse_local(entry: &Entry) -> Res<()> {
    if local_automations::local(entry) { Err(arg(format!("{} runs locally — nothing on claude.ai", entry.slug))) } else { Ok(()) }
}

fn sync_state(item: &mut WorkItem, enabled: Option<&Value>) -> Res<()> {
    let state = if enabled == Some(&json!(false)) { "fridge" } else { "active" };
    if item.state().as_deref() != Some(state) {
        item.update_state(state)?;
    }
    Ok(())
}

