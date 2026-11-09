//! `qm draft add`: a chat's review finding as a GitHub draft on the item's PR (`ChatReviewDrafts`),
//! written straight into the drafts file. The drafts are authored "claude"; the user's own on the same
//! line or thread are never replaced.

use serde_json::{json, Map, Value};

use crate::branch_diff::{github_repo, pr_at_url, pr_find, pr_is_review, pr_label, Failure};
use crate::drafts::Halt;
use crate::gui_actions::Stop;
use crate::work_item::WorkItem;

/// What `add` can end in: Ruby's `ArgumentError` message, or a value this port leaves to Ruby.
pub enum Fail {
    Arg(String),
    Unsupported,
}

type R<T> = Result<T, Fail>;

fn arg<T>(m: impl Into<String>) -> R<T> {
    Err(Fail::Arg(m.into()))
}

fn from_failure(f: Failure) -> Fail {
    match f {
        Failure::Arg(m) => Fail::Arg(m),
        Failure::Unsupported => Fail::Unsupported,
    }
}

fn from_stop(s: Stop) -> Fail {
    match s {
        Stop::Reply(v) => match v.get("error").and_then(Value::as_str) {
            Some(m) => Fail::Arg(m.to_string()),
            None => Fail::Unsupported,
        },
        Stop::Unsupported => Fail::Unsupported,
    }
}

/// The options of `qm draft add`, as given.
#[derive(Default)]
pub struct Options {
    pub path: Option<String>,
    pub line: Option<i64>,
    pub start_line: Option<i64>,
    pub side: String,
    pub commit: Option<String>,
    pub file: bool,
    pub reply_to: Option<String>,
    pub pr: Option<String>,
    pub branch: Option<String>,
    pub body: String,
}

fn repo_root(item: &WorkItem) -> R<String> {
    let project = item.project();
    match crate::project_map::root_for(project.as_deref()).map(|r| crate::data_root::expand_path(&r)).filter(|r| r.is_dir()) {
        Some(root) => Ok(root.to_string_lossy().into_owned()),
        None => arg(format!("no repo root configured for project '{}'", project.unwrap_or_default())),
    }
}

fn which_pr(item: &WorkItem, root: &str, url: &Option<String>, branch: &Option<String>) -> R<Value> {
    let repo = github_repo(root);
    let pr = if let Some(url) = url {
        pr_at_url(url).map_err(from_failure)?
    } else if pr_is_review(item) || branch.is_some() {
        pr_of(item, repo.as_deref(), branch.as_deref())?
    } else {
        branch_pr(item, repo.as_deref())?
    };
    let pr_repo = pr["repo"].as_str().unwrap_or("");
    if repo.as_deref().unwrap_or("").to_lowercase() != pr_repo.to_lowercase() {
        return arg(format!("{} is not in {}'s repo (its origin is {})", pr["url"].as_str().unwrap_or(""), item.slug, repo.as_deref().unwrap_or("unknown")));
    }
    Ok(pr)
}

fn pr_of(item: &WorkItem, repo: Option<&str>, branch: Option<&str>) -> R<Value> {
    let found = pr_find(item, repo, branch).map_err(from_failure)?;
    if found.is_null() {
        return arg(format!("{} has no open pull request — name it with --pr URL", branch.unwrap_or(&item.slug)));
    }
    Ok(found)
}

fn branch_pr(item: &WorkItem, repo: Option<&str>) -> R<Value> {
    let branches = item.branches();
    let cwd = std::env::current_dir().map_err(|_| Fail::Unsupported)?;
    let here = crate::git::git(cwd.to_str(), &["symbolic-ref", "--quiet", "--short", "HEAD"]);
    if let Some(here) = here.filter(|h| branches.contains(h)) {
        return pr_of(item, repo, Some(&here));
    }
    let mut prs = vec![];
    for b in &branches {
        let found = pr_find(item, repo, Some(b)).map_err(from_failure)?;
        if !found.is_null() {
            prs.push(found);
        }
    }
    if prs.len() == 1 {
        return Ok(prs.remove(0));
    }
    if prs.is_empty() {
        return arg(format!("none of {}'s branches has an open pull request — name it with --pr URL", item.slug));
    }
    let labels: Vec<String> = prs.iter().map(pr_label).collect();
    arg(format!("{} has several open pull requests ({}) — pick one with --branch or --pr URL", item.slug, labels.join(", ")))
}

/// The PR head, or `commit` when it is one of the PR's commits, with the run from the PR's first commit
/// to it (the pane's label for it).
fn anchor_commit(root: &str, revs: &Value, commit: &Option<String>) -> R<(String, Option<String>)> {
    let head = revs["headSha"].as_str().unwrap_or("").to_string();
    let Some(commit) = commit else { return Ok((head, None)) };
    let sha = crate::git::git(Some(root), &["rev-parse", "--verify", "--quiet", &format!("{commit}^{{commit}}")]);
    let base = revs["baseSha"].as_str().unwrap_or("");
    let log = crate::git::git(Some(root), &["log", "--reverse", "--format=%H %h", &format!("{base}..{head}")]).unwrap_or_default();
    let commits: Vec<Vec<&str>> = log.lines().map(|l| l.split_whitespace().collect()).collect();
    let Some(sha) = sha.filter(|s| commits.iter().any(|c| c.first() == Some(&s.as_str()))) else { return arg(format!("{commit} is not one of the pull request's commits")) };
    if sha == head {
        return Ok((head, None));
    }
    let (first, last) = (&commits[0], commits.iter().find(|c| c.first() == Some(&sha.as_str())).unwrap());
    let short = |c: &Vec<&str>| c.get(1).copied().unwrap_or("").to_string();
    Ok((sha.clone(), Some(if first == last { short(last) } else { format!("{}..{}", short(first), short(last)) })))
}

fn blob_lines(root: &str, commit: &str, path: &str, from: i64, to: i64) -> Vec<String> {
    let Some(content) = crate::git::raw(root, &["show", &format!("{commit}:{path}")], &[0]) else { return vec![] };
    let lines: Vec<&str> = content.split_inclusive('\n').map(|l| l.strip_suffix("\r\n").or_else(|| l.strip_suffix('\n')).unwrap_or(l)).collect();
    let (from, to) = ((from - 1) as usize, (to - 1) as usize);
    if from > lines.len() {
        return vec![];
    }
    lines[from..(to + 1).min(lines.len())].iter().map(|l| l.to_string()).collect()
}

fn line_entry(root: &str, pr: &Value, o: &Options) -> R<Map<String, Value>> {
    let path = o.path.clone().unwrap_or_default();
    let Some(line) = o.line.filter(|_| !path.is_empty()) else { return arg("a draft needs --path and --line") };
    if o.side != "old" && o.side != "new" {
        return arg("--side is old or new");
    }
    if !(line > 0 && o.start_line.map_or(true, |s| s > 0)) {
        return arg("--line and --start-line are line numbers");
    }
    if let Some(s) = o.start_line.filter(|s| *s > line) {
        return arg(format!("--start-line {s} comes after --line {line}"));
    }
    let revs = crate::branch_diff::fetch_pr_uncached(root, pr).map_err(|e| e.map_or_else(|_| Fail::Unsupported, Fail::Arg))?;
    let (anchor, range) = anchor_commit(root, &revs, &o.commit)?;
    let base = revs["baseSha"].as_str().unwrap_or("");
    let anchors = crate::review_anchors::new(root, base, &anchor).map_err(Fail::Arg)?;
    let unsure = |_| Fail::Unsupported;
    let side = json!(o.side);
    let start_line = o.start_line.filter(|s| *s != line);
    let text = |l: i64| anchors.text(&path, &side, l).map_err(unsure);
    let mut texts: Vec<String> = match start_line {
        Some(s) => match anchors.span(&path, &side, s, &side, line).map_err(unsure)? {
            Some(t) => t,
            None => vec![text(s)?, text(line)?].into_iter().flatten().collect(),
        },
        None => text(line)?.into_iter().collect(),
    };
    if o.file && texts.is_empty() {
        let at = if o.side == "old" { base } else { anchor.as_str() };
        texts = blob_lines(root, at, &path, start_line.unwrap_or(line), line);
    }
    let mut e = Map::new();
    e.insert("kind".into(), json!("github-comment"));
    e.insert("path".into(), json!(path));
    e.insert("side".into(), json!(o.side));
    e.insert("line".into(), json!(line));
    e.insert("code".into(), json!(texts.join("\n")));
    if let Some(s) = start_line {
        e.insert("start_line".into(), json!(s));
        e.insert("start_side".into(), json!(o.side));
    }
    if let Some(r) = range {
        e.insert("range".into(), json!(r));
    }
    e.insert("repo".into(), pr["repo"].clone());
    e.insert("number".into(), pr["number"].clone());
    e.insert("base".into(), json!(base));
    e.insert("commit".into(), json!(anchor));
    e.insert("subject".into(), json!(if o.file { "file" } else { "line" }));
    e.insert("author".into(), json!("claude"));
    e.retain(|_, v| !v.is_null());
    Ok(e)
}

/// Claude may replace its own draft, never one the user wrote or edited.
fn keep_users(existing: Option<&Value>, replaced: &mut bool, place: &str) -> Result<(), Halt> {
    let Some(existing) = existing else { return Ok(()) };
    if existing.get("author").and_then(Value::as_str) == Some("claude") {
        *replaced = true;
        return Ok(());
    }
    let id = crate::draft_command::s(existing.get("id")).ok_or(Halt::Unsupported)?;
    Err(Halt::Refuse(format!("{place} already holds the user's draft {id} — leave it, or put yours on another line")))
}

/// Returns the stored entry and whether it replaced Claude's own draft.
pub fn add(item: &WorkItem, o: &Options) -> R<(Map<String, Value>, bool)> {
    if crate::ruby_text::strip(&o.body).is_empty() {
        return arg("the comment is empty");
    }
    let root = repo_root(item)?;
    let pr = which_pr(item, &root, &o.pr, &o.branch)?;
    let mut replaced = false;
    let refuse = |h: Halt| match h {
        Halt::Refuse(m) => Fail::Arg(m),
        Halt::Unsupported => Fail::Unsupported,
    };
    if let Some(thread) = &o.reply_to {
        if o.commit.is_some() || o.file || o.start_line.is_some() {
            return arg("a reply goes to its thread — --commit, --file and --start-line don't apply");
        }
        let mut reply = Map::new();
        reply.insert("thread".into(), json!(thread));
        reply.insert("repo".into(), pr["repo"].clone());
        reply.insert("number".into(), pr["number"].clone());
        reply.insert("url".into(), pr["url"].clone());
        if let Some(p) = o.path.as_ref().filter(|p| !p.is_empty()) {
            reply.insert("path".into(), json!(p));
        }
        if let Some(l) = o.line {
            reply.insert("line".into(), json!(l));
        }
        reply.insert("author".into(), json!("claude"));
        reply.insert("comment".into(), json!(o.body));
        let place = format!("thread {thread}");
        let stored = crate::gui_draft_actions::thread_reply_guarded(&item.slug, &reply, "claude", &mut |e| keep_users(e, &mut replaced, &place)).map_err(from_stop)?;
        return match stored {
            Value::Object(m) => Ok((m, replaced)),
            _ => Err(Fail::Unsupported),
        };
    }
    let mut entry = line_entry(&root, &pr, o)?;
    entry.insert("comment".into(), json!(o.body));
    if let Some(why) = crate::review_anchors::refusal_stored(&root, &entry).map_err(|_| Fail::Unsupported)? {
        return arg(if o.file { why } else { format!("{why}. Record it as a file comment with --file instead") });
    }
    let label = crate::draft_command::lines_label(&entry).ok_or(Fail::Unsupported)?;
    let place = format!("{}:{}", o.path.clone().unwrap_or_default(), label.strip_prefix(':').unwrap_or(&label));
    let stored = crate::gui_draft_actions::put_guarded(&item.slug, &entry, &mut |e| keep_users(e, &mut replaced, &place)).map_err(from_stop)?;
    let _ = refuse;
    match stored {
        Value::Object(m) => Ok((m, replaced)),
        _ => Err(Fail::Unsupported),
    }
}
