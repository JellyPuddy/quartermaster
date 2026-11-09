//! `qm open-chat`, `qm start-issue` and `qm loose`: bring a chat up in the running GUI (or, for the
//! last two, say how to start it in a terminal when there is none).

use serde_json::{json, Value};

use crate::command_runner;
use crate::gui_action::{self, truthy, Failed};
use crate::gui_actions::Stop;
use crate::issue_start::{self, Fail};
use crate::outcome::{abort, done, Outcome};
use crate::project_config::shell_escape;

const ARC: &str = "company.thebrowser.Browser";

fn arc_script() -> String {
    format!(
        "on run argv\n  set target to item 1 of argv\n  set prefixes to items 2 thru -1 of argv\n  if application id \"{ARC}\" is not running then return \"none\"\n  tell application id \"{ARC}\"\n    repeat with w in windows\n      repeat with t in tabs of w\n        set u to URL of t\n        repeat with prefix in prefixes\n          if u starts with (prefix as text) then\n            set URL of t to target\n            select t\n            activate\n            return \"found\"\n          end if\n        end repeat\n      end repeat\n    end repeat\n  end tell\n  return \"none\"\nend run\n"
    )
}

/// `URI.encode_www_form_component`.
fn encode(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        match b {
            b'*' | b'-' | b'.' | b'_' => out.push(b as char),
            b if b.is_ascii_alphanumeric() => out.push(b as char),
            b' ' => out.push('+'),
            b => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn failed(f: Failed) -> Outcome {
    match f {
        Failed::Abort(message) => abort(&message),
        Failed::Ruby => Outcome::Delegate,
    }
}

/// `--name VALUE` / `--name=VALUE` among `names` and the other arguments; None when another shape of
/// option (an abbreviation, a short switch) shows up, which OptionParser reads its own way.
fn options(a: &[String], names: &[&str]) -> Option<(Vec<(String, String)>, Vec<String>)> {
    let (mut found, mut rest) = (vec![], vec![]);
    let mut i = 0;
    while i < a.len() {
        if a[i] == "--" {
            rest.extend(a[i + 1..].iter().cloned());
            break;
        }
        let (name, inline) = match a[i].split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (a[i].as_str(), None),
        };
        if name.starts_with('-') && name != "-" && !a[i].contains(char::is_whitespace) {
            if !names.contains(&name) {
                return None;
            }
            let value = match inline {
                Some(v) => v,
                None => {
                    i += 1;
                    a.get(i)?.clone()
                }
            };
            found.push((name.to_string(), value));
        } else {
            rest.push(a[i].clone());
        }
        i += 1;
    }
    Some((found, rest))
}

fn last<'a>(found: &'a [(String, String)], name: &str) -> Option<&'a str> {
    found.iter().rev().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

pub fn open_chat(a: &[String]) -> Outcome {
    let Some((found, rest)) = options(a, &["--benchmark"]) else { return Outcome::Delegate };
    let Some(slug) = rest.first() else { return abort("usage: qm open-chat SLUG [--benchmark BRANCH]") };
    let port = match gui_action::port() {
        Ok(p) => p,
        Err(f) => return failed(f),
    };
    let mut hash = format!("chat={}", encode(slug));
    if let Some(branch) = last(&found, "--benchmark") {
        hash.push_str(&format!("&benchmark={}", encode(branch)));
    }
    let target = format!("http://127.0.0.1:{port}/#{hash}");
    let script = arc_script();
    let (one, two) = (format!("http://127.0.0.1:{port}/"), format!("http://localhost:{port}/"));
    let result = command_runner::call(&["osascript", "-e", &script, &target, &one, &two]);
    if !(result.success && crate::ruby_text::strip(&result.out) == "found") {
        command_runner::call(&["open", &target]);
    }
    done(String::new())
}

fn default_issue_project() -> String {
    let cwd = std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned());
    let project = crate::project_map::project_for(cwd.as_deref());
    if project != crate::project_map::NO_PROJECT {
        return project;
    }
    crate::project_config::ProjectConfig::current().default_project().unwrap_or(project)
}

fn preview_lines(p: &Value) -> String {
    let text = |k: &str| crate::draft_command::s(p.get(k)).unwrap_or_default();
    let mut out = format!("#{} {} ({}) — {}\n", text("number"), text("title"), text("state"), text("url"));
    if truthy(p.get("closed")) {
        out.push_str("  ⚠ the issue is closed\n");
    }
    if truthy(p.get("existing")) {
        out.push_str(&format!("  already tracked: {} ({})\n", text_of(&p["existing"], "slug"), text_of(&p["existing"], "state")));
    } else {
        out.push_str(&format!("  project {}, branch {}{}\n", text("project"), text("branch"), if truthy(p.get("reuse_branch")) { " (existing, reused)" } else { "" }));
    }
    out
}

fn text_of(v: &Value, key: &str) -> String {
    crate::draft_command::s(v.get(key)).unwrap_or_default()
}

pub fn start_issue(a: &[String]) -> Outcome {
    let Some((found, rest)) = options(a, &["--project"]) else { return Outcome::Delegate };
    let [number] = &rest[..] else { return abort("usage: qm start-issue NUMBER [--project P]") };
    let project = last(&found, "--project").map(String::from).unwrap_or_else(default_issue_project);
    let prefixed = |m: &str| abort(&format!("qm start-issue: {m}"));
    let preview = match issue_start::preview(&json!(number), &project) {
        Ok(p) => p,
        Err(Fail::Arg(m)) => return prefixed(&m),
        Err(Fail::Unported) => return Outcome::Delegate,
    };
    let mut out = preview_lines(&preview);
    let reply = match gui_action::call_optional("start-issue", "issue-start", None, json!({"number": preview["number"], "project": project})) {
        Ok(r) => r,
        Err(Failed::Abort(m)) => return Outcome::Done { code: 1, stdout: out, stderr: format!("{m}\n") },
        Err(Failed::Ruby) => return Outcome::Delegate,
    };
    if let Some(reply) = reply {
        let slug = text_of(&Value::Object(reply.clone()), "slug");
        out.push_str(&if truthy(reply.get("existing")) { format!("{slug}: its chat is open in the qm gui\n") } else { format!("{slug}: starting in the qm gui — its chat opens in the item's pane once the worktree is ready\n") });
    } else if truthy(preview.get("existing")) {
        let slug = text_of(&preview["existing"], "slug");
        out.push_str(&format!("{slug} already holds #{} — continue there: qm resume {slug}\n", text_of(&preview, "number")));
    } else {
        match issue_start::start(&preview, None, &|_| {}) {
            Ok((item, path)) => {
                out.push_str(&format!("{}: created, worktree {} on {}\n", item.slug, crate::cli_format::short_path(Some(&path)), text_of(&preview, "branch")));
                out.push_str("no qm gui running — start its chat with:\n");
                out.push_str(&format!("  cd {} && QM_ITEM={} claude {}\n", shell_escape(&path), item.slug, shell_escape(&issue_start::kickoff(preview["number"].as_i64().unwrap_or(0)))));
            }
            Err(Fail::Arg(m)) => return Outcome::Done { code: 1, stdout: out, stderr: format!("qm start-issue: {m}\n") },
            Err(Fail::Unported) => return Outcome::Delegate,
        }
    }
    done(out)
}

pub fn loose(a: &[String]) -> Outcome {
    let Some((found, rest)) = options(a, &["--project", "--model", "--starter"]) else { return Outcome::Delegate };
    let models = ["sonnet", "opus", "haiku"];
    if rest.len() > 1 {
        return abort(&format!("usage: qm loose [--project P] [--model {}] [--starter NAME] [--] [\"first prompt\"]", models.join("|")));
    }
    let (model, starter) = (last(&found, "--model"), last(&found, "--starter"));
    if let Some(m) = model.filter(|m| !models.contains(m)) {
        let Some(shown) = crate::ruby_text::inspect_ascii(m) else { return Outcome::Delegate };
        return abort(&format!("qm loose: unknown model {shown} ({})", models.join(", ")));
    }
    let stop = |s: Stop| match s {
        Stop::Reply(v) => abort(&format!("qm loose: {}", v["error"].as_str().unwrap_or(""))),
        Stop::Unported => Outcome::Delegate,
    };
    if let Err(s) = crate::gui_actions::loose_kickoff(starter, None) {
        return stop(s);
    }
    let cwd = std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned());
    let project = last(&found, "--project").map(String::from).unwrap_or_else(|| crate::project_map::project_for(cwd.as_deref()));
    let prompt = rest.first();
    let mut args = serde_json::Map::new();
    args.insert("project".into(), json!(project));
    if let Some(m) = model {
        args.insert("model".into(), json!(m));
    }
    if let Some(p) = prompt {
        args.insert("prompt".into(), json!(p));
    }
    if let Some(s) = starter {
        args.insert("starter".into(), json!(s));
    }
    match gui_action::call_optional("loose", "loose-start", None, Value::Object(args)) {
        Err(f) => failed(f),
        Ok(Some(reply)) => done(format!("loose chat {} started in the qm gui ({project}) — under Loose in its chats list\n", crate::draft_command::s(reply.get("id")).unwrap_or_default())),
        Ok(None) => {
            let id = crate::gui_draft_actions::random_hex(4);
            let kickoff = match crate::gui_actions::loose_kickoff(starter, prompt.map(String::as_str)) {
                Ok(k) => k,
                Err(s) => return stop(s),
            };
            let Some(mut argv) = crate::launcher::chat_command() else { return Outcome::Delegate };
            if let Some(m) = model {
                argv.extend(["--model".to_string(), m.to_string()]);
            }
            argv.extend(kickoff.filter(|k| !crate::ruby_text::strip(k).is_empty()));
            let root = crate::project_map::root_for(Some(&project)).filter(|r| std::path::Path::new(r).is_dir());
            let cwd = root.unwrap_or_else(crate::data_root::home);
            let joined: Vec<String> = argv.iter().map(|s| shell_escape(s)).collect();
            done(format!("no qm gui running — start the loose chat with:\n  cd {} && QM_LOOSE={id} QM_ITEM= {}\n", shell_escape(&cwd), joined.join(" ")))
        }
    }
}
