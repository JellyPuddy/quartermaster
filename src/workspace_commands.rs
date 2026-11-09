//! Launching an item's sessions and its workspace from the CLI: `resume`, `start`, `pf-switch`, `ide`,
//! `term`, `work-on`, `pf-stop` and `pf-status` (`CliWorkspace` and the `cmd_workspace` of `Cli`).
//! A flag this port does not read exactly as Ruby's option parser does hands the command back.

use std::os::unix::process::CommandExt;

use crate::cli_format::{paint, short_path};
use crate::outcome::{abort, done, Outcome};
use crate::work_item::WorkItem;
use crate::workspace::{self, Report};

fn failed(m: String) -> Outcome {
    abort(&format!("qm: {m}"))
}

pub fn run(command: &str, a: &[String]) -> Outcome {
    match command {
        "pf-switch" => workspace_command("pf-switch", a, true, |item, mode, worktree| workspace::switch_pf(item, mode, worktree, None)),
        "ide" => workspace_command("ide", a, false, |item, _, worktree| workspace::open_ide(item, worktree, None)),
        "term" => workspace_command("term", a, false, |item, _, worktree| workspace::open_terminal(item, worktree, None)),
        "work-on" => workspace_command("work-on", a, true, |item, mode, worktree| workspace::work_on(item, mode, worktree, None)),
        "pf-stop" => match workspace::stop_pf() {
            Ok(m) => done(format!("{m}\n")),
            Err(m) => failed(m),
        },
        "pf-status" => pf_status(),
        "resume" => resume(a),
        _ => start(a),
    }
}

/// `SLUG [--mode MODE] [--worktree PATH]`; `None` when the rest is a shape only Ruby reads.
fn options(a: &[String], mode: bool) -> Option<(Option<String>, Option<String>)> {
    let (mut m, mut w) = (None, None);
    let mut i = 0;
    while i < a.len() {
        let arg = a[i].as_str();
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (arg, None),
        };
        match name {
            "--mode" if mode => {
                m = Some(inline.or_else(|| { i += 1; a.get(i).cloned() })?);
            }
            "--worktree" => {
                w = Some(inline.or_else(|| { i += 1; a.get(i).cloned() })?);
            }
            s if s.starts_with('-') && s != "-" => return None,
            _ => {}
        }
        i += 1;
    }
    Some((m, w))
}

fn workspace_command(name: &str, a: &[String], mode: bool, act: impl FnOnce(&mut WorkItem, Option<&str>, Option<&str>) -> Result<Report, String>) -> Outcome {
    let Some(slug) = a.first() else { return abort(&format!("usage: qm {name} SLUG{} [--worktree PATH]", if mode { " [--mode MODE]" } else { "" })) };
    let Some((m, w)) = options(&a[1..], mode) else { return Outcome::Delegate };
    if w.as_deref().is_some_and(|p| p.starts_with('~') && p != "~" && !p.starts_with("~/")) {
        return Outcome::Delegate;
    }
    let mut item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) if e.class == crate::error::UNEMITTABLE => return Outcome::Delegate,
        Err(e) => return failed(e.message),
    };
    let report = match act(&mut item, m.as_deref(), w.as_deref()) {
        Ok(r) => r,
        Err(m) => return failed(m),
    };
    let mut out = String::new();
    if let Some(warning) = &report.target.warning {
        out += &format!("{}\n", paint(&format!("⚠ {warning}"), 33));
    }
    for step in &report.steps {
        out += &format!("{step}\n");
    }
    for (branch, path) in &report.target.alternatives {
        out += &format!("{}\n", paint(&format!("  also: {branch} @ {}  (--worktree {path})", short_path(Some(path))), 90));
    }
    done(out)
}

fn pf_status() -> Outcome {
    let config = crate::project_config::ProjectConfig::current();
    let Some(server) = config.dev_server() else { return abort(&format!("qm: no project configures a dev server: run `{}`", crate::project_config::DEV_SERVER_ANYWHERE)) };
    let Some(status) = crate::pf::status(Some(server)) else { return Outcome::Delegate };
    let state = if status.running { if status.switching { "switching" } else { "running" } } else { "stopped" };
    let last = match status.mode.as_str() {
        Some(mode) => format!("{mode} @ {}", short_path(status.root.as_deref())),
        None => "never switched".to_string(),
    };
    done(format!("{} {state}: {last}\n", server.command))
}

/// Opens the command in a new Warp tab (or, with `--here`, replaces this process with it).
fn open_session(cwd: &str, argv: &[&str], env: &[(&str, &str)], title: &str, here: bool) -> Outcome {
    let cwd = if std::path::Path::new(cwd).is_dir() { cwd.to_string() } else { crate::data_root::home() };
    if here {
        let mut command = std::process::Command::new(argv[0]);
        command.args(&argv[1..]).current_dir(&cwd);
        for (k, v) in env {
            command.env(k, v);
        }
        let error = command.exec();
        return abort(&format!("No such file or directory - {} ({error})", argv[0]));
    }
    let escape = crate::project_config::shell_escape;
    let mut words: Vec<String> = env.iter().map(|(k, v)| format!("{k}={}", escape(v))).collect();
    words.push(argv.iter().map(|x| escape(x)).collect::<Vec<_>>().join(" "));
    match workspace::warp_tab(&cwd, title, Some(&words.join(" "))) {
        Ok(opened) => done(format!("{opened}\n")),
        Err(m) => failed(m),
    }
}

fn flags(a: &[String], with_session: bool) -> Option<(Option<String>, bool)> {
    let (mut session, mut here) = (None, false);
    let mut i = 0;
    while i < a.len() {
        let arg = a[i].as_str();
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (arg, None),
        };
        match name {
            "--here" if inline.is_none() => here = true,
            "--session" if with_session => session = Some(inline.or_else(|| { i += 1; a.get(i).cloned() })?),
            s if s.starts_with('-') && s != "-" => return None,
            _ => {}
        }
        i += 1;
    }
    Some((session, here))
}

fn resume(a: &[String]) -> Outcome {
    let Some(slug) = a.first() else { return abort("usage: qm resume SLUG [--session ID] [--here]") };
    let Some((session, here)) = flags(&a[1..], true) else { return Outcome::Delegate };
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) if e.class == crate::error::UNEMITTABLE => return Outcome::Delegate,
        Err(e) => return failed(e.message),
    };
    use crate::launcher::Resume;
    match crate::launcher::resume_plan(&item, session.as_deref()) {
        Resume::Live { session_id } => abort(&format!("qm: session {} is running right now — switch to its Warp tab instead", session_id.chars().take(8).collect::<String>())),
        Resume::Resume { session_id, cwd } => open_session(&cwd, &["claude", "--resume", &session_id], &[], &format!("resume {}", item.slug), here),
        Resume::Rehydrate { cwd } => open_session(&cwd, &["claude"], &[("QM_ITEM", &item.slug)], &format!("qm {}", item.slug), here),
    }
}

fn start(a: &[String]) -> Outcome {
    let Some(slug) = a.first() else { return abort("usage: qm start SLUG [--here]") };
    let Some((_, here)) = flags(&a[1..], false) else { return Outcome::Delegate };
    let item = match WorkItem::find(slug) {
        Ok(i) => i,
        Err(e) if e.class == crate::error::UNEMITTABLE => return Outcome::Delegate,
        Err(e) => return failed(e.message),
    };
    open_session(&crate::branch_diff::start_cwd(&item), &["claude"], &[("QM_ITEM", &item.slug)], &format!("qm {}", item.slug), here)
}
