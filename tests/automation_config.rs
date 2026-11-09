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
