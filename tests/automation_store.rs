//! The local copy of an automation: its yml and prompt files, the merge-on-write, the `.bak`s and the checks a
//! local record must pass.

use quartermaster::automation_store::{local_settings, validate_local, AutomationStore, Record};
use quartermaster::run_log::RunLog;
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;

struct World {
    root: tempfile::TempDir,
}

impl World {
    fn new() -> World {
        World { root: tempfile::tempdir().unwrap() }
    }

    fn dir(&self) -> std::path::PathBuf {
        self.root.path().join("automations")
    }

    fn store(&self) -> AutomationStore {
        AutomationStore::new(self.dir())
    }

    fn file(&self, name: &str) -> String {
        std::fs::read_to_string(self.dir().join(name)).unwrap()
    }
}

fn rec(value: Value) -> Record {
    value.as_object().unwrap().clone()
}

fn cloud() -> Record {
    rec(json!({
        "routine": "trig_1", "runner": "cloud", "name": "Digest", "cron": "0 7 * * 1,4",
        "model": "claude-sonnet-5-5", "sources": [{"git_repository": {"url": "https://github.com/o/r"}}],
        "connectors": [{"name": "Slack", "url": "https://mcp.slack.com/mcp"}], "allowed_tools": ["Bash", "Read"],
        "environment_id": "env_1", "enabled": true, "remote_updated_at": "2026-10-27T12:21:01.911143Z"
    }))
}

fn local() -> Record {
    rec(json!({
        "runner": "local", "name": "Review PRs", "cron": "*/15 9-17 * * 1-5", "enabled": false,
        "when": "gh pr list --json url", "flow": "pr-review", "cwd": "/tmp/repo", "model": "claude-sonnet-5-5",
        "allowed_tools": ["Bash(gh:*)", "Read"], "permission_mode": "acceptEdits", "timeout_minutes": 45, "notify": "quiet"
    }))
}

fn with(mut record: Record, change: Value) -> Record {
    record.extend(rec(change));
    record
}

#[test]
fn round_trips_the_record_and_prompt_through_two_files() {
    let w = World::new();
    w.store().write("digest", &cloud(), "Do the digest.\n\nSecond paragraph.\n").unwrap();
    let entry = w.store().read("digest").unwrap().unwrap();
    assert_eq!(entry.slug, "digest");
    assert_eq!(entry.record, with(cloud(), json!({"v": 1})));
    assert_eq!(entry.prompt, "Do the digest.\n\nSecond paragraph.\n");
    assert_eq!(w.file("digest.prompt.md"), "Do the digest.\n\nSecond paragraph.\n");
    assert!(w.file("digest.yml").starts_with("---\nv: 1\nroutine: trig_1\n"), "{}", w.file("digest.yml"));
}

#[test]
fn a_missing_automation_reads_as_nothing() {
    let w = World::new();
    assert!(w.store().read("nope").unwrap().is_none());
    assert!(!w.store().exists("nope"));
}

#[test]
fn unknown_keys_survive_a_rewrite_that_does_not_name_them() {
    let w = World::new();
    std::fs::create_dir_all(w.dir()).unwrap();
    std::fs::write(w.dir().join("digest.yml"), "v: 1\nroutine: trig_1\nname: Old\nmy_note: keep me\n").unwrap();
    std::fs::write(w.dir().join("digest.prompt.md"), "old prompt").unwrap();
    w.store().write("digest", &rec(json!({"name": "New"})), "new prompt").unwrap();
    assert_eq!(w.store().read("digest").unwrap().unwrap().record, rec(json!({"v": 1, "routine": "trig_1", "name": "New", "my_note": "keep me"})));
}

#[test]
fn an_overwrite_keeps_the_previous_files_as_bak() {
    let w = World::new();
    w.store().write("digest", &cloud(), "first").unwrap();
    w.store().write("digest", &with(cloud(), json!({"cron": "0 8 * * *"})), "second").unwrap();
    assert!(w.file("digest.yml.bak").contains("cron: 0 7 * * 1,4"));
    assert_eq!(w.file("digest.prompt.md.bak"), "first");
    assert_eq!(w.store().read("digest").unwrap().unwrap().record["cron"], "0 8 * * *");
}

#[test]
fn a_first_write_leaves_no_bak_and_no_temp_files() {
    let w = World::new();
    w.store().write("digest", &cloud(), "first").unwrap();
    let mut names: Vec<String> = std::fs::read_dir(w.dir()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    assert_eq!(names, ["digest.prompt.md", "digest.yml"]);
}

#[test]
fn a_failed_write_leaves_the_previous_file_whole() {
    let w = World::new();
    w.store().write("digest", &cloud(), "first").unwrap();
    std::fs::set_permissions(w.dir(), std::fs::Permissions::from_mode(0o555)).unwrap();
    let failed = w.store().write("digest", &with(cloud(), json!({"name": "Broken"})), "second");
    std::fs::set_permissions(w.dir(), std::fs::Permissions::from_mode(0o755)).unwrap();
    if std::fs::write(w.dir().join(".probe"), "").is_ok() && failed.is_ok() {
        return; // a user who ignores directory modes (root) can't make a write fail this way
    }
    assert!(failed.is_err());
    assert_eq!(w.store().read("digest").unwrap().unwrap().record["name"], "Digest");
    assert_eq!(w.file("digest.prompt.md"), "first");
}

#[test]
fn lists_slugs_finds_by_routine_and_deletes_locally() {
    let w = World::new();
    w.store().write("b-digest", &cloud(), "b").unwrap();
    w.store().write("a-review", &with(cloud(), json!({"routine": "trig_2"})), "a").unwrap();
    let slugs = |s: &AutomationStore| s.list().unwrap().into_iter().map(|e| e.slug).collect::<Vec<_>>();
    assert_eq!(slugs(&w.store()), ["a-review", "b-digest"]);
    assert_eq!(w.store().find_by_routine("trig_2").unwrap().unwrap().slug, "a-review");
    assert!(w.store().find_by_routine("trig_missing").unwrap().is_none());
    w.store().delete_local("b-digest").unwrap();
    assert!(!w.store().exists("b-digest"));
    assert_eq!(slugs(&w.store()), ["a-review"]);
}

#[test]
fn a_local_record_round_trips_its_fields_in_order_with_unknown_keys_kept() {
    let w = World::new();
    w.store().write("review-prs", &with(local(), json!({"my_note": "keep"})), "Review it.").unwrap();
    assert_eq!(w.store().read("review-prs").unwrap().unwrap().record, with(local(), json!({"v": 1, "my_note": "keep"})));
    let stored: Record = serde_yaml::from_str(&w.file("review-prs.yml")).unwrap();
    let keys: Vec<&String> = stored.keys().collect();
    assert_eq!(keys, ["v", "runner", "name", "cron", "when", "flow", "cwd", "model", "allowed_tools", "permission_mode", "enabled", "timeout_minutes", "notify", "my_note"]);
    assert!(w.file("review-prs.yml").contains("cron: \"*/15 9-17 * * 1-5\""), "{}", w.file("review-prs.yml"));
}

#[test]
fn local_settings_fill_flow_timeout_and_notify_defaults() {
    let settings = local_settings(&rec(json!({"runner": "local", "name": "X", "notify": null})));
    assert_eq!((&settings["flow"], &settings["timeout_minutes"], &settings["notify"]), (&json!("chat"), &json!(30), &json!("attention")));
    assert_eq!(local_settings(&local())["notify"], "quiet");
}

#[test]
fn a_local_record_refuses_bypass_permissions_and_bad_fields() {
    let cases = [
        (json!({"permission_mode": "bypassPermissions"}), "bypassPermissions"),
        (json!({"notify": "loud"}), "notify must be attention or quiet, got \"loud\""),
        (json!({"flow": ""}), "flow must be a flow name"),
        (json!({"flow": 3}), "flow must be a flow name, got 3"),
        (json!({"timeout_minutes": 0}), "timeout_minutes must be a positive whole number"),
        (json!({"timeout_minutes": "30"}), "timeout_minutes must be a positive whole number, got \"30\""),
        (json!({"allowed_tools": "Bash"}), "allowed_tools must be a list"),
        (json!({"repos": "acme/app"}), "repos must be a list of owner/name"),
        (json!({"repos": ["acme"]}), "repos must be a list of owner/name"),
        (json!({"repos": ["https://github.com/acme/app"]}), "repos must be a list of owner/name"),
    ];
    for (change, message) in cases {
        let w = World::new();
        let error = w.store().write("review-prs", &with(local(), change.clone()), "p").unwrap_err();
        assert!(error.message.contains(message), "{change}: {}", error.message);
        assert!(!w.store().exists("review-prs"), "nothing is written for {change}");
    }
    let all = validate_local(&with(local(), json!({"permission_mode": "bypassPermissions", "notify": "loud"}))).unwrap_err();
    assert!(all.message.contains("bypassPermissions") && all.message.contains("; notify must be"), "every bad field is named: {}", all.message);
    assert!(validate_local(&with(local(), json!({"repos": ["Acme/app.v2", "a-b/c_d"]}))).is_ok());
}

#[test]
fn an_invalid_change_merged_onto_a_stored_local_record_is_refused_and_leaves_it_whole() {
    let w = World::new();
    w.store().write("review-prs", &local(), "p").unwrap();
    assert!(w.store().write("review-prs", &rec(json!({"permission_mode": "bypassPermissions"})), "p").is_err());
    assert_eq!(w.store().read("review-prs").unwrap().unwrap().record["permission_mode"], "acceptEdits");
}

#[test]
fn cloud_records_are_not_held_to_local_rules() {
    let w = World::new();
    w.store().write("digest", &with(cloud(), json!({"permission_mode": "bypassPermissions", "notify": "loud"})), "x").unwrap();
    assert_eq!(w.store().read("digest").unwrap().unwrap().record["permission_mode"], "bypassPermissions");
}

#[test]
fn delete_local_also_removes_the_run_log() {
    let w = World::new();
    w.store().write("review-prs", &local(), "p").unwrap();
    RunLog::new("review-prs", &w.dir()).unwrap().checked(chrono::Utc::now()).unwrap();
    w.store().delete_local("review-prs").unwrap();
    assert!(std::fs::read_dir(w.dir()).unwrap().all(|e| e.unwrap().file_name().to_string_lossy().ends_with(".bak")));
}

#[test]
fn refuses_a_slug_that_is_not_a_plain_name() {
    let w = World::new();
    assert!(w.store().write("../evil", &cloud(), "x").is_err());
    assert!(w.store().read("a/b").is_ok_and(|e| e.is_none()), "a path is no automation, so it reads as absent");
    assert!(w.store().yml_path("a/b").is_err());
}
