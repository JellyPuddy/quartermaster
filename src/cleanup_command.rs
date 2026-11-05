//! `qm cleanup SLUG` (the plan only) and the resolve hint `state … resolved` prints. Removing anything
//! — `--yes`, `--force`, the sweep — stays in Ruby.

use crate::cleanup::{plan_item, Entry};
use crate::cli_format::{paint, puts, short_path};
use crate::data_root;
use crate::outcome::{abort, done, Outcome};
use crate::work_item::WorkItem;

/// Drafts::SLUG: `\A[a-z0-9][\w.-]*\z`, case-insensitive.
pub fn valid_slug(slug: &str) -> bool {
    let mut chars = slug.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphanumeric()) && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

/// Whether the plan must be Ruby's: a slug IssueDrafts would refuse, or issue-draft files this port
/// can't read exactly as Ruby does (checked before anything is written).
pub fn leaves_to_ruby(slug: &str) -> bool {
    !crate::issue_drafts::supported(slug)
}

/// Resolving is when worktrees go stale, so say what cleanup would do — a hint only: a failing plan
/// must never fail the resolve.
pub fn offer(item: &WorkItem) -> String {
    match plan_item(item) {
        Ok(plan) if !plan.is_empty() => puts(&format!("cleanup: {} — qm cleanup {}", plan.summary(), item.slug)),
        Ok(_) => String::new(),
        Err(e) => {
            data_root::log_error("cleanup-offer", e.class, &e.message);
            String::new()
        }
    }
}

fn line(entry: &Entry) -> String {
    let (mark, color) = match entry.status {
        "warn" => ("⚠ ", 33),
        "blocked" => ("⛔ ", 31),
        _ => ("", 0),
    };
    let target = if entry.is_worktree() {
        short_path(entry.path.as_deref())
    } else if entry.is_issue_draft() {
        let file = std::path::Path::new(entry.path.as_deref().unwrap_or("")).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
        format!("{}/{file}", entry.item.clone().unwrap_or_default())
    } else {
        entry.branch.clone().unwrap_or_default()
    };
    let head = if entry.is_worktree() {
        format!(" ({})", entry.branch.clone().unwrap_or_else(|| "detached".into()))
    } else if entry.is_issue_draft() {
        format!(" “{}”", entry.title.clone().unwrap_or_default())
    } else {
        String::new()
    };
    let dbs = match &entry.db_names {
        Some(names) if !names.is_empty() => format!(" · test DBs: {}", names.join(", ")),
        _ => String::new(),
    };
    let details = entry.reasons.iter().chain(&entry.notes).cloned().collect::<Vec<_>>().join("; ");
    let line = format!("  [{}] {} {target}{head}{dbs}", if entry.ticked { "x" } else { " " }, paint(&format!("{mark}{}", entry.kind), color));
    if details.is_empty() { line } else { format!("{line} — {details}") }
}

pub fn cleanup(a: &[String]) -> Outcome {
    let [slug] = a else { return Outcome::Delegate };
    if slug.starts_with('-') || leaves_to_ruby(slug) {
        return Outcome::Delegate;
    }
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) => return abort(&format!("qm: {}", e.message)),
    };
    let plan = match plan_item(&item) {
        Ok(p) => p,
        Err(e) => return abort(&format!("qm: {}", e.message)),
    };
    let mut out = String::new();
    for note in &plan.notes {
        out.push_str(&puts(&paint(note, 90)));
    }
    out.push_str(&puts(&format!("{}: {}", plan.scope, plan.summary())));
    for e in &plan.entries {
        out.push_str(&puts(&line(e)));
    }
    if !plan.is_empty() {
        out.push_str(&puts(&paint("--yes removes the [x] entries; --force PATH|BRANCH|SLUG/FILE adds a ⚠ one", 90)));
    }
    done(out)
}

#[cfg(test)]
mod tests {
    use super::valid_slug;

    #[test]
    fn slugs_are_what_drafts_accept() {
        for ok in ["a", "fix-login-bug", "A1_b.c-d", "9x"] {
            assert!(valid_slug(ok), "{ok}");
        }
        for bad in ["", "-a", ".a", "a b", "a/b", "é"] {
            assert!(!valid_slug(bad), "{bad:?}");
        }
    }
}
