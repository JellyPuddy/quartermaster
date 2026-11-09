//! The fzf viewer (`qm viewer`, `qm sessions-view`, `qm inbox-view`), its pickers (`choose-state`,
//! `choose-project`, `choose-snooze`, `attach-session`) and `item-from-session`. The views are shell
//! pipelines of this binary's own row commands into fzf, whose key bindings call back into it.

use std::io::Write;
use std::process::{Command, Stdio};

use crate::outcome::{abort, done, Outcome};
use crate::project_config::{shell_escape, ProjectConfig};
use crate::ruby_text::strip;
use crate::work_item::{WorkItem, STATES};

const FILTER_CYCLE: [&str; 5] = ["open", "in_progress", "fridge", "resolved", "all"];

fn failed(e: crate::error::QmError) -> Outcome {
    abort(&format!("qm: {}", e.message))
}

macro_rules! tri {
    ($e:expr) => {
        match $e {
            Ok(v) => v,
            Err(e) => return failed(e),
        }
    };
}

pub fn fzf_available() -> bool {
    Command::new("sh").args(["-c", "command -v fzf >/dev/null 2>&1"]).status().is_ok_and(|s| s.success())
}

fn need_fzf() -> Option<Outcome> {
    (!fzf_available()).then(|| abort("qm: the viewer needs fzf (brew install fzf)"))
}

/// `Viewer.pick`: the chosen line, or None when fzf ends without one.
pub fn pick(lines: &[String], prompt: &str) -> Option<String> {
    let mut child = Command::new("fzf").arg(format!("--prompt={prompt} ")).args(["--height=40%", "--reverse"]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    let text = lines.join("\n");
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(text.as_bytes());
    });
    let out = child.wait_with_output().ok()?;
    let _ = writer.join();
    out.status.success().then(|| strip(&String::from_utf8_lossy(&out.stdout)).to_string())
}

/// What `pick` returns for a choice that was made.
fn chosen(lines: &[String], prompt: &str) -> Option<String> {
    pick(lines, prompt).filter(|c| !c.is_empty())
}

fn executable() -> String {
    shell_escape(&std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "qm".into()))
}

/// Single-quoted so embedded newlines survive (multi-line fzf headers).
fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn run_fzf(rows_command: &str, prompt: &str, header: &str, preview: &str, binds: &[String]) -> Outcome {
    let mut options = vec!["--ansi".to_string(), "--reverse".into(), "--delimiter='\t'".into(), "--with-nth=2..".into(), format!("--prompt={}", quote(&format!("{prompt} "))), format!("--header={}", quote(header)), format!("--preview={}", quote(preview)), "--preview-window=right:55%:wrap".into()];
    options.extend(binds.iter().map(|b| format!("--bind={}", quote(b))));
    let _ = Command::new("sh").args(["-c", &format!("{rows_command} | fzf {}", options.join(" "))]).status();
    done(String::new())
}

pub fn open() -> Outcome {
    if let Some(o) = need_fzf() {
        return o;
    }
    let _ = crate::data_root::ensure_setup();
    let filter_file = crate::data_root::root().join("viewer-filter");
    let _ = std::fs::write(&filter_file, FILTER_CYCLE[0]);
    let bin = executable();
    let rows = format!("{bin} viewer-rows");
    let show_filter = format!("echo \"$(cat {}) > \"", shell_escape(&filter_file.to_string_lossy()));
    let header = format!(
        "enter or double-click resume · ^N new session · ^X sessions · ^B inbox · ^R refresh\n^S state · ^P project · ^O pr · ^F filter: {}\n^T distill · ^A ack degradation · ^Z snooze",
        FILTER_CYCLE.join("→")
    );
    let binds: Vec<String> = vec![
        format!("ctrl-r:reload({rows})"),
        format!("enter:execute-silent({bin} resume {{1}})"),
        format!("double-click:execute-silent({bin} resume {{1}})"),
        format!("ctrl-n:execute-silent({bin} start {{1}})"),
        format!("ctrl-x:execute({bin} sessions-view {{1}})"),
        format!("ctrl-s:execute({bin} choose-state {{1}})+reload({rows})"),
        format!("ctrl-p:execute({bin} choose-project {{1}})+reload({rows})"),
        format!("ctrl-o:execute-silent({bin} pr {{1}})"),
        format!("ctrl-b:execute({bin} inbox-view)+reload({rows})"),
        format!("ctrl-f:execute-silent({bin} cycle-filter)+transform-prompt({show_filter})+reload({rows})"),
        format!("ctrl-t:execute({bin} distill {{1}} && printf '\\n[press enter] ' && read -r _)+reload({rows})"),
        format!("ctrl-a:execute-silent({bin} ack {{1}})+reload({rows})"),
        format!("ctrl-z:execute({bin} choose-snooze {{1}})+reload({rows})"),
    ];
    run_fzf(&rows, &format!("{} > ", FILTER_CYCLE[0]), &header, &format!("{bin} show {{1}}"), &binds)
}

pub fn sessions_view(args: &[String]) -> Outcome {
    let Some(slug) = args.first() else { return abort("usage: qm sessions-view SLUG") };
    if let Some(o) = need_fzf() {
        return o;
    }
    let item = tri!(WorkItem::find(slug));
    let bin = executable();
    let slug = shell_escape(&item.slug);
    let rows = format!("{bin} session-rows {slug}");
    let binds = vec![format!("enter:execute-silent({bin} resume {slug} --session {{1}})"), format!("ctrl-r:reload({rows})")];
    run_fzf(&rows, &format!("{} sessions > ", item.slug), "enter resume this session · ^R refresh · esc back", &format!("{bin} show-session {{1}}"), &binds)
}

pub fn inbox_view() -> Outcome {
    if let Some(o) = need_fzf() {
        return o;
    }
    let bin = executable();
    let rows = format!("{bin} inbox-rows");
    let binds = vec![
        format!("enter:execute({bin} attach-session {{1}})+reload({rows})"),
        format!("ctrl-w:execute({bin} item-from-session {{1}})+reload({rows})"),
        format!("ctrl-d:execute-silent({bin} dismiss {{1}})+reload({rows})"),
        format!("ctrl-r:reload({rows})"),
    ];
    run_fzf(&rows, "inbox > ", "enter attach to a work item · ^D dismiss · ^R refresh\n^W new item from session · esc back", &format!("{bin} show-session {{1}}"), &binds)
}

pub fn choose_state(a: &[String]) -> Outcome {
    let Some(slug) = a.first() else { return abort("usage: qm choose-state SLUG") };
    let mut item = tri!(WorkItem::find(slug));
    let states: Vec<String> = STATES.iter().map(|s| s.to_string()).collect();
    if let Some(choice) = chosen(&states, &format!("state for {} >", item.slug)) {
        tri!(item.update_state(&choice));
    }
    done(String::new())
}

pub fn choose_project(a: &[String]) -> Outcome {
    let Some(slug) = a.first() else { return abort("usage: qm choose-project SLUG") };
    let mut item = tri!(WorkItem::find(slug));
    let mut options = ProjectConfig::current().project_names();
    options.push(crate::project_map::NO_PROJECT.to_string());
    let mut seen: Vec<String> = vec![];
    for o in options {
        if !seen.contains(&o) {
            seen.push(o);
        }
    }
    if let Some(choice) = chosen(&seen, &format!("project for {} >", item.slug)) {
        tri!(item.move_to(&choice));
    }
    done(String::new())
}

pub fn choose_snooze(a: &[String]) -> Outcome {
    let Some(slug) = a.first() else { return abort("usage: qm choose-snooze SLUG") };
    tri!(WorkItem::find(slug));
    let options: Vec<String> = ["1d", "7d", "clear"].iter().map(|s| s.to_string()).collect();
    match chosen(&options, &format!("snooze {slug} >")) {
        Some(choice) => crate::work_item_commands::snooze(&[slug.clone(), choice]),
        None => done(String::new()),
    }
}

pub fn attach_session(a: &[String]) -> Outcome {
    let Some(session) = a.first() else { return abort("usage: qm attach-session SESSION_ID") };
    let items = tri!(WorkItem::all());
    let lines: Vec<String> = items.iter().filter(|i| i.state().as_deref() != Some("resolved")).map(|i| format!("{}\t{}", i.slug, i.title())).collect();
    let Some(choice) = chosen(&lines, &format!("attach {} to >", crate::ruby_text::prefix(session, 8))) else { return done(String::new()) };
    let slug = choice.split('\t').next().unwrap_or("").to_string();
    let mut item = tri!(WorkItem::find(&slug));
    let vacated = tri!(item.claim_session(session));
    let (mut stdout, mut stderr) = (String::new(), String::new());
    crate::work_item_commands::report_claim(&vacated, session, &slug, &mut stdout, &mut stderr);
    Outcome::Done { code: 0, stdout, stderr }
}

pub fn item_from_session(a: &[String]) -> Outcome {
    let Some(session) = a.first() else { return abort("usage: qm item-from-session SESSION_ID") };
    if crate::session_log::SessionLog::read().last_start_for(Some(session)).is_none() {
        return abort(&format!("qm: unknown session {session}"));
    }
    print!("Title for the new work item: ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    let title = strip(&line).to_string();
    if title.is_empty() {
        return done(String::new());
    }
    let (item, vacated) = match crate::gui_actions::from_session(session, &title) {
        Ok(r) => r,
        Err(crate::gui_actions::Stop::Reply(v)) => return abort(&format!("qm: {}", v["error"].as_str().unwrap_or(""))),
        Err(crate::gui_actions::Stop::Unported) => return Outcome::Delegate,
    };
    let (mut stdout, mut stderr) = (String::new(), String::new());
    crate::work_item_commands::report_claim(&vacated, session, &item.slug, &mut stdout, &mut stderr);
    stdout.push_str(&format!("Created {}\n", item.slug));
    Outcome::Done { code: 0, stdout, stderr }
}
