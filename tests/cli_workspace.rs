//! `pf-switch`, `ide`, `term`, `work-on`, `pf-stop`, `pf-status`, `resume` and `start`, pinned as transcripts
//! generated from the Ruby implementation, with stand-ins for the dev server, IDE, Warp and claude.

mod common;
use common::*;
use std::fs;
use std::path::Path;

fn script(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn workspace_and_launch_commands() {
    let qm = Qm::new();
    let root = qm.root.path().to_path_buf();
    let tools = root.join("tools");
    let repo = root.join("repo");
    let wt = root.join("wt-w");
    common::repo(&repo, "main");
    common::git(&repo, &["branch", "feat-w"]);
    common::git(&repo, &["branch", "feat-x"]);
    common::git(&repo, &["worktree", "add", wt.to_str().unwrap(), "feat-w"]);
    script(&tools.join("devsrv"), "#!/bin/sh\necho \"devsrv $*\" >> \"$FAKE_LOG\"\ncase \"$1\" in status) exit 1;; esac\n[ -f \"$FAKE_LOG.fail\" ] && { echo 'devsrv exploded' >&2; exit 3; }\nexit 0\n");
    script(&tools.join("fake-ide"), "#!/bin/sh\necho \"ide $*\" >> \"$FAKE_LOG\"\nexit 0\n");
    script(&tools.join("open"), "#!/bin/sh\necho \"open $*\" >> \"$FAKE_LOG\"\n[ -f \"$FAKE_LOG.noopen\" ] && exit 1\nexit 0\n");
    script(&tools.join("claude"), "#!/bin/sh\necho \"claude $* item=${QM_ITEM-unset} cwd=$(pwd)\"\n");
    fs::write(root.join("config.yml"), format!("ide_command: [{}, PATH]\nide_label: FakeIDE\nprojects:\n  demo:\n    root: {}\n    dev_server:\n      command: {}\n      modes: [dev, tunnel]\n      default_mode: dev\n  bare: {}\n", tools.join("fake-ide").display(), repo.display(), tools.join("devsrv").display(), repo.display())).unwrap();
    let item = |slug: &str, project: &str, extra: &str| fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap_or_else(|_| {
        fs::create_dir_all(root.join("work-items")).unwrap();
        fs::write(root.join(format!("work-items/{slug}.md")), format!("---\nv: 1\ntitle: {slug}\nstate: in_progress\nproject: {project}\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")).unwrap();
    });
    qm.ok(&["list"]);
    item("w-item", "demo", "branches:\n- feat-w\n- feat-x\nsessions:\n- id: s-res\n");
    item("w-live", "demo", "branches:\n- feat-w\nsessions:\n- id: s-live\n");
    item("w-none", "demo", "");
    item("w-bare", "bare", "branches:\n- feat-w\n");
    let transcripts = root.join("transcripts");
    fs::create_dir_all(transcripts.join("p")).unwrap();
    fs::write(transcripts.join("p/s-res.jsonl"), "{}\n").unwrap();
    fs::write(transcripts.join("p/s-live.jsonl"), "{}\n").unwrap();
    let log = |id: &str, pid: u32, cwd: &Path, tr: &str| format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"cwd\":\"{}\",\"pid\":{pid},\"transcript_path\":\"{tr}\",\"ts\":\"2026-03-01T00:00:00+00:00\"}}\n", cwd.display());
    fs::write(root.join("sessions.jsonl"), log("s-res", 999999, &wt, transcripts.join("p/s-res.jsonl").to_str().unwrap()) + &log("s-live", std::process::id(), &wt, transcripts.join("p/s-live.jsonl").to_str().unwrap())).unwrap();
    let env: Vec<(&str, String)> = vec![
        ("PATH", format!("{}:{}", tools.display(), std::env::var("PATH").unwrap())),
        ("HOME", root.join("home").display().to_string()),
        ("FAKE_LOG", root.join("tool.log").display().to_string()),
        ("QM_WARP_TAB_CONFIGS", root.join("warp").display().to_string()),
        ("QM_TRANSCRIPTS_DIR", transcripts.display().to_string()),
    ];
    let env_refs: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    fs::create_dir_all(root.join("home")).unwrap();
    let steps: Vec<Step> = vec![
        (&["pf-status"], ""),
        (&["pf-switch"], ""),
        (&["pf-switch", "w-item"], ""),
        (&["pf-switch", "w-item", "--mode", "tunnel"], ""),
        (&["pf-switch", "w-item", "--mode=tunnel"], ""),
        (&["pf-switch", "w-item", "--mode", "bogus"], ""),
        (&["pf-switch", "w-item", "--worktree", "/nowhere"], ""),
        (&["pf-switch", "w-none"], ""),
        (&["pf-switch", "w-bare"], ""),
        (&["pf-switch", "nowhere"], ""),
        (&["pf-switch", "w-item", "--bogus"], ""),
        (&["ide"], ""),
        (&["ide", "w-item"], ""),
        (&["ide", "w-item", "--mode", "dev"], ""),
        (&["ide", "w-none"], ""),
        (&["term", "w-item"], ""),
        (&["term", "w-item", "--worktree", "WT"], ""),
        (&["work-on", "w-item"], ""),
        (&["work-on", "w-item", "--mode", "tunnel"], ""),
        (&["work-on", "w-bare"], ""),
        (&["pf-status"], ""),
        (&["pf-stop"], ""),
        (&["resume"], ""),
        (&["resume", "w-item"], ""),
        (&["resume", "w-item", "--here"], ""),
        (&["resume", "w-item", "--session", "s-res"], ""),
        (&["resume", "w-item", "--session", "nope"], ""),
        (&["resume", "w-live"], ""),
        (&["resume", "w-none"], ""),
        (&["resume", "w-none", "--here"], ""),
        (&["resume", "nowhere"], ""),
        (&["start"], ""),
        (&["start", "w-item"], ""),
        (&["start", "w-item", "--here"], ""),
        (&["start", "w-none"], ""),
        (&["start", "nowhere"], ""),
        (&["start", "w-item", "--bogus"], ""),
    ];
    let wt_arg = wt.display().to_string();
    let steps: Vec<(Vec<String>, &str)> = steps.into_iter().map(|(a, i)| (a.iter().map(|x| if *x == "WT" { wt_arg.clone() } else { x.to_string() }).collect(), i)).collect();
    let mut out = String::new();
    for (args, stdin) in &steps {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        out += &transcript_env(&qm, "w-item", &[(&refs[..], stdin)], &env_refs);
        let _ = fs::remove_file(root.join("tool.log.fail"));
    }
    fs::write(root.join("tool.log.fail"), "").unwrap();
    out += &transcript_env(&qm, "w-item", &[(&["pf-switch", "w-item"], ""), (&["pf-stop"], "")], &env_refs);
    let _ = fs::remove_file(root.join("tool.log.fail"));
    fs::write(root.join("tool.log.noopen"), "").unwrap();
    out += &transcript_env(&qm, "w-item", &[(&["term", "w-item"], ""), (&["start", "w-none"], "")], &env_refs);
    out += &format!("tool log:\n{}", fs::read_to_string(root.join("tool.log")).unwrap_or_default());
    out += &format!("warp:\n{}", fs::read_to_string(root.join("warp/qm-launch.toml")).unwrap_or_default());
    golden("cli_workspace.txt", &scrub(&qm, &out));
}
