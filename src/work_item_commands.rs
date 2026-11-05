//! The work-item commands of the CLI, ported from `Cli#cmd_*`. Anything this port is not sure it
//! parses or writes exactly as Ruby does is handed back as `Delegate` before anything is written.

use std::io::Read;

use crate::cli_format::{ljust, note_line};
use crate::error::{QmError, UNEMITTABLE};
use crate::git::git;
pub use crate::outcome::Outcome;
use crate::outcome::{abort, done};
use crate::note::{DEFAULT_NOTE_KIND, NOTE_KINDS};
use crate::ruby_text::strip;
use crate::work_item::{WorkItem, STATES};

/// An error as `Cli#run` reports it: `qm: <message>`, or Ruby's job when only it can write the value.
fn failed(e: QmError) -> Outcome {
    if e.class == UNEMITTABLE {
        Outcome::Delegate
    } else {
        abort(&format!("qm: {}", e.message))
    }
}

macro_rules! tri {
    ($e:expr) => {
        match $e {
            Ok(v) => v,
            Err(e) => return failed(e),
        }
    };
}

/// `Some(outcome)` for the commands ported here, `None` for every other word.
pub fn run(command: &str, args: &[String]) -> Option<Outcome> {
    Some(match command {
        "new" => new(args),
        "note" => note(args),
        "retag" => retag(args),
        "state" => state(args),
        "link-branch" => link_branch(args),
        "unlink-branch" => unlink_branch(args),
        "board" => board(args),
        "move" => move_to(args),
        "retitle" => retitle(args),
        "describe" => describe(args),
        "detach" => detach(args),
        "list" => list(),
        _ => return None,
    })
}

fn new(a: &[String]) -> Outcome {
    let (mut project, mut branch, mut description) = ("No project".to_string(), None, None);
    let mut parts: Vec<&str> = vec![];
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            flag @ ("--project" | "--branch" | "--description") => {
                let Some(value) = a.get(i + 1) else { return Outcome::Delegate };
                match flag {
                    "--project" => project = value.clone(),
                    "--branch" => branch = Some(value.clone()),
                    _ => description = Some(value.clone()),
                }
                i += 2;
            }
            s if s.starts_with('-') => return Outcome::Delegate,
            s => {
                parts.push(s);
                i += 1;
            }
        }
    }
    let title = strip(&parts.join(" ")).to_string();
    if title.is_empty() {
        return abort("usage: qm new TITLE [--project P] [--branch B] [--session ID] [--description TEXT] [--pf-mode MODE]");
    }
    let item = tri!(WorkItem::create(&title, &project, branch.as_deref(), description.as_deref()));
    done(format!("{}\n", item.slug))
}

fn note(a: &[String]) -> Outcome {
    if a.first().is_some_and(|s| s.starts_with('-')) {
        return Outcome::Delegate;
    }
    let mut kind = DEFAULT_NOTE_KIND.to_string();
    let mut parts: Vec<&str> = vec![];
    let rest = a.get(1..).unwrap_or(&[]);
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--kind" => {
                let Some(value) = rest.get(i + 1) else { return Outcome::Delegate };
                kind = value.clone();
                i += 2;
            }
            s if s.starts_with('-') => return Outcome::Delegate,
            s => {
                parts.push(s);
                i += 1;
            }
        }
    }
    let text = strip(&parts.join(" ")).to_string();
    let usage = || abort(&format!("usage: qm note SLUG [--kind {}] TEXT", NOTE_KINDS.join("|")));
    let Some(slug) = a.first() else { return usage() };
    if text.is_empty() {
        return usage();
    }
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.add_note(&text, &kind));
    done(format!("{}\n", note_line(&item.notes()[0])))
}

fn retag(a: &[String]) -> Outcome {
    let [slug, position, kind, ..] = a else {
        return abort(&format!("usage: qm retag SLUG POSITION KIND ({}) — POSITION is the number qm show prints", NOTE_KINDS.join(" | ")));
    };
    let plain = position == "0" || (position.starts_with(|c: char| ('1'..='9').contains(&c)) && position.bytes().all(|c| c.is_ascii_digit()));
    let Some(position) = plain.then(|| position.parse::<usize>().ok()).flatten() else { return Outcome::Delegate };
    let mut item = tri!(WorkItem::find(slug));
    let note = tri!(item.update_note_kind(position, kind));
    done(format!("{}\n", note_line(&note)))
}

fn state(a: &[String]) -> Outcome {
    let [slug, state, ..] = a else { return abort(&format!("usage: qm state SLUG ({})", STATES.join(" | "))) };
    if state == "resolved" {
        return Outcome::Delegate; // resolving also offers cleanup and clears the diff pane's viewed marks
    }
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.update_state(state));
    done(String::new())
}

fn link_branch(a: &[String]) -> Outcome {
    let mut temp = false;
    let mut positional: Vec<&String> = vec![];
    for arg in a {
        match arg.as_str() {
            "--temp" => temp = true,
            s if s.starts_with('-') => return Outcome::Delegate,
            _ => positional.push(arg),
        }
    }
    let cwd = std::env::current_dir().ok();
    let branch = positional
        .get(1)
        .map(|b| b.to_string())
        .or_else(|| git(cwd.as_deref().and_then(|p| p.to_str()), &["rev-parse", "--abbrev-ref", "HEAD"]));
    let (Some(slug), Some(branch)) = (positional.first(), branch) else {
        return abort("usage: qm link-branch SLUG [BRANCH] [--temp]  (BRANCH defaults to the current branch)");
    };
    let mut item = tri!(WorkItem::find(slug));
    if temp {
        if item.branches().contains(&branch) {
            return abort(&format!("qm: '{branch}' is already a linked branch of '{slug}'; unlink it first"));
        }
        tri!(item.add_temp_branch(&branch));
        done(format!("{slug} → temp: {}\n", item.temp_branches().join(", ")))
    } else {
        tri!(item.link_branch(&branch));
        done(format!("{slug} → {}\n", item.branches().join(", ")))
    }
}

fn unlink_branch(a: &[String]) -> Outcome {
    let [slug, branch, ..] = a else { return abort("usage: qm unlink-branch SLUG BRANCH") };
    let mut item = tri!(WorkItem::find(slug));
    if !item.branches().contains(branch) {
        return abort(&format!("qm: '{slug}' has no branch '{branch}'"));
    }
    tri!(item.unlink_branch(branch));
    let left = item.branches();
    done(format!("{slug} → {}\n", if left.is_empty() { "(no branches)".to_string() } else { left.join(", ") }))
}

fn board(a: &[String]) -> Outcome {
    let mut answers_dir: Option<&String> = None;
    let mut positional: Vec<&String> = vec![];
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            "--answers-dir" => {
                let Some(value) = a.get(i + 1) else { return Outcome::Delegate };
                answers_dir = Some(value);
                i += 2;
            }
            s if s.starts_with('-') => return Outcome::Delegate,
            _ => {
                positional.push(&a[i]);
                i += 1;
            }
        }
    }
    if answers_dir.is_some_and(|d| d.starts_with('~') && d != "~" && !d.starts_with("~/")) {
        return Outcome::Delegate; // `~user` expansion
    }
    let Some(slug) = positional.first() else { return abort("usage: qm board SLUG [URL [--answers-dir DIR] | clear]") };
    let url = positional.get(1).map(|u| u.as_str());
    if answers_dir.is_some() && matches!(url, None | Some("clear")) {
        return abort("qm: --answers-dir needs a board URL");
    }
    let mut item = tri!(WorkItem::find(slug));
    match url {
        None => match item.board() {
            Some(b) => done(format!("{b}\n")),
            None => Outcome::Done { code: 1, stdout: String::new(), stderr: String::new() },
        },
        Some("clear") => {
            tri!(item.unlink_board());
            done(format!("{slug} → (no status board)\n"))
        }
        Some(url) => {
            tri!(item.link_board(url, answers_dir.map(String::as_str)));
            let answers = item.board_answers_dir().map(|d| format!(" (answers: {d})")).unwrap_or_default();
            done(format!("{slug} → {url}{answers}\n"))
        }
    }
}

fn move_to(a: &[String]) -> Outcome {
    let [slug, project, ..] = a else { return abort("usage: qm move SLUG PROJECT") };
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.move_to(project));
    done(format!("{slug} → {project}\n"))
}

fn retitle(a: &[String]) -> Outcome {
    let title = strip(&a.get(1..).unwrap_or(&[]).join(" ")).to_string();
    let Some(slug) = a.first().filter(|_| !title.is_empty()) else {
        return abort("usage: qm retitle SLUG NEW_TITLE  (the slug never changes)");
    };
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.retitle(&title));
    done(format!("{slug}: {title}\n"))
}

fn describe(a: &[String]) -> Outcome {
    let mut text = strip(&a.get(1..).unwrap_or(&[]).join(" ")).to_string();
    if text.is_empty() || text == "-" {
        let mut piped = String::new();
        let _ = std::io::stdin().read_to_string(&mut piped);
        text = strip(&piped).to_string();
    }
    let Some(slug) = a.first().filter(|_| !text.is_empty()) else {
        return abort("usage: qm describe SLUG TEXT  (or pipe the text on stdin)");
    };
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.describe(&text));
    done(String::new())
}

fn detach(a: &[String]) -> Outcome {
    if a.first().is_some_and(|s| s.starts_with('-')) {
        return Outcome::Delegate;
    }
    let session = match a.get(1..).unwrap_or(&[]) {
        [] => None,
        [flag, id] if flag == "--session" => Some(id),
        _ => return Outcome::Delegate,
    };
    let (Some(slug), Some(session)) = (a.first(), session) else { return abort("usage: qm detach SLUG --session SESSION_ID") };
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.detach_session(session));
    done(String::new())
}

fn list() -> Outcome {
    let items = tri!(WorkItem::all());
    if items.is_empty() {
        return done("No work items yet. Create one with: qm new TITLE\n".into());
    }
    let rows: Vec<[String; 5]> = items
        .iter()
        .map(|i| {
            let branches = i.branches();
            [
                i.state().unwrap_or_else(|| "?".into()),
                i.project().unwrap_or_else(|| "?".into()),
                i.slug.clone(),
                i.session_count().to_string(),
                if branches.is_empty() { "-".into() } else { branches.join(" ") },
            ]
        })
        .collect();
    let widths: Vec<usize> = (0..5).map(|c| rows.iter().map(|r| r[c].chars().count()).max().unwrap_or(0)).collect();
    let mut out = String::new();
    for row in &rows {
        let cells: Vec<String> = row.iter().enumerate().map(|(c, cell)| ljust(cell, widths[c])).collect();
        out.push_str(&cells.join("  "));
        out.push('\n');
    }
    done(out)
}
