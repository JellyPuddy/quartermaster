//! Restack and rotate act only on the user's click, only in a chat that is at its turn, and refuse otherwise;
//! nothing automatic (a state build, the notifier, a hook) reaches either. A real tmux pane running `cat`
//! stands in for the chat; expected values written out, no Ruby oracle.

use quartermaster::gui_actions::dispatch;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

static ENV: Mutex<()> = Mutex::new(());
const SOCKET: &str = "qm-test-restack-rotate";

fn tmux(args: &[&str]) -> String {
    let out = Command::new("tmux").args(["-L", SOCKET]).args(args).env_remove("TMUX").stderr(Stdio::null()).output().unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git").args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test", "-c", "init.defaultBranch=main"]).args(args).current_dir(dir).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

struct World {
    _guard: std::sync::MutexGuard<'static, ()>,
    _dir: tempfile::TempDir,
    root: std::path::PathBuf,
}

impl Drop for World {
    fn drop(&mut self) {
        tmux(&["kill-server"]);
    }
}

impl World {
    fn event(&self, name: &str) {
        let stamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let mut f = fs::OpenOptions::new().append(true).create(true).open(self.root.join("events.jsonl")).unwrap();
        writeln!(f, "{{\"v\":1,\"ts\":\"{stamp}\",\"event\":\"{name}\",\"session_id\":\"sess-it\"}}").unwrap();
    }

    /// What the stand-in chat has been typed.
    fn pane(&self) -> String {
        tmux(&["capture-pane", "-p", "-t", "it"])
    }
}

/// An item `it` on stack branches st-1 ← st-2 of project `demo`, with a live session `sess-it` (this process's
/// pid) and a tmux pane `it` running `cat`; `plain` is an item with no stack.
fn world() -> World {
    let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    let (repo, root) = (base.join("repo"), base.join("root"));
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("README"), "x").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "one"]);
    for b in ["st-1", "st-2", "solo"] {
        git(&repo, &["branch", b]);
    }
    fs::write(repo.join(".git/gh-stack"), json!({"stacks": [{"trunk": {"branch": "main"}, "branches": [{"branch": "st-1"}, {"branch": "st-2"}]}]}).to_string()).unwrap();
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::write(root.join("config.yml"), format!("projects:\n  demo: {}\n", repo.display())).unwrap();
    for (slug, branch, sessions) in [("it", "st-1", "sessions:\n- id: sess-it\n"), ("plain", "solo", "")] {
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: demo\ncreated: '2026-01-01'\nbranches:\n- {branch}\n{sessions}---\n\n## Description\n\nd\n\n## Notes\n\n- 2026-03-01 [decision]: x\n\n## Snapshots\n")).unwrap();
    }
    fs::write(root.join("sessions.jsonl"), format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"sess-it\",\"cwd\":\"{}\",\"pid\":{},\"ts\":\"2026-03-01T00:00:00+00:00\"}}\n", repo.display(), std::process::id())).unwrap();
    let bin = base.join("bin");
    fs::create_dir_all(&bin).unwrap();
    for tool in ["gh", "claude"] {
        use std::os::unix::fs::PermissionsExt;
        fs::write(bin.join(tool), "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(bin.join(tool), fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::env::set_var("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()));
    std::env::set_var("QM_ROOT", &root);
    std::env::set_var("HOME", &base);
    std::env::set_var("QM_TMUX_SOCKET", SOCKET);
    std::env::set_var("QM_TRANSCRIPTS_DIR", base.join("transcripts"));
    std::env::remove_var("TMUX");
    std::env::remove_var("QM_ITEM");
    tmux(&["kill-server"]);
    for _ in 0..50 {
        tmux(&["new-session", "-d", "-s", "it", "-x", "200", "-y", "50", "cat"]);
        if tmux(&["list-sessions", "-F", "#{session_name}"]).contains("it") {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    World { _guard: guard, _dir: dir, root }
}

fn act(cmd: &str, slug: &str, args: Value) -> Value {
    dispatch(&json!({"cmd": cmd, "slug": slug, "args": args})).expect("a ported action")
}

fn error(reply: &Value) -> String {
    assert_eq!(reply["ok"], json!(false), "{reply}");
    reply["error"].as_str().unwrap().to_string()
}

#[test]
fn restack_types_into_the_chat_only_on_the_click_and_only_at_the_users_turn() {
    let w = world();
    w.event("UserPromptSubmit");
    let refused = error(&act("restack", "it", json!({})));
    assert_eq!(refused, "it's chat is mid-turn (working) — try again once it is your turn");
    assert!(!w.pane().contains("Restack"), "nothing was typed mid-turn");
    w.event("PermissionRequest");
    assert!(error(&act("restack", "it", json!({}))).contains("mid-turn (blocked)"));
    std::thread::sleep(Duration::from_millis(1100));
    w.event("Stop");
    let reply = act("restack", "it", json!({}));
    assert_eq!(reply, json!({"ok": true, "attached": true}));
    let pane = w.pane();
    assert!(pane.contains("Restack the gh-stack main ← st-1 ← st-2"), "{pane}");
    assert!(pane.contains("with `gh stack rebase`"), "{pane}");
}

#[test]
fn restack_refuses_an_item_without_that_stack_and_types_nothing() {
    let w = world();
    assert_eq!(error(&act("restack", "plain", json!({}))), "plain has no stack to restack");
    assert_eq!(error(&act("restack", "it", json!({"branch": "solo"}))), "solo is in none of it's stacks");
    assert!(w.pane().trim().is_empty(), "{}", w.pane());
}

#[test]
fn rotate_refuses_a_chat_mid_turn_and_one_outside_the_gui_and_starts_nothing() {
    let w = world();
    w.event("UserPromptSubmit");
    assert_eq!(error(&act("rotate", "it", json!({}))), "it's chat is mid-turn (working) — rotate once it is your turn");
    assert!(!w.pane().contains("Wrap up"), "nothing was typed mid-turn");
    tmux(&["kill-server"]);
    assert_eq!(error(&act("rotate", "it", json!({"close": true}))), "it's chat runs outside the GUI — end it there first");
    assert!(error(&act("rotate", "nowhere", json!({}))).contains("nowhere"));
}

#[test]
fn building_the_state_never_rotates_or_restacks_a_chat_at_its_turn() {
    let w = world();
    w.event("UserPromptSubmit");
    std::thread::sleep(Duration::from_millis(1100));
    w.event("Stop");
    for _ in 0..3 {
        let state = quartermaster::gui_state::build("token").unwrap_or_else(|_| panic!("state"));
        assert!(state["items"].as_array().is_some_and(|i| i.iter().any(|x| x["slug"] == "it")));
    }
    assert!(w.pane().trim().is_empty(), "a state build typed into the chat: {}", w.pane());
    assert!(!fs::read_to_string(w.root.join("work-items/it.md")).unwrap().contains("rotations:"));
}

#[test]
fn only_the_gui_actions_reach_rotation_and_restack_and_the_rotate_skill_is_the_users_alone() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    for entry in fs::read_dir(&src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let text = fs::read_to_string(&path).unwrap();
        if name != "gui_actions.rs" && name != "rotation.rs" {
            assert!(!text.contains("rotation::run") && !text.contains("rotation::plan") && !text.contains("restack("), "{name} reaches rotate or restack");
        }
    }
    let actions = fs::read_to_string(src.join("gui_actions.rs")).unwrap();
    assert_eq!(actions.matches("=> rotate_action(").count(), 1, "rotate is reached from the action table only");
    assert_eq!(actions.matches("=> restack(").count(), 1, "restack is reached from the action table only");
    assert_eq!(actions.matches("rotate_action(").count(), 2, "and called nowhere else");
    assert_eq!(actions.matches("restack(").count(), 2, "and called nowhere else");
    let skill = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/rotate/SKILL.md")).unwrap();
    assert!(skill.lines().take(8).any(|l| l.trim() == "disable-model-invocation: true"), "the /rotate skill must stay user-invoked");
}
