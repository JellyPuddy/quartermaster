//! The commands that take free text — `qm new TITLE` and `qm note SLUG TEXT`. The text may start with a dash
//! (`opt_parse` leaves it alone), and `--` ends the options. Anything this port is not sure it parses or
//! writes exactly as Ruby does is handed back as `Delegate` before anything is written.

use crate::cli_format::note_line;
use crate::note::{DEFAULT_NOTE_KIND, NOTE_KINDS};
use crate::outcome::{abort, done, Outcome};
use crate::ruby_text::strip;
use crate::work_item::WorkItem;
use crate::work_item_commands::{failed, report_claim, tri};

pub fn new(a: &[String]) -> Outcome {
    let (mut project, mut branch, mut description, mut session, mut pf_mode) = ("No project".to_string(), None, None, None, None);
    let mut parts: Vec<&str> = vec![];
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            "--" => {
                parts.extend(a[i + 1..].iter().map(String::as_str));
                break;
            }
            flag @ ("--project" | "--branch" | "--description" | "--session" | "--pf-mode") => {
                let Some(value) = a.get(i + 1) else { return Outcome::Delegate };
                match flag {
                    "--project" => project = value.clone(),
                    "--branch" => branch = Some(value.clone()),
                    "--session" => session = Some(value.clone()),
                    "--pf-mode" => pf_mode = Some(value.clone()),
                    _ => description = Some(value.clone()),
                }
                i += 2;
            }
            s if looks_like_option(s) => return Outcome::Delegate,
            s => {
                parts.push(s);
                i += 1;
            }
        }
    }
    let title = strip(&parts.join(" ")).to_string();
    if title.is_empty() {
        return abort("usage: qm new [--project P] [--branch B] [--session ID] [--description TEXT] [--pf-mode MODE] [--] TITLE");
    }
    let mut item = tri!(WorkItem::create(&title, &project, branch.as_deref(), session.as_deref(), description.as_deref(), pf_mode.as_deref()));
    let (mut stdout, mut stderr) = (String::new(), String::new());
    if let Some(id) = &session {
        let vacated = tri!(item.claim_session(id));
        report_claim(&vacated, id, &item.slug, &mut stdout, &mut stderr);
    }
    stdout.push_str(&format!("{}\n", item.slug));
    Outcome::Done { code: 0, stdout, stderr }
}

/// What is left of an option after `opt_parse` read the ones the command knows: free text that starts with a
/// dash holds whitespace, an option never does.
fn looks_like_option(arg: &str) -> bool {
    arg.starts_with('-') && arg.len() > 1 && !arg.contains(char::is_whitespace)
}

pub fn note(a: &[String]) -> Outcome {
    if a.first().is_some_and(|s| s.starts_with('-')) {
        return Outcome::Delegate;
    }
    let mut kind = DEFAULT_NOTE_KIND.to_string();
    let mut parts: Vec<&str> = vec![];
    let rest = a.get(1..).unwrap_or(&[]);
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--" => {
                parts.extend(rest[i + 1..].iter().map(String::as_str));
                break;
            }
            "--kind" => {
                let Some(value) = rest.get(i + 1) else { return Outcome::Delegate };
                kind = value.clone();
                i += 2;
            }
            s if looks_like_option(s) => return Outcome::Delegate,
            s => {
                parts.push(s);
                i += 1;
            }
        }
    }
    let text = strip(&parts.join(" ")).to_string();
    let usage = || abort(&format!("usage: qm note SLUG [--kind {}] [--] TEXT", NOTE_KINDS.join("|")));
    let Some(slug) = a.first() else { return usage() };
    if text.is_empty() {
        return usage();
    }
    let mut item = tri!(WorkItem::find(slug));
    tri!(item.add_note(&text, &kind));
    done(format!("{}\n", note_line(&item.notes()[0])))
}
