//! `ack` and `snooze`, as transcripts generated from Ruby over the attention world.

mod common;
use common::*;
use std::time::SystemTime;

fn run_steps(retention: Option<u32>, watch: &str, steps: &[Step]) -> String {
    let base = tempfile::tempdir().unwrap();
    let w = attention_world(base.path(), SystemTime::now(), retention);
    let qm = Qm::at(&w.root);
    let home = w.home.display().to_string();
    let transcripts = w.transcripts.display().to_string();
    let env = [("HOME", home.as_str()), ("QM_TRANSCRIPTS_DIR", transcripts.as_str())];
    transcript_env(&qm, watch, steps, &env)
        .replace(&base.path().display().to_string(), "BASE")
}

#[test]
fn ack_acknowledges_every_degrading_session_or_the_one_named() {
    let steps: Vec<Step> = vec![
        (&["ack", "stale"], ""),
        (&["ack", "degrade"], ""),
        (&["ack", "degrade"], ""),
        (&["ack", "degrade", "d-fresh"], ""),
        (&["ack", "degrade", "not-attached"], ""),
        (&["ack", "degrade", "d-fresh"], ""),
        (&["ack", "ghost"], ""),
        (&["ack"], ""),
    ];
    golden("attention_ack.txt", &run_steps(None, "degrade", &steps));
}

#[test]
fn ack_follows_the_configured_retention() {
    let steps: Vec<Step> = vec![(&["ack", "degrade"], "")];
    golden("attention_ack_retention.txt", &run_steps(Some(10), "degrade", &steps));
}

#[test]
fn snooze_sets_clears_and_refuses() {
    let steps: Vec<Step> = vec![
        (&["snooze", "stale", "1d"], ""),
        (&["snooze", "stale", "7d"], ""),
        (&["snooze", "stale", "30d"], ""),
        (&["snooze", "stale", "0d"], ""),
        (&["snooze", "stale", "turn"], ""),
        (&["snooze", "stale", "1d"], ""),
        (&["snooze", "stale", "clear"], ""),
        (&["snooze", "stale", "clear"], ""),
        (&["snooze", "stale", "turn"], ""),
        (&["snooze", "stale", "bogus"], ""),
        (&["snooze", "stale", "1D"], ""),
        (&["snooze", "stale", "d"], ""),
        (&["snooze", "stale", "-1d"], ""),
        (&["snooze", "stale", "10d "], ""),
        (&["snooze", "stale"], ""),
        (&["snooze"], ""),
        (&["snooze", "ghost", "1d"], ""),
        (&["snooze", "snoozed-past", "clear"], ""),
    ];
    golden("attention_snooze.txt", &run_steps(None, "stale", &steps));
}
