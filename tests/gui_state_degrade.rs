//! One odd timestamp, draft file or work item costs `/api/state` only its own part: the rest of the state is
//! still built, as `GuiState` rescued per section. Expected values are written out; no Ruby oracle.

use quartermaster::gui_state;
use serde_json::{json, Value};
use std::fs;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

fn item(title: &str, extra: &str) -> String {
    format!("---\nv: 1\ntitle: {title}\nstate: in_progress\ncreated: '2026-01-01'\n{extra}---\n\n## Description\n\nd\n\n## Notes\n\n## Snapshots\n")
}

/// A data root with a good item, an item holding an odd-timestamp session, an item whose drafts file holds a
/// float, and a malformed item file.
fn world() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::env::set_var("QM_ROOT", root);
    std::env::set_var("QM_TMUX_SOCKET", "qm-test-gui-degrade");
    fs::create_dir_all(root.join("work-items")).unwrap();
    fs::create_dir_all(root.join("drafts")).unwrap();
    fs::write(root.join("work-items/a-good.md"), item("Good", "")).unwrap();
    fs::write(root.join("work-items/b-odd.md"), item("Odd", "sessions:\n- id: s-odd\n")).unwrap();
    fs::write(root.join("work-items/c-float.md"), item("Float", "")).unwrap();
    fs::write(root.join("work-items/d-broken.md"), "no frontmatter at all\n").unwrap();
    fs::write(root.join("sessions.jsonl"), "{\"v\":1,\"event\":\"start\",\"session_id\":\"s-odd\",\"cwd\":\"/\",\"ts\":\"last tuesday\"}\n").unwrap();
    fs::write(root.join("drafts/c-float.json"), "{\"entries\": [{\"kind\": \"note\", \"score\": 1.5}]}").unwrap();
    dir
}

fn row<'a>(state: &'a Value, slug: &str) -> &'a Value {
    state["items"].as_array().unwrap().iter().find(|i| i["slug"] == slug).unwrap_or_else(|| panic!("no {slug} in {}", state["items"]))
}

#[test]
fn an_unparseable_timestamp_has_no_relative_time_instead_of_an_error() {
    assert_eq!(gui_state::relative_when(Some("last tuesday")), None);
    assert_eq!(gui_state::relative_when(Some("")), None);
    assert_eq!(gui_state::relative_when(None), None);
    assert_eq!(gui_state::relative_when(Some("2020-01-02T03:04:05Z")), Some("2020-01-02".to_string()));
}

#[test]
fn an_odd_timestamp_a_float_draft_and_a_broken_item_leave_the_rest_of_the_state_built() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let dir = world();
    let state = gui_state::build("tok");
    let slugs: Vec<&str> = state["items"].as_array().unwrap().iter().map(|i| i["slug"].as_str().unwrap()).collect();
    assert_eq!(slugs, ["a-good", "b-odd", "c-float"], "the malformed item is left out, the others stay");
    assert_eq!(state["terminalToken"], "tok");
    assert_eq!(row(&state, "a-good")["title"], "Good");
    // the odd-timestamp session still lists, its time unknown
    assert_eq!(row(&state, "b-odd")["sessionList"], json!([{"id": "s-odd", "tier": "expired", "when": "—", "prompt": null}]));
    assert!(row(&state, "b-odd")["updated"].as_str().is_some_and(|d| d.len() == 10), "{}", row(&state, "b-odd")["updated"]);
    // the float draft file reads as no drafts
    assert_eq!(row(&state, "c-float")["drafts"], json!([]));
    let log = fs::read_to_string(dir.path().join("qm.log")).unwrap_or_default();
    assert!(log.contains("[gui-item]") && log.contains("[gui-drafts]"), "{log}");
}

#[test]
fn the_attention_payload_survives_a_float_draft_file_too() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let _dir = world();
    let payload = gui_state::attention_payload();
    assert_eq!(payload["draftCounts"], json!({}));
    assert!(payload["attention"].is_array());
}
