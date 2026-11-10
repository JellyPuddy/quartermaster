//! Cleanup's safety rules with expected values written out, no Ruby oracle: a dirty or unpushed worktree
//! warns and goes only when forced; a worktree a live session works in, or the dev server serves, is
//! never removed; a clean worktree whose commits are preserved goes.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "-c", "init.defaultBranch=main"])
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn commit(dir: &Path, file: &str) {
    fs::write(dir.join(file), file).unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-q", "-m", file]);
}

fn script(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

struct World {
    _dir: tempfile::TempDir,
    base: PathBuf,
}

impl World {
    fn root(&self) -> PathBuf {
        self.base.join("root")
    }

    fn worktree(&self, name: &str) -> PathBuf {
        self.base.join("repo/.claude/worktrees").join(name)
    }

    fn qm(&self, args: &[&str]) -> (i32, String) {
        let path = format!("{}:{}", self.base.join("bin").display(), std::env::var("PATH").unwrap());
        let out = Command::new(env!("CARGO_BIN_EXE_qm"))
            .args(args)
            .env_clear()
            .env("PATH", path)
            .env("QM_ROOT", self.root())
            .env("HOME", self.base.join("home"))
            .env("QM_TMUX_SOCKET", "qm-test-cleanup-safety")
            .env("LANG", "C.UTF-8")
            .current_dir(&self.base)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        let plain = regex::Regex::new("\x1b\\[[0-9;]*m").unwrap().replace_all(&text, "").into_owned();
        (out.status.code().unwrap_or(-1), plain.replace(self.base.to_str().unwrap(), "BASE"))
    }
}

/// One repo with an origin and a worktree per case, each owned by an item `<name>-item`: `clean` (nothing to
/// lose), `dirty` (uncommitted and untracked files), `unpushed` (a commit found nowhere else), `live` (a running
/// session works in it) and `served` (the dev server serves it).
fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    let (repo, origin) = (base.join("repo"), base.join("origin.git"));
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    commit(&repo, "README");
    fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare"]);
    git(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&repo, &["push", "-q", "origin", "main"]);
    let w = World { _dir: dir, base: base.clone() };
    for name in ["clean", "dirty", "unpushed", "live", "served"] {
        git(&repo, &["worktree", "add", "-q", "-b", &format!("b-{name}"), w.worktree(name).to_str().unwrap(), "main"]);
    }
    fs::write(w.worktree("dirty").join("README"), "changed").unwrap();
    fs::write(w.worktree("dirty").join("untracked.txt"), "x").unwrap();
    commit(&w.worktree("unpushed"), "only-here.txt");

    script(&base.join("bin/gh"), "#!/bin/sh\nexit 1\n");
    script(&base.join("bin/devsrv"), "#!/bin/sh\n[ \"$1\" = status ] && exit 0\nexit 1\n");
    fs::write(base.join("devstate"), format!("dev   {}\n", w.worktree("served").display())).unwrap();
    fs::create_dir_all(base.join("home")).unwrap();
    fs::create_dir_all(w.root().join("work-items")).unwrap();
    fs::write(w.root().join("config.yml"), format!("projects:\n  demo:\n    root: {}\n    dev_server:\n      command: devsrv\n      state_file: {}\n", repo.display(), base.join("devstate").display())).unwrap();
    let me = std::process::id();
    fs::write(w.root().join("sessions.jsonl"), format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"s-live-0001\",\"cwd\":\"{}\",\"pid\":{me},\"ts\":\"2026-03-01T00:00:00+00:00\"}}\n", w.worktree("live").display())).unwrap();
    for name in ["clean", "dirty", "unpushed", "live", "served"] {
        let sessions = if name == "live" { "sessions:\n- id: s-live-0001\n" } else { "" };
        fs::write(w.root().join(format!("work-items/{name}-item.md")), format!("---\nv: 1\ntitle: {name}\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\nbranches:\n- b-{name}\n{sessions}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    }
    w
}

#[test]
fn a_clean_worktree_is_ready_and_goes_with_yes() {
    let w = world();
    let (_, plan) = w.qm(&["cleanup", "clean-item"]);
    assert!(plan.contains("clean-item: 1 worktree — 1 ready"), "{plan}");
    let (code, _) = w.qm(&["cleanup", "clean-item", "--yes"]);
    assert_eq!(code, 0);
    assert!(!w.worktree("clean").exists(), "a worktree with nothing to lose is removed");
}

#[test]
fn a_dirty_worktree_warns_and_goes_only_when_forced() {
    let w = world();
    let (_, plan) = w.qm(&["cleanup", "dirty-item"]);
    assert!(plan.contains("uncommitted changes") && plan.contains("untracked files"), "{plan}");
    assert!(plan.contains("dirty-item: 1 worktree — 0 ready, 1 needs a look"), "{plan}");
    w.qm(&["cleanup", "dirty-item", "--yes"]);
    assert!(w.worktree("dirty").join("untracked.txt").exists(), "--yes alone leaves a dirty worktree");
    w.qm(&["cleanup", "dirty-item", "--yes", "--force", w.worktree("dirty").to_str().unwrap()]);
    assert!(!w.worktree("dirty").exists(), "naming the worktree with --force removes it");
}

#[test]
fn unpushed_commits_warn_and_the_worktree_stays_unless_forced() {
    let w = world();
    let (_, plan) = w.qm(&["cleanup", "unpushed-item"]);
    assert!(plan.contains("1 commit found nowhere else"), "{plan}");
    w.qm(&["cleanup", "unpushed-item", "--yes"]);
    assert!(w.worktree("unpushed").exists(), "unpushed work survives --yes");
    git(&w.base.join("repo"), &["rev-parse", "--verify", "b-unpushed"]);
    w.qm(&["cleanup", "unpushed-item", "--yes", "--force", w.worktree("unpushed").to_str().unwrap()]);
    assert!(!w.worktree("unpushed").exists());
}

#[test]
fn a_worktree_a_live_session_works_in_is_blocked_even_when_forced() {
    let w = world();
    let (_, plan) = w.qm(&["cleanup", "live-item"]);
    assert!(plan.contains("1 worktree — 0 ready, 1 blocked") && plan.contains("⛔"), "{plan}");
    assert!(plan.contains("live session s-live-0 works here"), "{plan}");
    w.qm(&["cleanup", "live-item", "--yes", "--force", w.worktree("live").to_str().unwrap()]);
    assert!(w.worktree("live").exists(), "a live chat's worktree is never removed");
}

#[test]
fn a_worktree_the_dev_server_serves_is_blocked_even_when_forced() {
    let w = world();
    let (_, plan) = w.qm(&["cleanup", "served-item"]);
    assert!(plan.contains("1 worktree — 0 ready, 1 blocked") && plan.contains("⛔"), "{plan}");
    assert!(plan.contains("the dev server serves it"), "{plan}");
    w.qm(&["cleanup", "served-item", "--yes", "--force", w.worktree("served").to_str().unwrap()]);
    assert!(w.worktree("served").exists(), "the served worktree is never removed");
}
