//! A local automation's run as a PR review: the item's `url` names the PR, whose Review item gets its own chat
//! through `pr_review_start` — the Review button's argv and kickoff, plus qm's session id, the yml's flags and
//! the automation's prompt as extra instructions. While that chat runs the run waits instead of starting.

use regex::Regex;
use serde_json::{json, Value};

use crate::automation_flows::{flags, FlowError, Reply};
use crate::automation_store::{Entry, Record};
use crate::{command_runner, pr_inbox, pr_items, pr_review_start};

const GH_FIELDS: &str = "number,title,url,headRefName,baseRefName,author";

fn pr_url() -> Regex {
    Regex::new(r"^https://github\.com/([^/\s]+/[^/\s]+)/pull/[0-9]+").unwrap()
}

fn url_of(item: &Value) -> String {
    crate::ruby_text::strip(item.get("url").and_then(Value::as_str).unwrap_or("")).to_string()
}

/// Why the automation may not review the item's PR, or None: an unattended review reads text others wrote, so
/// only repos its yml lists (owner/name, any case) are reviewed; no list reviews nothing.
pub fn refusal(record: &Record, item: &Value) -> Option<String> {
    let url = url_of(item);
    let Some(caps) = pr_url().captures(&url) else { return Some(format!("{} isn't a GitHub pull request URL", crate::ruby_text::inspect_ascii(&url).unwrap_or_else(|| format!("{url:?}")))) };
    let repo = caps[1].to_string();
    let repos: Vec<String> = record.get("repos").and_then(Value::as_array).into_iter().flatten().map(|r| r.as_str().unwrap_or("").to_lowercase()).collect();
    if repos.is_empty() {
        return Some(format!("repo {repo} isn't in this automation's repos (it has no repos list)"));
    }
    (!repos.contains(&repo.to_lowercase())).then(|| format!("repo {repo} isn't in this automation's repos"))
}

pub fn start(automation: &Entry, item: &Value, prompt: &str, session_id: &str) -> Result<Reply, FlowError> {
    if let Some(reason) = refusal(&automation.record, item) {
        return Err(FlowError::Refused(reason));
    }
    let other = |m: String| FlowError::Other(m);
    let pr = pr_for(&url_of(item)).map_err(other)?;
    if pr_review_start::live(&pr).map_err(|e| other(e.message))? {
        return Ok(Reply::Waiting(format!("Review chat for {} is open", pr_items::pr_label(&pr))));
    }
    let reply = pr_review_start::start(&pr, &flags(&automation.record, session_id), Some(prompt)).map_err(other)?;
    let slug = reply["slug"].as_str().unwrap_or("").to_string();
    Ok(Reply::Started { item_slug: slug.clone(), tmux: slug })
}

/// The PR as the inbox caches it, else one `gh pr view` mapped to that shape.
fn pr_for(url: &str) -> Result<Value, String> {
    match pr_inbox::cached_prs().into_iter().find(|pr| pr.get("url").and_then(Value::as_str) == Some(url)) {
        Some(pr) => Ok(pr),
        None => fetch(url),
    }
}

fn fetch(url: &str) -> Result<Value, String> {
    let repo = pr_url().captures(url).map(|c| c[1].to_string()).ok_or_else(|| format!("not a pull request URL: {}", crate::ruby_text::inspect_ascii(url).unwrap_or_else(|| format!("{url:?}"))))?;
    let result = command_runner::call(&["gh", "pr", "view", url, "--json", GH_FIELDS]);
    if !result.success {
        let detail = if crate::ruby_text::strip(&result.err).is_empty() { &result.out } else { &result.err };
        return Err(format!("gh pr view {url} failed: {}", crate::ruby_text::prefix(crate::ruby_text::strip(detail), 200)));
    }
    let data: Value = serde_json::from_str(&result.out).map_err(|_| format!("gh pr view {url} answered no JSON"))?;
    let text = |key: &str| data.get(key).cloned().unwrap_or(Value::Null);
    Ok(json!({"url": if text("url").is_null() { json!(url) } else { text("url") }, "repo": repo, "number": text("number"), "title": text("title"),
              "author": data.pointer("/author/login").cloned().unwrap_or(Value::Null), "head": text("headRefName"), "base": text("baseRefName")}))
}
