//! `qm overview` over the attention world: the snapshot, its file form, the page URL and the
//! published-page record. Transcripts generated from Ruby.

mod common;
use common::*;
use std::time::SystemTime;

#[test]
fn overview_snapshot_url_and_page() {
    let base = tempfile::tempdir().unwrap();
    let w = attention_world(base.path(), SystemTime::now(), None);
    let qm = Qm::at(&w.root);
    let home = w.home.display().to_string();
    let transcripts = w.transcripts.display().to_string();
    let env = [("HOME", home.as_str()), ("QM_TRANSCRIPTS_DIR", transcripts.as_str())];
    let out_path = base.path().join("out/overview.json").display().to_string();
    let mut text = String::new();
    let mut step = |args: &[&str]| text += &transcript_env(&qm, "none", &[(args, "")], &env);
    step(&["overview"]);
    step(&["overview", "--bogus"]);
    step(&["overview", "--json"]);
    step(&["overview", "--json", &out_path]);
    step(&["overview", "--url"]);
    std::fs::write(w.root.join("config.yml"), "overview_artifact: '  https://claude.ai/artifact/abc  '\n").unwrap();
    step(&["overview", "--url"]);
    std::fs::write(w.root.join("config.yml"), "overview_artifact: 5\n").unwrap();
    step(&["overview", "--url"]);
    step(&["overview", "--page"]);
    step(&["overview", "--page-published"]);
    step(&["overview", "--page"]);
    std::fs::write(w.root.join("overview-page.sha256"), "stale\n").unwrap();
    step(&["overview", "--page"]);
    let file = std::fs::read_to_string(&out_path).unwrap_or_default();
    let record = std::fs::read_to_string(w.root.join("overview-page.sha256")).unwrap_or_default();
    let text = format!("{text}file:\n{file}\nrecord: {}\n", record.trim().len());
    let text = text.replace(&base.path().display().to_string(), "BASE").replace(env!("CARGO_MANIFEST_DIR"), "REPO");
    golden("cli_overview.txt", &normalize(&text));
}
