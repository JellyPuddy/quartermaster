//! Work items of `kind: automation`: ordinary items that stay off every list of the user's work, one
//! test per surface.

mod common;
use common::*;
use quartermaster::attention::Attention;
use quartermaster::chat_attention::ChatAttention;
use quartermaster::work_item::WorkItem;
use serde_json::{json, Value};
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

/// A `qm new` item turned into an automation in state `state`, by editing its front matter.
fn automation(qm: &Qm, title: &str, state: &str) -> String {
    qm.ok(&["new", title, "--project", "MyApp"]);
    let slug = title.to_lowercase().replace(' ', "-");
    let path = qm.root.path().join(format!("work-items/{slug}.md"));
    let text = std::fs::read_to_string(&path).unwrap();
    let text = text.replacen("state: in_progress\n", &format!("state: {state}\nkind: automation\nroutine: trig_01JJ\nrunner: cloud\n"), 1);
    std::fs::write(&path, text).unwrap();
    slug
}

fn live_session(qm: &Qm, slug: &str, session: &str) {
    let start = json!({"v": 1, "event": "start", "session_id": session, "ts": "2026-11-01T10:00:00Z", "pid": std::process::id(), "cwd": "/tmp", "work_item": slug});
    let log = qm.root.path().join("sessions.jsonl");
    let old = std::fs::read_to_string(&log).unwrap_or_default();
    std::fs::write(&log, format!("{old}{start}\n")).unwrap();
    let path = qm.root.path().join(format!("work-items/{slug}.md"));
    let text = std::fs::read_to_string(&path).unwrap();
    std::fs::write(&path, text.replacen("sessions: []", &format!("sessions:\n- id: {session}\n  linked: 2026-11-01\n"), 1)).unwrap();
}

#[test]
fn the_frontmatter_reads_back_and_active_is_a_state() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let qm = Qm::new();
    let slug = automation(&qm, "Shipped digest", "active");
    std::env::set_var("QM_ROOT", qm.root.path());
    let item = WorkItem::find(&slug).unwrap();
    assert!(item.automation());
    assert_eq!([item.kind(), item.routine(), item.runner()], [Some("automation".into()), Some("trig_01JJ".into()), Some("cloud".into())]);
    assert_eq!(item.state().as_deref(), Some("active"));
    qm.ok(&["new", "Plain", "--project", "MyApp"]);
    assert!(!WorkItem::find("plain").unwrap().automation());
    let state = qm.run(&["state", "plain", "active"]);
    assert_eq!(state.code, 0, "{}", state.stderr);
    assert_eq!(WorkItem::find("plain").unwrap().state().as_deref(), Some("active"), "active is valid for any item");
}

#[test]
fn qm_list_leaves_automations_out_unless_asked_for_by_kind() {
    let qm = Qm::new();
    qm.ok(&["new", "Plain work", "--project", "MyApp"]);
    automation(&qm, "Shipped digest", "active");
    let plain = qm.ok(&["list"]);
    assert!(plain.contains("plain-work") && !plain.contains("shipped-digest"), "{plain}");
    let kinded = qm.ok(&["list", "--kind", "automation"]);
    assert!(kinded.contains("shipped-digest") && !kinded.contains("plain-work"), "{kinded}");
    assert!(qm.ok(&["help"]).contains("qm list [--kind automation]"));
}

#[test]
fn qm_show_names_kind_routine_and_runner() {
    let qm = Qm::new();
    automation(&qm, "Shipped digest", "active");
    let shown = qm.ok(&["show", "shipped-digest"]);
    assert!(shown.lines().nth(1).unwrap().contains("automation trig_01JJ (cloud)"), "{shown}");
}

#[test]
fn attention_skips_automations() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let qm = Qm::new();
    automation(&qm, "Quiet automation", "in_progress");
    qm.ok(&["new", "Quiet work", "--project", "MyApp"]);
    std::env::set_var("QM_ROOT", qm.root.path());
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(30 * 86_400);
    let slugs: Vec<String> = Attention::new(later).entries().unwrap().into_iter().map(|e| e.slug).collect();
    assert_eq!(slugs, ["quiet-work"]);
}

#[test]
fn the_chats_list_skips_automations_even_with_a_live_chat() {
    let _env = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let qm = Qm::new();
    let auto = automation(&qm, "Live automation", "in_progress");
    qm.ok(&["new", "Live work", "--project", "MyApp"]);
    live_session(&qm, &auto, "s-auto");
    live_session(&qm, "live-work", "s-work");
    std::env::set_var("QM_ROOT", qm.root.path());
    let slugs: Vec<String> = ChatAttention::new().entries().unwrap().into_iter().map(|e| e.slug).collect();
    assert_eq!(slugs, ["live-work"]);
}

#[test]
fn the_phone_page_neither_shows_nor_counts_automations() {
    let qm = Qm::new();
    automation(&qm, "Running digest", "active");
    automation(&qm, "Paused digest", "fridge");
    qm.ok(&["new", "Plain work", "--project", "MyApp"]);
    let doc: Value = serde_json::from_str(&qm.ok(&["overview", "--json"])).unwrap();
    let slugs: Vec<&str> = doc["items"].as_array().unwrap().iter().map(|r| r["slug"].as_str().unwrap()).collect();
    assert_eq!(slugs, ["plain-work"]);
    assert_eq!(doc["counts"]["states"], json!({"in_progress": 1, "active": 0, "fridge": 0, "resolved": 0}));
    assert_eq!(doc["counts"]["omitted"], 0, "a paused automation is not a left-out fridge item");
}

#[test]
fn the_viewer_rows_leave_automations_out() {
    let qm = Qm::new();
    qm.ok(&["new", "Plain work", "--project", "MyApp"]);
    automation(&qm, "Shipped digest", "active");
    let rows = qm.ok(&["viewer-rows", "--state", "all"]);
    assert!(rows.contains("plain-work") && !rows.contains("shipped-digest"), "{rows}");
}

#[test]
fn the_board_draws_only_items_that_are_not_automations() {
    let js = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/gui/js/board.js")).unwrap();
    let render = &js[js.find("function render()").unwrap()..];
    let render = &render[..render.find("\n}\n").unwrap()];
    assert!(render.contains("const boardItems = items.filter(it => it.kind !== \"automation\");"));
    assert!(!render.replace("items.filter(it => it.kind", "").contains("items.forEach"), "{render}");
    assert!(!render.replace("items.filter(it => it.kind", "").contains("items.filter"), "{render}");
    let css = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/gui/css/board.css")).unwrap();
    assert!(css.contains(".dot-active"));
}
