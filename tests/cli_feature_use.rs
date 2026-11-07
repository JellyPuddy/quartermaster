//! `qm feature-use`: the report over a hand-written log, its options, and the unknown-command answer.
//! Transcripts generated from Ruby.

mod common;
use common::*;

#[test]
fn feature_use_reports_and_unknown_commands_are_refused() {
    let qm = Qm::new();
    qm.ok(&["list"]);
    let now = chrono::Utc::now();
    let at = |days: i64| (now - chrono::Duration::days(days)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut log = String::new();
    for (days, kind, name) in [(40, "cli", "list"), (20, "cli", "list"), (3, "cli", "list"), (2, "cli", "show"), (2, "cli", "show"), (1, "action", "note"), (1, "get", "/api/prs"), (5, "action", "pr"), (5, "action", "pr")] {
        log += &format!("{{\"v\":1,\"at\":\"{}\",\"kind\":\"{kind}\",\"name\":\"{name}\"}}\n", at(days));
    }
    log += "not json\n[]\n{\"at\":\"nonsense\",\"kind\":\"cli\",\"name\":\"x\"}\n";
    std::fs::write(qm.root.path().join("feature-use.jsonl"), log).unwrap();
    let steps: Vec<Step> = vec![
        (&["feature-use"], ""),
        (&["feature-use", "--days", "7"], ""),
        (&["feature-use", "--days=7"], ""),
        (&["feature-use", "--da", "7"], ""),
        (&["feature-use", "--days", "0"], ""),
        (&["feature-use", "--days", "-3"], ""),
        (&["feature-use", "--days", "x"], ""),
        (&["feature-use", "--days"], ""),
        (&["feature-use", "7"], ""),
        (&["feature-use", "--bogus"], ""),
        (&["feature-use", "-x"], ""),
        (&["bogus"], ""),
        (&["--bogus"], ""),
    ];
    golden("cli_feature_use.txt", &normalize(&transcript(&qm, "none", &steps)));
}
