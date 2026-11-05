use std::fs::{self, OpenOptions};
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;

use serde_yaml::{Mapping, Value};

use crate::data_root;
use crate::error::{QmError, Res};
use crate::front_edit;
use crate::note::Note;
use crate::ruby_text::strip;
use crate::yaml_scalar::{array, get, text};

pub const INJECTED_NOTES: usize = 5;
pub const INJECTED_OPEN_NOTES: usize = 3;

pub struct WorkItem {
    pub slug: String,
    front: Mapping,
    body: String,
    front_text: String,
}

fn split(slug: &str, contents: &str) -> Res<(String, String)> {
    let malformed = || QmError::argument(format!("malformed work item file {}", WorkItem::path_for(slug).display()));
    let rest = contents.strip_prefix("---\n").ok_or_else(malformed)?;
    let at = rest.find("\n---\n").ok_or_else(malformed)?;
    Ok((rest[..at].to_string(), rest[at + 5..].to_string()))
}

fn parse_front(front_text: &str) -> Res<Mapping> {
    match serde_yaml::from_str::<Value>(front_text)? {
        Value::Mapping(m) => Ok(m),
        _ => Ok(Mapping::new()),
    }
}

impl WorkItem {
    pub fn path_for(slug: &str) -> PathBuf {
        data_root::work_items_dir().join(format!("{slug}.md"))
    }

    pub fn find(slug: &str) -> Res<WorkItem> {
        let path = Self::path_for(slug);
        let contents = fs::read_to_string(&path).map_err(|_| QmError::argument(format!("no work item '{slug}'")))?;
        let (front_text, body) = split(slug, &contents)?;
        Ok(WorkItem { slug: slug.to_string(), front: parse_front(&front_text)?, body, front_text })
    }

    /// Every item, in file-name order.
    pub fn all() -> Res<Vec<WorkItem>> {
        let Ok(dir) = fs::read_dir(data_root::work_items_dir()) else { return Ok(vec![]) };
        let mut names: Vec<String> = dir
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".md") && !n.starts_with('.'))
            .collect();
        names.sort();
        names.iter().map(|n| Self::find(n.trim_end_matches(".md"))).collect()
    }

    fn field(&self, key: &str) -> Option<String> {
        get(&self.front, key).map(text)
    }

    pub fn title(&self) -> String {
        self.field("title").unwrap_or_default()
    }
    pub fn state(&self) -> Option<String> {
        self.field("state")
    }
    pub fn project(&self) -> Option<String> {
        self.field("project")
    }
    pub fn created(&self) -> Option<String> {
        self.field("created")
    }
    pub fn board(&self) -> Option<String> {
        self.field("board")
    }
    pub fn pf_mode_override(&self) -> Option<String> {
        self.field("pf_mode")
    }

    pub fn session_ids(&self) -> Vec<String> {
        array(get(&self.front, "sessions"))
            .into_iter()
            .filter_map(|s| match s {
                Value::Mapping(m) => get(m, "id").map(text),
                _ => None,
            })
            .collect()
    }

    pub fn session_count(&self) -> usize {
        array(get(&self.front, "sessions")).len()
    }

    pub fn branches(&self) -> Vec<String> {
        let v = get(&self.front, "branches").or_else(|| get(&self.front, "branch"));
        array(v).into_iter().map(text).collect()
    }

    pub fn temp_branches(&self) -> Vec<String> {
        array(get(&self.front, "temp_branches")).into_iter().map(text).collect()
    }

    fn section_body(&self, heading: &str) -> String {
        let lines: Vec<&str> = self.body.split_inclusive('\n').collect();
        let Some(idx) = lines.iter().position(|l| l.starts_with(heading)) else { return String::new() };
        let end = (idx + 1..lines.len()).find(|&i| lines[i].starts_with("## ")).unwrap_or(lines.len());
        lines[idx + 1..end].concat()
    }

    pub fn description(&self) -> String {
        strip(&self.section_body("## Description")).to_string()
    }

    /// Newest first; `position` is the 1-based place in the file.
    pub fn notes(&self) -> Vec<Note> {
        let mut stored = vec![];
        for line in self.section_body("## Notes").split_inclusive('\n') {
            if let Some(note) = Note::parse(line, stored.len() + 1) {
                stored.push(note);
            }
        }
        stored.reverse();
        stored
    }

    /// Every open note (newest few) plus the newest non-history notes, returned oldest first.
    pub fn injectable_notes(&self) -> Vec<Note> {
        let carried: Vec<Note> = self.notes().into_iter().filter(|n| !n.is_history()).collect();
        let open: Vec<usize> = (0..carried.len()).filter(|&i| carried[i].is_open()).take(INJECTED_OPEN_NOTES).collect();
        let recent: Vec<usize> = (0..carried.len()).take(INJECTED_NOTES).collect();
        let mut chosen: Vec<usize> = open;
        for i in recent {
            if !chosen.contains(&i) {
                chosen.push(i);
            }
        }
        chosen.sort();
        chosen.reverse();
        chosen.into_iter().map(|i| carried[i].clone()).collect()
    }

    pub fn snapshot_count(&self) -> usize {
        let section = self.section_body("## Snapshots");
        let mut pieces: Vec<String> = vec![String::new()];
        for line in section.split_inclusive('\n') {
            if let Some(rest) = line.strip_prefix("### ") {
                pieces.push(rest.to_string());
            } else {
                pieces.last_mut().unwrap().push_str(line);
            }
        }
        pieces.iter().filter(|p| !strip(p).is_empty()).count()
    }

    // ---- the three writes the capture hooks make

    /// Runs `f` under the global work-item flock, as the Ruby `WorkItem.with_lock`.
    fn with_lock<T>(f: impl FnOnce() -> Res<T>) -> Res<T> {
        data_root::ensure_setup()?;
        let lock = OpenOptions::new().create(true).truncate(false).write(true).open(data_root::work_items_dir().join(".lock"))?;
        // SAFETY: the descriptor stays open until `lock` drops after `f` returns.
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        f()
    }

    /// Re-reads the file under the lock, applies `edit` to the front lines, validates and saves.
    fn edit_front(&mut self, edit: impl FnOnce(&WorkItem, &mut Vec<String>) -> Res<bool>) -> Res<bool> {
        Self::with_lock(|| {
            let fresh = Self::find(&self.slug)?;
            let mut lines: Vec<String> = fresh.front_text.lines().map(String::from).collect();
            if !edit(&fresh, &mut lines)? {
                *self = fresh;
                return Ok(false);
            }
            let front_text = lines.join("\n");
            let front = parse_front(&front_text)
                .map_err(|e| QmError::new("RuntimeError", format!("refusing to write unparsable front matter: {e}")))?;
            let contents = format!("---\n{front_text}\n---\n{}", fresh.body);
            let path = Self::path_for(&self.slug);
            let temp = path.with_file_name(format!(".{}.md.tmp-{}", self.slug, std::process::id()));
            fs::write(&temp, contents)?;
            fs::rename(&temp, &path)?;
            *self = WorkItem { slug: fresh.slug, front, body: fresh.body, front_text };
            Ok(true)
        })
    }

    pub fn attach_session(&mut self, session_id: &str) -> Res<bool> {
        let id = session_id.to_string();
        self.edit_front(move |fresh, lines| {
            if fresh.session_ids().contains(&id) {
                return Ok(false);
            }
            front_edit::push_item(lines, "sessions", vec![format!("- id: {}", front_edit::scalar(&id))])?;
            Ok(true)
        })
    }

    pub fn detach_session(&mut self, session_id: &str) -> Res<bool> {
        let id = session_id.to_string();
        self.edit_front(move |fresh, lines| {
            if !fresh.session_ids().contains(&id) {
                return Ok(false);
            }
            let (at, end) = front_edit::block(lines, "sessions").expect("sessions present");
            if lines[at] != "sessions:" {
                return Err(QmError::new("RuntimeError", "front matter 'sessions' is not a block list; edit it with the Ruby qm"));
            }
            let mut keep: Vec<String> = vec![];
            for (s, e) in front_edit::items(lines, at, end) {
                let entry = lines[s..e].join("\n");
                let listed = serde_yaml::from_str::<Value>(&entry).ok().and_then(|v| match v {
                    Value::Sequence(items) => items.first().and_then(|i| i.as_mapping().and_then(|m| get(m, "id").map(text))),
                    _ => None,
                });
                if listed.as_deref() != Some(id.as_str()) {
                    keep.extend(lines[s..e].iter().cloned());
                }
            }
            let replacement = if keep.is_empty() { vec!["sessions: []".to_string()] } else { [vec!["sessions:".to_string()], keep].concat() };
            lines.splice(at..end, replacement);
            Ok(true)
        })
    }

    pub fn add_temp_branch(&mut self, branch: &str) -> Res<bool> {
        let branch = branch.to_string();
        self.edit_front(move |fresh, lines| {
            if fresh.branches().contains(&branch) || fresh.temp_branches().contains(&branch) {
                return Ok(false);
            }
            front_edit::push_item(lines, "temp_branches", vec![format!("- {}", front_edit::scalar(&branch))])?;
            Ok(true)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(front: &str, body: &str) -> WorkItem {
        WorkItem { slug: "t".into(), front: parse_front(front).unwrap(), body: body.into(), front_text: front.into() }
    }

    const BODY: &str = "\n## Description\n\nDesc line.\n\n## Notes\n- 2026-01-01: a\n- 2026-01-02 [open]: b\n- 2026-01-03 [history]: c\nfree text\n- 2026-01-04: d\n\n## Snapshots\n\n### 2026-01-05 — session s1\n\ntext\n";

    #[test]
    fn reads_front_matter_fields_with_the_legacy_branch_key() {
        let i = item("title: T\nstate: fridge\nbranch: old\nsessions:\n- id: s1\n- id: s2\n", "");
        assert_eq!((i.title().as_str(), i.state().as_deref()), ("T", Some("fridge")));
        assert_eq!(i.branches(), vec!["old"]);
        assert_eq!((i.session_ids(), i.session_count()), (vec!["s1".to_string(), "s2".to_string()], 2));
        assert!(i.board().is_none() && i.project().is_none());
    }

    #[test]
    fn sections_notes_and_snapshots() {
        let i = item("title: T", BODY);
        assert_eq!(i.description(), "Desc line.");
        let notes = i.notes();
        assert_eq!(notes.iter().map(|n| n.position).collect::<Vec<_>>(), vec![4, 3, 2, 1]);
        assert_eq!(i.snapshot_count(), 1);
    }

    #[test]
    fn injectable_notes_window_open_notes_and_drop_history() {
        let mut body = String::from("## Notes\n- 2026-01-01 [open]: old blocker\n");
        for n in 0..8 {
            body.push_str(&format!("- 2026-01-02: n{n}\n"));
        }
        body.push_str("- 2026-01-03 [history]: mechanics\n");
        let shown = item("title: T", &body).injectable_notes();
        let texts: Vec<&str> = shown.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(texts, vec!["old blocker", "n3", "n4", "n5", "n6", "n7"]);
    }

    #[test]
    fn split_requires_both_fences() {
        assert!(split("t", "no front matter").is_err());
        assert!(split("t", "---\ntitle: T\nbody").is_err());
        assert_eq!(split("t", "---\ntitle: T\n---\nbody\n").unwrap(), ("title: T".into(), "body\n".into()));
    }
}
