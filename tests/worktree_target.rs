//! "Work on this item" with a branch that has no worktree yet: a new worktree is made, never a switched
//! checkout in an existing one. Real git, expected values written out, no Ruby oracle.

use quartermaster::work_item::WorkItem;
use quartermaster::workspace;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"])
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

struct World {
    _guard: std::sync::MutexGuard<'static, ()>,
    _dir: tempfile::TempDir,
    repo: PathBuf,
}

impl World {
    fn head(&self, dir: &Path) -> String {
        git(dir, &["rev-parse", "--abbrev-ref", "HEAD"])
    }
}

/// `repo` on main with origin; worktree `has-wt` on `b-has`; branches `b-new` (local only) and `b-remote`
/// (on origin only, not fetched); an item `it` linking all three.
fn world() -> World {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    let (repo, origin, other) = (base.join("repo"), base.join("origin.git"), base.join("other"));
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("README"), "x").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "one"]);
    fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare"]);
    git(&repo, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&repo, &["push", "-q", "origin", "main"]);
    git(&repo, &["worktree", "add", "-q", "-b", "b-has", repo.join(".claude/worktrees/has-wt").to_str().unwrap(), "main"]);
    git(&repo, &["branch", "b-new", "main"]);
    git(&base, &["clone", "-q", origin.to_str().unwrap(), other.to_str().unwrap()]);
    git(&other, &["checkout", "-q", "-b", "b-remote"]);
    fs::write(other.join("remote.txt"), "r").unwrap();
    git(&other, &["add", "."]);
    git(&other, &["commit", "-q", "-m", "remote work"]);
    git(&other, &["push", "-q", "origin", "b-remote"]);

    let root = base.join("root");
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    fs::write(root.join("work-items/it.md"), "---\nv: 1\ntitle: it\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\nbranches:\n- b-has\n- b-new\n- b-remote\n---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n").unwrap();
    std::env::set_var("QM_ROOT", &root);
    std::env::set_var("HOME", &base);
    World { _guard: guard, _dir: dir, repo }
}

fn item() -> WorkItem {
    WorkItem::find("it").unwrap()
}

#[test]
fn a_branch_without_a_worktree_gets_a_new_one_and_no_checkout_is_switched() {
    let w = world();
    let target = workspace::materialize(&mut item(), None, Some("b-new")).unwrap();
    let path = w.repo.join(".claude/worktrees/b-new");
    assert_eq!((target.path.as_str(), target.create), (path.to_str().unwrap(), true));
    assert_eq!(w.head(&path), "b-new", "the new worktree is on the branch");
    assert_eq!(w.head(&w.repo), "main", "the main checkout stays where it was");
    assert_eq!(w.head(&w.repo.join(".claude/worktrees/has-wt")), "b-has", "so does every other worktree");
}

#[test]
fn a_branch_that_already_has_a_worktree_is_used_as_it_is() {
    let w = world();
    let target = workspace::materialize(&mut item(), None, Some("b-has")).unwrap();
    assert_eq!((target.path.as_str(), target.create), (w.repo.join(".claude/worktrees/has-wt").to_str().unwrap(), false));
    assert!(!w.repo.join(".claude/worktrees/b-has").exists());
    assert_eq!(w.head(&w.repo), "main");
}

#[test]
fn a_branch_only_on_origin_is_fetched_and_tracked_in_a_new_worktree() {
    let w = world();
    workspace::materialize(&mut item(), None, Some("b-remote")).unwrap();
    let path = w.repo.join(".claude/worktrees/b-remote");
    assert_eq!(w.head(&path), "b-remote");
    assert!(path.join("remote.txt").exists());
    assert_eq!(git(&path, &["rev-parse", "--abbrev-ref", "b-remote@{upstream}"]), "origin/b-remote");
    assert_eq!(w.head(&w.repo), "main");
}

#[test]
fn a_branch_the_item_does_not_link_is_refused_and_nothing_is_made() {
    let w = world();
    git(&w.repo, &["branch", "stranger", "main"]);
    let err = workspace::materialize(&mut item(), None, Some("stranger")).err().unwrap();
    assert_eq!(err, "branch stranger is not linked to 'it'");
    assert!(!w.repo.join(".claude/worktrees/stranger").exists());
    assert_eq!(w.head(&w.repo), "main");
}

#[test]
fn an_explicit_worktree_wins_and_creates_nothing() {
    let w = world();
    let given = w.repo.join(".claude/worktrees/has-wt");
    let target = workspace::materialize(&mut item(), Some(given.to_str().unwrap()), Some("b-new")).unwrap();
    assert_eq!((target.path.as_str(), target.create), (given.to_str().unwrap(), false));
    assert!(!w.repo.join(".claude/worktrees/b-new").exists());
    assert_eq!(fs::read_dir(w.repo.join(".claude/worktrees")).unwrap().count(), 1);
}

#[test]
fn qm_never_runs_git_checkout_or_switch() {
    let pattern = regex::Regex::new(r#"(?s)"git"[^;]{0,200}?"(checkout|switch|reset)"|&\["(checkout|switch|reset)"|git (checkout|switch) "#).unwrap();
    for entry in fs::read_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("src")).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "rs") {
            let text = fs::read_to_string(&path).unwrap();
            let code: String = text.lines().filter(|l| !l.trim_start().starts_with("//")).collect::<Vec<_>>().join("\n");
            assert!(!pattern.is_match(&code), "{} runs git checkout/switch", path.display());
        }
    }
}
