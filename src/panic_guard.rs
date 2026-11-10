//! A hook or the status line that panics must not break the session it runs in: no Rust panic message, no
//! exit 101. A hook's panic goes to `qm.log`; the status line's goes nowhere (it records nothing).

use std::panic::{self, AssertUnwindSafe};

use crate::data_root;

pub fn is_quiet_command(command: Option<&str>) -> bool {
    command.is_some_and(|c| c.starts_with("hook-") || c == "statusline")
}

/// Runs a hook or `statusline` command; a panic ends it with exit 0.
pub fn contained(command: &str, run: impl FnOnce() -> i32) -> i32 {
    let context = command.to_string();
    let log = command != "statusline";
    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        if log {
            data_root::log_error(&context, "Panic", &info.to_string());
        }
    }));
    let code = panic::catch_unwind(AssertUnwindSafe(run)).unwrap_or(0);
    panic::set_hook(previous);
    code
}
