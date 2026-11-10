//! A state build spawns git once per question, not once per work item: one `git worktree list` per project root
//! per build, and one `git rev-parse --git-common-dir` per root for the life of the process (a root that is no
//! repo included). Spawns are counted through a `git` shim first on PATH that logs its arguments.

use quartermaster::gui_state;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn item(project: &str, branch: &str) -> String {
    format!("---\nv: 1\ntitle: T\nstate: in_progress\ncreated: '2026-01-01'\nproject: {project}\nbranches:\n- {branch}\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")
}

/// Three items of a real repo project and three of a project whose root is a plain directory, behind a logging
/// `git` shim. Returns the data dir and the shim's log path.
fn world() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    let (repo, plain, bin, qm_root) = (base.join("repo"), base.join("plain"), base.join("bin"), base.join("root"));
    for d in [&repo, &plain, &bin, &qm_root.join("work-items")] {
        fs::create_dir_all(d).unwrap();
    }
    let git = |args: &[&str]| assert!(Command::new("git").arg("-C").arg(&repo).args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t"]).args(args).status().unwrap().success());
    git(&["init", "-q", "-b", "main"]);
    git(&["commit", "-q", "--allow-empty", "-m", "one"]);
    let real = String::from_utf8(Command::new("which").arg("git").output().unwrap().stdout).unwrap();
    let log = base.join("git.log");
    let shim = bin.join("git");
    fs::write(&shim, format!("#!/bin/sh\necho \"$*\" >> {}\nexec {} \"$@\"\n", log.display(), real.trim())).unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(qm_root.join("config.yml"), format!("projects:\n  real:\n    root: {}\n  plain:\n    root: {}\n", repo.display(), plain.display())).unwrap();
    for n in 1..=3 {
        fs::write(qm_root.join(format!("work-items/r{n}.md")), item("real", &format!("feat-{n}"))).unwrap();
        fs::write(qm_root.join(format!("work-items/p{n}.md")), item("plain", &format!("feat-{n}"))).unwrap();
    }
    std::env::set_var("QM_ROOT", &qm_root);
    std::env::set_var("QM_TMUX_SOCKET", "qm-test-git-caches");
    std::env::set_var("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()));
    (dir, log)
}

fn spawns(log: &Path, needle: &str, cwd: &Path) -> usize {
    let cwd = format!("-C {} ", cwd.display());
    fs::read_to_string(log).unwrap_or_default().lines().filter(|l| l.contains(&cwd) && l.contains(needle)).count()
}

#[test]
fn one_state_build_lists_worktrees_once_per_project_root_and_asks_the_common_dir_once_per_root_ever() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let (dir, log) = world();
    let base = dir.path().canonicalize().unwrap();
    gui_state::build("tok");
    assert_eq!(spawns(&log, "worktree list", &base.join("repo")), 1, "six items, two roots, one listing each");
    assert_eq!(spawns(&log, "worktree list", &base.join("plain")), 1);
    gui_state::build("tok");
    assert_eq!(spawns(&log, "worktree list", &base.join("repo")), 2, "a new build lists again, so a new worktree shows");
    assert_eq!(spawns(&log, "--git-common-dir", &base.join("repo")), 1, "the repo's common dir is asked once, not per item or build");
    assert_eq!(spawns(&log, "--git-common-dir", &base.join("plain")), 1, "a root that is no repo is remembered too");
}
