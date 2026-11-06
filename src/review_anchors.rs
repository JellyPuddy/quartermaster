//! Where a GitHub review comment anchored to one commit of a PR can sit. GitHub validates it against
//! the PR diff base..commit (the merge-base of the PR's base with that commit) — not the commit's own
//! parent..commit — so only lines inside that diff's hunks (3 context lines, hunks one line apart
//! joined) take a comment. The part of `ReviewAnchors` the diff pane's PR scope needs: whether a
//! shown line is anchorable.

use std::collections::HashMap;

use regex::Regex;
use serde_json::Value;

use crate::git::raw;
use crate::unified_diff::UnifiedDiff;

pub const GITHUB_HUNKS: &str = "--inter-hunk-context=1";

pub struct ReviewAnchors {
    pub base_sha: String,
    files: HashMap<String, Value>,
    lines: std::cell::RefCell<HashMap<(String, &'static str), HashMap<i64, String>>>,
}

fn g(repo: &str, args: &[&str]) -> Option<String> {
    crate::git::git(Some(repo), args)
}

/// `Err` is the message of the `ArgumentError` Ruby raises.
pub fn new(repo: &str, base: &str, commit: &str) -> Result<ReviewAnchors, String> {
    let Some(commit_sha) = g(repo, &["rev-parse", "--verify", "--quiet", &format!("{commit}^{{commit}}")]) else { return Err(format!("{commit} is not a commit in {repo}")) };
    let Some(base_sha) = g(repo, &["merge-base", base, &commit_sha]) else { return Err(format!("{commit} shares no history with {base}")) };
    let Some(diff) = raw(repo, &["diff", "--no-color", "--no-ext-diff", "-M", GITHUB_HUNKS, &base_sha, &commit_sha, "--"], &[0]) else {
        return Err(format!("git diff {}..{} failed", &base_sha[..7.min(base_sha.len())], &commit_sha[..7.min(commit_sha.len())]));
    };
    let mut files = HashMap::new();
    let mut start = 0;
    let marker = Regex::new(r"(?m)^diff --git ").unwrap();
    let mut cuts: Vec<usize> = marker.find_iter(&diff).map(|m| m.start()).collect();
    if cuts.first() != Some(&0) {
        cuts.insert(0, 0);
    }
    cuts.push(diff.len());
    for w in cuts.windows(2) {
        let chunk = &diff[w[0]..w[1]];
        start = w[1];
        if chunk.is_empty() {
            continue;
        }
        let Some(parsed) = UnifiedDiff::new(i64::MAX).parse(chunk).into_iter().next() else { continue };
        let path = parsed["path"].as_str().unwrap_or("").to_string();
        let old = parsed["oldPath"].as_str().unwrap_or("").to_string();
        let deleted = parsed["status"] == "deleted";
        files.entry(path).or_insert_with(|| parsed.clone());
        if deleted {
            files.entry(old).or_insert(parsed);
        }
    }
    let _ = start;
    Ok(ReviewAnchors { base_sha, files, lines: Default::default() })
}

impl ReviewAnchors {
    fn find(&self, path: &str, key: &'static str, line: i64) -> Option<String> {
        let mut cache = self.lines.borrow_mut();
        let index = cache.entry((path.to_string(), key)).or_insert_with(|| {
            let mut found: HashMap<i64, String> = HashMap::new();
            for hunk in self.files.get(path).and_then(|f| f["hunks"].as_array()).into_iter().flatten() {
                for l in hunk["lines"].as_array().into_iter().flatten() {
                    if let Some(n) = l[key].as_i64() {
                        found.entry(n).or_insert_with(|| l["s"].as_str().unwrap_or("").to_string());
                    }
                }
            }
            found
        });
        index.get(&line).cloned()
    }

    /// Whether GitHub takes a comment on this line of a view diffed from `view_base`: inside the
    /// hunks and still this text. A removed line is numbered by `view_base`, so it counts only when
    /// that is GitHub's base too. `old` or `new` is the diff pane's side.
    pub fn anchorable(&self, path: &str, side: &str, line: i64, text: &str, view_base: &str) -> bool {
        let key = if side == "old" { "o" } else { "n" };
        if key == "o" && view_base != self.base_sha {
            return false;
        }
        self.find(path, key, line).is_some_and(|s| s == text)
    }
}
