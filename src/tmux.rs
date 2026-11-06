//! The tmux server the GUI's chats live in: a dedicated socket (`tmux -L qm`, `QM_TMUX_SOCKET` for
//! tests) keeping it apart from any tmux the user runs. Each chat is its own tmux session holding
//! one window, both named after the item's slug.
//!
//! Only what looking at a chat and renaming it needs is ported. Starting a chat, typing into one,
//! respawning and killing stay in Ruby: nothing types into the user's chat without their click.

use std::process::{Command, Stdio};

const DEFAULT_SOCKET: &str = "qm";

pub struct Tmux {
    socket: String,
}

/// tmux reserves some characters in target names; slugs never carry them.
pub fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphanumeric()) && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

impl Tmux {
    pub fn new() -> Tmux {
        Tmux { socket: std::env::var("QM_TMUX_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.to_string()) }
    }

    /// TMUX unset, so a GUI started inside tmux still talks to our server. (success, stdout).
    fn run(&self, args: &[&str]) -> (bool, String) {
        match Command::new("tmux").args(["-L", &self.socket]).args(args).env_remove("TMUX").stdin(Stdio::null()).stderr(Stdio::null()).output() {
            Ok(out) => (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned()),
            Err(_) => (false, String::new()),
        }
    }

    pub fn sessions(&self) -> Vec<String> {
        match self.run(&["list-sessions", "-F", "#{session_name}"]) {
            (true, out) => out.split('\n').filter(|l| !l.is_empty()).map(String::from).collect(),
            _ => vec![],
        }
    }

    pub fn live(&self, name: &str) -> bool {
        valid_name(name) && self.run(&["has-session", "-t", &format!("={name}")]).0
    }

    /// The process the session's pane runs (the chat, once its launcher exec'd), or None.
    pub fn pane_pid(&self, name: &str) -> Option<i64> {
        if !valid_name(name) {
            return None;
        }
        let (ok, out) = self.run(&["display-message", "-p", "-t", &format!("={name}:"), "#{pane_pid}"]);
        let pid: i64 = out.trim().parse().unwrap_or(0);
        (ok && pid > 0).then_some(pid)
    }

    /// The directory of the session's pane, or None.
    pub fn pane_path(&self, name: &str) -> Option<String> {
        if !valid_name(name) {
            return None;
        }
        let (ok, out) = self.run(&["display-message", "-p", "-t", &format!("={name}:"), "#{pane_current_path}"]);
        let path = crate::ruby_text::strip(&out).to_string();
        (ok && !path.is_empty()).then_some(path)
    }

    /// Renames session `old` and its window to `new`, so the attach target follows the chat. False
    /// when either name is unusable, `old` isn't running, or `new` already is.
    pub fn rename(&self, old: &str, new: &str) -> bool {
        if !(valid_name(old) && valid_name(new)) || self.live(new) {
            return false;
        }
        self.run(&["rename-session", "-t", &format!("={old}"), new]).0 && self.run(&["rename-window", "-t", &format!("={new}:"), new]).0
    }
}

impl Default for Tmux {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::valid_name;

    #[test]
    fn names_are_slugs() {
        for ok in ["a", "fix-login-bug", "a_b-1", "9lives"] {
            assert!(valid_name(ok), "{ok}");
        }
        for bad in ["", "-a", "_a", "a b", "a.b", "a:b", "=a", "a\n", "é"] {
            assert!(!valid_name(bad), "{bad:?}");
        }
    }
}
