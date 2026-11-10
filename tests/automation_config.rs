//! The tick settings in config.yml (`automations.local_*`): defaults, overrides and `qm config set`.

mod common;
use common::*;
use quartermaster::project_config::ProjectConfig;

#[test]
fn unset_tick_settings_read_at_their_defaults() {
    let local = ProjectConfig::parse("projects: {}\n").local_automations().clone();
    assert_eq!((local.paused, local.max_running, local.hold_five_hour, local.hold_seven_day), (false, 2.0, 80.0, 90.0));
}

#[test]
fn set_tick_settings_are_read_and_a_wrong_type_falls_back() {
    let local = ProjectConfig::parse("automations: { local_paused: true, local_max_running: 4, local_hold_five_hour: 50.5, local_hold_seven_day: high }\n").local_automations().clone();
    assert_eq!((local.paused, local.max_running, local.hold_five_hour, local.hold_seven_day), (true, 4.0, 50.5, 90.0));
}

#[test]
fn qm_config_sets_and_checks_them() {
    let qm = Qm::new();
    qm.ok(&["config", "set", "automations.local_paused", "true"]);
    qm.ok(&["config", "set", "automations.local_max_running", "3"]);
    let written = qm.read("config.yml");
    assert!(written.contains("automations:\n  local_paused: true\n  local_max_running: 3\n"), "{written}");
    let bad = qm.run(&["config", "set", "automations.local_max_running", "many"]);
    assert_eq!(bad.code, 1, "{}", bad.stdout);
    assert!(bad.stderr.contains("automations.local_max_running"), "{}", bad.stderr);
    assert_eq!(qm.ok(&["config", "get", "automations.local_max_running"]).trim(), "3");
}

#[test]
fn the_token_source_is_off_until_set_and_only_claude_code_is_accepted() {
    assert_eq!(ProjectConfig::parse("projects: {}\n").automations_token_source(), None);
    assert_eq!(ProjectConfig::parse("automations: { token_source: claude_code }\n").automations_token_source(), Some("claude_code"));
    let key = quartermaster::config_schema::lookup("automations.token_source").unwrap();
    assert_eq!((key.kind, key.options), ("enum", Some(&["claude_code"][..])));
    let qm = Qm::new();
    let bad = qm.run(&["config", "set", "automations.token_source", "api_key"]);
    assert_eq!(bad.code, 1);
    assert!(bad.stderr.contains("must be one of: claude_code"), "{}", bad.stderr);
    qm.ok(&["config", "set", "automations.token_source", "claude_code"]);
    assert!(qm.read("config.yml").contains("automations:\n  token_source: claude_code\n"));
}
