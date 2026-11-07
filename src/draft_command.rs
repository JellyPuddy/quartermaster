//! `qm draft list SLUG [--json]`: what the item's chat and the user have drafted. `qm draft add`
//! needs a PR (gh, git) and writes the drafts file: it stays in Ruby.

use serde_json::{Map, Value};

use crate::cli_format::{prefix_chars, puts};
use crate::drafts;
use crate::error::UNEMITTABLE;
use crate::outcome::{abort, done, Outcome};
use crate::ruby_text::strip;
use crate::work_item::WorkItem;

const USAGE: &str = "usage: qm draft add SLUG --path P --line N [options] (--body TEXT | --body-file F) | qm draft list SLUG [--json]";

pub fn run(a: &[String]) -> Outcome {
    match a.first().map(String::as_str) {
        Some("list") => list(&a[1..]),
        Some("add") => add(&a[1..]),
        _ => abort(USAGE),
    }
}

/// `qm draft add`: the options OptionParser reads in their exact spellings; any other form (an
/// abbreviation, a short switch, an odd number) is Ruby's to read.
fn add(a: &[String]) -> Outcome {
    use crate::chat_review_drafts::{add as record, Fail, Options};
    let mut o = Options { side: "new".into(), ..Default::default() };
    let (mut slug, mut body, mut body_file) = (None::<&String>, None::<String>, None::<String>);
    let mut i = 0;
    while i < a.len() {
        let (name, inline) = match a[i].split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (a[i].as_str(), None),
        };
        if !name.starts_with('-') || name == "-" {
            if slug.replace(&a[i]).is_some() {
                return Outcome::Delegate;
            }
            i += 1;
            continue;
        }
        if name == "--file" {
            if inline.is_some() {
                return Outcome::Delegate;
            }
            o.file = true;
            i += 1;
            continue;
        }
        if !["--path", "--line", "--start-line", "--side", "--commit", "--reply-to", "--pr", "--branch", "--body", "--body-file"].contains(&name) {
            return Outcome::Delegate;
        }
        let value = match inline {
            Some(v) => v,
            None => {
                i += 1;
                let Some(v) = a.get(i) else { return Outcome::Delegate };
                v.clone()
            }
        };
        i += 1;
        let int = |v: &str| if !v.is_empty() && v.len() < 18 && v.bytes().all(|b| b.is_ascii_digit()) && (v == "0" || !v.starts_with('0')) { v.parse::<i64>().ok() } else { None };
        match name {
            "--path" => o.path = Some(value),
            "--line" => match int(&value) { Some(n) => o.line = Some(n), None => return Outcome::Delegate },
            "--start-line" => match int(&value) { Some(n) => o.start_line = Some(n), None => return Outcome::Delegate },
            "--side" if value == "old" || value == "new" => o.side = value,
            "--commit" => o.commit = Some(value),
            "--reply-to" => o.reply_to = Some(value),
            "--pr" => o.pr = Some(value),
            "--branch" => o.branch = Some(value),
            "--body" => body = Some(value),
            "--body-file" => body_file = Some(value),
            _ => return Outcome::Delegate,
        }
    }
    let Some(slug) = slug else { return Outcome::Delegate };
    if body_file.is_some() && body.is_some() {
        return abort("qm draft add: give the comment with --body or --body-file, not both");
    }
    if let Some(file) = body_file {
        let text = if file == "-" {
            let mut t = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut t).map(|_| t)
        } else {
            std::fs::read_to_string(&file)
        };
        let Ok(text) = text else { return Outcome::Delegate };
        body = Some(text);
    }
    let prefixed = |message: &str| abort(&format!("qm draft add: {message}"));
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) if e.class == UNEMITTABLE => return Outcome::Delegate,
        Err(e) if e.class == "ArgumentError" => return prefixed(&e.message),
        Err(e) => return abort(&format!("qm: {}", e.message)),
    };
    if !crate::cleanup_command::valid_slug(&item.slug) {
        return prefixed(&format!("'{}' is not a work item slug", item.slug));
    }
    // Ruby passes `body:` as a required keyword
    let Some(text) = body else { return prefixed("missing keyword: :body") };
    o.body = text;
    match record(&item, &o) {
        Ok((entry, replaced)) => {
            let Some(place) = draft_where(&entry) else { return Outcome::Delegate };
            let id = s(entry.get("id")).unwrap_or_default();
            done(puts(&format!("🤖 {place} drafted ({id}){}", if replaced { " — replaced your earlier draft there" } else { "" })))
        }
        Err(Fail::Arg(m)) => prefixed(&m),
        Err(Fail::Unported) => Outcome::Delegate,
    }
}

fn list(a: &[String]) -> Outcome {
    let (mut json, mut rest) = (false, vec![]);
    for arg in a {
        match arg.as_str() {
            "--json" => json = true,
            s if s.starts_with('-') => return Outcome::Delegate, // OptionParser reads these its own way
            _ => rest.push(arg),
        }
    }
    let [slug] = rest[..] else { return abort(USAGE) };
    let prefixed = |message: &str| abort(&format!("qm draft list: {message}"));
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) if e.class == UNEMITTABLE => return Outcome::Delegate,
        Err(e) if e.class == "ArgumentError" => return prefixed(&e.message),
        Err(e) => return abort(&format!("qm: {}", e.message)),
    };
    if !crate::cleanup_command::valid_slug(&item.slug) {
        return prefixed(&format!("'{}' is not a work item slug", item.slug));
    }
    let Some(entries) = drafts::entries(&item.slug) else { return Outcome::Delegate };
    if json {
        let all: Vec<Value> = entries.into_iter().map(Value::Object).collect();
        return done(puts(&drafts::pretty(&Value::Array(all))));
    }
    let mut out = String::new();
    if entries.is_empty() {
        out.push_str("no drafts\n");
    }
    for entry in &entries {
        let Some(line) = entry_line(entry) else { return Outcome::Delegate };
        out.push_str(&puts(&line));
    }
    done(out)
}

/// `"#{value}"` for the values a drafts file holds; `None` for what Ruby would print in its own way.
pub(crate) fn s(v: Option<&Value>) -> Option<String> {
    match v {
        None | Some(Value::Null) => Some(String::new()),
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        Some(Value::Number(n)) if n.is_i64() || n.is_u64() => Some(n.to_string()),
        _ => None,
    }
}

/// Ruby truthiness: neither null (or absent) nor false.
fn truthy(v: Option<&Value>) -> bool {
    !matches!(v, None | Some(Value::Null) | Some(Value::Bool(false)))
}

fn entry_line(entry: &Map<String, Value>) -> Option<String> {
    let author = match s(entry.get("author"))?.as_str() {
        "claude" => "🤖 claude",
        _ => "user",
    };
    let comment = s(entry.get("comment"))?;
    let first = strip(strip(&comment).split_inclusive('\n').next().unwrap_or("")).to_string();
    Some(format!("{}  {}  {author}: {}", s(entry.get("id"))?, draft_where(entry)?, prefix_chars(&first, 100)))
}

/// `Integer(value, exception: false)`, for the shapes a drafts file holds.
fn integer(v: Option<&Value>) -> Result<Option<i64>, ()> {
    match v {
        Some(Value::Number(n)) => n.as_i64().map(Some).ok_or(()),
        Some(Value::String(t)) => {
            let plain = !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit()) && (t == "0" || !t.starts_with('0')) && t.len() < 18;
            if plain { Ok(t.parse().ok()) } else { Err(()) }
        }
        None | Some(Value::Null) | Some(Value::Bool(_)) | Some(Value::Array(_)) | Some(Value::Object(_)) => Ok(None),
    }
}

/// `DiffComments.lines_label`: ":12", ":12-15", or ":old 12-new 15" across sides.
pub(crate) fn lines_label(entry: &Map<String, Value>) -> Option<String> {
    let Some(line) = integer(entry.get("line")).ok()? else { return Some(String::new()) };
    let Some(start) = integer(entry.get("start_line")).ok()? else { return Some(format!(":{line}")) };
    let side = s(entry.get("side"))?;
    let start_side = if truthy(entry.get("start_side")) { s(entry.get("start_side"))? } else { side.clone() };
    Some(if start_side == side { format!(":{start}-{line}") } else { format!(":{start_side} {start}-{side} {line}") })
}

/// `String#split("/").last`: trailing empty parts are dropped.
fn last_segment(repo: &str) -> &str {
    repo.split('/').collect::<Vec<_>>().into_iter().rev().skip_while(|p| p.is_empty()).next().unwrap_or("")
}

pub(crate) fn draft_where(entry: &Map<String, Value>) -> Option<String> {
    let pr = format!("{}#{}", last_segment(&s(entry.get("repo"))?), s(entry.get("number"))?);
    let at = if truthy(entry.get("path")) { Some(format!("{}{}", s(entry.get("path"))?, lines_label(entry)?)) } else { None };
    let at_text = at.clone().unwrap_or_default();
    let kind = s(entry.get("kind"))?;
    Some(match kind.as_str() {
        "github-comment" => {
            let what = if s(entry.get("subject"))? == "file" { "file comment" } else { "review comment" };
            let removed = if s(entry.get("side"))? == "old" { " (removed)" } else { "" };
            format!("{what} on {pr} {at_text}{removed} @{}", prefix_chars(&s(entry.get("commit"))?, 7))
        }
        "thread-reply" => {
            let place = if at.is_some() && truthy(entry.get("line")) { format!(" ({at_text})") } else { String::new() };
            format!("reply on {pr} to thread {}{place}", s(entry.get("thread"))?)
        }
        "diff-comment" => format!("chat comment on {at_text}{}", if truthy(entry.get("number")) { format!(" of {pr}") } else { String::new() }),
        "annotation" => {
            let page = if truthy(entry.get("page")) { s(entry.get("page"))? } else { s(entry.get("url"))? };
            format!("page annotation on {page}")
        }
        "issue-comment" => format!("issue comment on {}", s(entry.get("file"))?),
        _ => kind,
    })
}
