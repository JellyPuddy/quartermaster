//! A plain `yes`/`no`/`on`/`off` on a schema boolean key is the boolean Psych read, in the file as loaded: the check
//! accepts it, a later write keeps it as `true`/`false`, and every reader sees it. A quoted one is still text.
//! Expected values written out; no Ruby oracle.

use quartermaster::config_file::ConfigFile;
use quartermaster::project_config::ProjectConfig;
use serde_yaml::Value;
use std::fs;

fn load(text: &str) -> (tempfile::TempDir, ConfigFile) {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("config.yml");
    fs::write(&file, text).unwrap();
    let config = ConfigFile::load(&file);
    (dir, config)
}

fn flagged(config: &ConfigFile) -> Vec<(String, String)> {
    config.errors().into_iter().map(|i| (i.path, i.message)).collect()
}

#[test]
fn a_hand_written_plain_yes_is_true_and_does_not_block_a_later_write() {
    let (dir, mut config) = load("automations:\n  local_paused: yes # paused by hand\ndefault_project: App\nprojects:\n  App: /code/app\n  Other: /code/other\n");
    assert_eq!(config.get("automations.local_paused"), Some(Value::Bool(true)));
    assert_eq!(flagged(&config), vec![]);
    config.set("default_project", Value::String("Other".into())).unwrap();
    config.write(None).unwrap_or_else(|e| panic!("{}", e.message()));
    let written = fs::read_to_string(dir.path().join("config.yml")).unwrap();
    assert!(written.contains("local_paused: true\n"), "{written}");
    assert!(written.contains("default_project: Other\n"), "{written}");
    assert!(!written.contains("yes"), "{written}");
}

#[test]
fn every_plain_psych_spelling_is_read_in_block_and_flow_form_at_any_depth() {
    for (spelling, expected) in [("yes", true), ("YES", true), ("On", true), ("no", false), ("No", false), ("OFF", false)] {
        let block = format!("projects:\n  App:\n    root: /code/app\n    pr_prerequisites: {spelling}\n");
        let flow = format!("projects: {{ App: {{ root: /code/app, pr_prerequisites: {spelling} }} }}\n");
        for text in [block, flow] {
            let (_dir, config) = load(&text);
            assert_eq!(config.get("projects.App.pr_prerequisites"), Some(Value::Bool(expected)), "{text}");
            assert_eq!(flagged(&config), vec![], "{text}");
            assert_eq!(ProjectConfig::parse(&text).settings(Some("App")).unwrap().pr_prerequisites, expected, "{text}");
        }
    }
}

#[test]
fn quoted_and_other_spellings_stay_text_and_are_flagged() {
    for (text, path) in [
        ("automations:\n  local_paused: 'yes'\n", "automations.local_paused"),
        ("automations:\n  local_paused: \"on\"\n", "automations.local_paused"),
        ("automations: { local_paused: 'yes' }\n", "automations.local_paused"),
        ("automations:\n  local_paused: y\n", "automations.local_paused"),
        ("automations:\n  local_paused: n\n", "automations.local_paused"),
        ("projects:\n  App:\n    root: /code/app\n    pr_prerequisites: 'yes'\n", "projects.App.pr_prerequisites"),
    ] {
        let (_dir, config) = load(text);
        assert_eq!(flagged(&config), vec![(path.to_string(), "must be true or false".to_string())], "{text}");
    }
    assert!(!ProjectConfig::parse("projects:\n  p:\n    root: /r\n    pr_prerequisites: \"yes\"\n").settings(Some("p")).unwrap().pr_prerequisites);
}

#[test]
fn a_yes_on_a_key_that_is_no_boolean_is_left_alone() {
    let (_dir, config) = load("default_project: yes\nautomations:\n  local_paused: yes\n");
    assert_eq!(config.get("default_project"), Some(Value::String("yes".into())));
    assert_eq!(config.get("automations.local_paused"), Some(Value::Bool(true)));
}
