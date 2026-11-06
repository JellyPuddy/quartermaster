//! The Issues pane and view: an item's issue drafts with the GitHub repo their numbers link into
//! (`Gui#issues_payload`), and every item's drafts in one list (`IssueIndex`).

use serde_json::{json, Value};

use crate::data_root;
use crate::issue_drafts;
use crate::work_item::{WorkItem, STATES};

fn slug_shaped(slug: &str) -> bool {
    slug.chars().next().is_some_and(|c| c.is_ascii_alphanumeric()) && slug.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

fn repo(project: Option<&str>) -> Option<String> {
    crate::project_map::root_for(project).and_then(|root| crate::branch_diff::github_repo(&root))
}

/// `GET /api/issues/<slug>`; `None` for what only Ruby reads exactly.
pub fn payload(slug: &str) -> Option<Value> {
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) => {
            if e.class != "ArgumentError" {
                data_root::log_error("gui-issues", e.class, &e.message);
            }
            return Some(json!({"ok": false, "error": e.message}));
        }
    };
    if !slug_shaped(&item.slug) {
        return Some(json!({"ok": false, "error": format!("'{}' is not a work item slug", item.slug)}));
    }
    let mut out = json!({"ok": true, "slug": item.slug, "repo": repo(item.project().as_deref())});
    for (k, v) in issue_drafts::read(&item.slug)?.as_object().cloned().unwrap_or_default() {
        out[k] = v;
    }
    Some(out)
}

/// `GET /api/issues`: one entry per work item whose issues directory holds a draft or a broken file.
pub fn index() -> Option<Value> {
    let Ok(dirs) = std::fs::read_dir(data_root::root().join("issues")) else { return Some(json!({"ok": true, "items": []})) };
    let mut slugs: Vec<String> = vec![];
    for d in dirs.filter_map(|e| e.ok()) {
        let name = d.file_name().into_string().ok()?;
        if d.path().is_dir() && slug_shaped(&name) {
            slugs.push(name);
        }
    }
    slugs.sort();
    let mut repos: Vec<(Option<String>, Option<String>)> = vec![];
    let mut entries: Vec<(usize, f64, i64, String, Value)> = vec![];
    for slug in slugs {
        let files = issue_drafts::files(&slug)?;
        if files.is_empty() {
            continue;
        }
        let Ok(item) = WorkItem::find(&slug) else { continue };
        let data = issue_drafts::read(&slug)?;
        let project = item.project();
        let repo = match repos.iter().find(|(p, _)| *p == project) {
            Some((_, r)) => r.clone(),
            None => {
                let r = repo(project.as_deref());
                repos.push((project.clone(), r.clone()));
                r
            }
        };
        let changed = files
            .iter()
            .filter_map(|f| std::fs::metadata(issue_drafts::dir(&slug).join(f)).and_then(|m| m.modified()).ok())
            .map(crate::clock::epoch_f64)
            .fold(None, |best: Option<f64>, t| Some(best.map_or(t, |b| b.max(t))))
            .unwrap_or(0.0);
        let issues: Vec<Value> = data["issues"].as_array().cloned().unwrap_or_default().into_iter().map(|i| json!({"file": i["file"], "title": i["title"], "kind": i["kind"], "number": i["number"], "created": i["created"]})).collect();
        let state = item.state();
        let rank = state.as_deref().and_then(|s| STATES.iter().position(|x| *x == s)).unwrap_or(STATES.len());
        let stamp = chrono::DateTime::<chrono::Utc>::from_timestamp(changed.floor() as i64, 0).map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)).unwrap_or_default();
        entries.push((rank, -changed, 0, slug.clone(), json!({"slug": slug, "title": item.title(), "state": state, "repo": repo, "changed_at": stamp, "issues": issues, "errors": data["errors"]})));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)).then(a.3.cmp(&b.3)));
    Some(json!({"ok": true, "items": entries.into_iter().map(|e| e.4).collect::<Vec<_>>()}))
}
