#![allow(dead_code)]
//! A world for the tests that start chats: a data root, a stand-in for claude that records how it was
//! started, and a tmux server on a throwaway `qm-test-…` socket, killed when the world drops.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub struct ChatWorld {
    pub dir: tempfile::TempDir,
    pub socket: String,
}

/// What a started chat recorded: its `QM_ITEM`, its cwd and the arguments it was given.
pub struct Started {
    pub item: String,
    pub cwd: String,
    pub args: Vec<String>,
}

impl ChatWorld {
    /// Points `QM_ROOT`, `QM_TMUX_SOCKET`, `QM_CHAT_COMMAND` and the transcripts at this world (process-wide:
    /// hold a lock across a test that uses it).
    pub fn new(tag: &str) -> ChatWorld {
        let dir = tempfile::tempdir().unwrap();
        let world = ChatWorld { socket: format!("qm-test-{tag}-{}", std::process::id()), dir };
        std::fs::create_dir_all(world.root()).unwrap();
        std::fs::create_dir_all(world.chats()).unwrap();
        let standin = world.chats().join("claude");
        std::fs::write(&standin, "#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s\\0' \"$QM_ITEM\" \"$(pwd -P)\" \"$@\" > \"$d/chat-$$.tmp\"\nmv \"$d/chat-$$.tmp\" \"$d/chat-$$.log\"\nexec sleep 120\n").unwrap();
        std::fs::set_permissions(&standin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let home = world.dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::set_var("QM_ROOT", world.root());
        std::env::set_var("QM_TRANSCRIPTS_DIR", world.dir.path().join("transcripts"));
        std::env::set_var("QM_TMUX_SOCKET", &world.socket);
        std::env::set_var("QM_CHAT_COMMAND", &standin);
        std::env::set_var("QM_CONFIG_STRICT", "1");
        for var in ["QM_ITEM", "QM_ASIDE", "QM_LOOSE", "TMUX"] {
            std::env::remove_var(var);
        }
        world
    }

    pub fn root(&self) -> PathBuf {
        self.dir.path().join("root")
    }

    pub fn chats(&self) -> PathBuf {
        self.dir.path().join("chats")
    }

    pub fn automations(&self) -> PathBuf {
        self.root().join("automations")
    }

    /// The chats started so far, oldest first.
    pub fn started(&self) -> Vec<Started> {
        let mut logs: Vec<PathBuf> = std::fs::read_dir(self.chats()).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "log")).collect();
        logs.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
        logs.iter()
            .map(|p| {
                let text = std::fs::read_to_string(p).unwrap();
                let mut parts: Vec<String> = text.split('\0').map(String::from).collect();
                parts.pop(); // after the last terminator
                let mut parts = parts.into_iter();
                Started { item: parts.next().unwrap_or_default(), cwd: parts.next().unwrap_or_default(), args: parts.collect() }
            })
            .collect()
    }

    /// Waits for `count` chats to have started.
    pub fn wait_started(&self, count: usize) -> Vec<Started> {
        wait_for(|| self.started().len() >= count, &format!("{count} chat(s) to start"));
        self.started()
    }

    pub fn tmux(&self, args: &[&str]) -> (bool, String) {
        match Command::new("tmux").args(["-L", &self.socket]).args(args).env_remove("TMUX").output() {
            Ok(o) => (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned()),
            Err(_) => (false, String::new()),
        }
    }

    pub fn sessions(&self) -> Vec<String> {
        let (_, out) = self.tmux(&["list-sessions", "-F", "#{session_name}"]);
        let mut names: Vec<String> = out.lines().map(String::from).collect();
        names.sort();
        names
    }

    /// Forgets every chat: kills the tmux server and the stand-in's logs.
    pub fn reset_chats(&self) {
        self.tmux(&["kill-server"]);
        for entry in std::fs::read_dir(self.chats()).unwrap().filter_map(|e| e.ok()) {
            if entry.path().extension().is_some_and(|e| e == "log") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

impl Drop for ChatWorld {
    fn drop(&mut self) {
        self.tmux(&["kill-server"]);
    }
}

pub fn wait_for(done: impl Fn() -> bool, what: &str) {
    let until = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < until, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A git repo on `main` with an origin remote, at `dir`.
pub fn repo_with_origin(dir: &Path, origin: &str) {
    super::repo(dir, "main");
    super::git(dir, &["remote", "add", "origin", origin]);
}

/// A world with one project, WebApp, whose checkout's origin is acme/WebApp and whose review skill is its own.
pub fn with_webapp(tag: &str) -> (ChatWorld, PathBuf) {
    let world = ChatWorld::new(tag);
    let repo = world.dir.path().join("repo");
    repo_with_origin(&repo, "git@github.com:acme/WebApp.git");
    std::fs::write(world.root().join("config.yml"), format!("projects:\n  WebApp:\n    root: {}\n    review_skill: /review-app-pr\n", repo.display())).unwrap();
    (world, repo)
}

impl ChatWorld {
    /// A `gh` stand-in first on PATH (and nowhere in ~/bin): it records its arguments and answers as told.
    pub fn gh(&self, stdout: &str, stderr: &str, code: i32) {
        let bin = self.dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("gh.out"), stdout).unwrap();
        std::fs::write(bin.join("gh.err"), stderr).unwrap();
        let script = format!("#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s\\0' \"$@\" >> \"$d/gh.log\"\necho >> \"$d/gh.log\"\ncat \"$d/gh.out\"\ncat \"$d/gh.err\" >&2\nexit {code}\n");
        std::fs::write(bin.join("gh"), script).unwrap();
        std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::var("PATH").unwrap_or_default();
        if !path.starts_with(&bin.display().to_string()) {
            std::env::set_var("PATH", format!("{}:{path}", bin.display()));
        }
    }

    /// The argument lists `gh` was run with, one per call.
    pub fn gh_calls(&self) -> Vec<Vec<String>> {
        let text = std::fs::read_to_string(self.dir.path().join("bin/gh.log")).unwrap_or_default();
        text.lines().map(|line| line.split('\0').filter(|a| !a.is_empty()).map(String::from).collect()).collect()
    }
}
