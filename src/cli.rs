use std::io::{Read, Write};

use crate::data_root;
use crate::delegate;
use crate::error::QmError;
use crate::feature_use;
use crate::hook;
use crate::session_log::SessionLog;
use crate::session_rows;

fn out(text: &str) {
    let _ = std::io::stdout().write_all(text.as_bytes());
}

/// `-n N` (or nothing) is the only form handled here; anything else is Ruby's to parse and refuse.
fn limit(args: &[String]) -> Option<usize> {
    match args {
        [] => Some(15),
        [flag, n] if flag == "-n" => n.parse().ok(),
        [joined] => joined.strip_prefix("-n")?.parse().ok(),
        _ => None,
    }
}

/// Hooks must never block or break a session: swallow everything, log, stay silent.
fn guard_hook(context: &str, run: impl FnOnce() -> Result<Option<String>, QmError>) {
    if std::env::var_os("QM_SKIP").is_some() {
        return;
    }
    match run() {
        Ok(Some(context)) => {
            out(&context);
            if !context.ends_with('\n') {
                out("\n");
            }
        }
        Ok(None) => {}
        Err(e) => data_root::log_error(context, e.class, &e.message),
    }
}

fn read_input() -> Result<serde_json::Value, QmError> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map_err(QmError::from)?;
    Ok(serde_json::from_str(&text)?)
}

fn abort(message: &str) -> i32 {
    eprintln!("{message}");
    1
}

pub fn run(args: Vec<String>) -> i32 {
    let command = args.first().map(String::as_str);
    let rest = args.get(1..).unwrap_or(&[]);
    match command {
        Some("hook-session-start") => {
            guard_hook("hook-session-start", || hook::session_started(&read_input()?));
            0
        }
        Some("hook-session-end") => {
            guard_hook("hook-session-end", || {
                hook::session_ended(&read_input()?)?;
                Ok(None)
            });
            0
        }
        Some("sessions") if limit(rest).is_some() => {
            feature_use::command(command);
            out(&session_rows::print(SessionLog::read().sessions(), limit(rest).unwrap()));
            0
        }
        Some("inbox") if limit(rest).is_some() => {
            feature_use::command(command);
            match SessionLog::read().inbox() {
                Ok(unlinked) if unlinked.is_empty() => {
                    out("Inbox empty — every captured session is linked to a work item or dismissed.\n");
                    0
                }
                Ok(unlinked) => {
                    out(&session_rows::print(unlinked, limit(rest).unwrap()));
                    0
                }
                Err(e) => abort(&format!("qm: {e}")),
            }
        }
        Some("dismiss") => {
            feature_use::command(command);
            match rest.first() {
                None => abort("usage: qm dismiss SESSION_ID"),
                Some(id) => match SessionLog::dismiss(id) {
                    Ok(()) => 0,
                    Err(e) => abort(&format!("qm: {e}")),
                },
            }
        }
        _ => delegate::exec_ruby(&args),
    }
}
