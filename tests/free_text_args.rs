//! Free text that starts with a dash is text, `--` ends options, and a bad option is a one-line `qm:`
//! error, never a backtrace.

mod common;
use common::*;

fn title(qm: &Qm, slug: &str) -> String {
    qm.read(&format!("work-items/{slug}.md")).lines().find_map(|l| l.strip_prefix("title: ").map(|t| t.trim_matches(['\'', '"']).to_string())).unwrap_or_default()
}

fn notes(qm: &Qm, slug: &str) -> Vec<String> {
    qm.read(&format!("work-items/{slug}.md")).lines().filter(|l| l.starts_with("- ") && l.contains(": ") && l.contains("DATE")).map(String::from).collect()
}

#[test]
fn new_takes_a_dash_leading_title() {
    let qm = Qm::new();
    assert_eq!(qm.ok(&["new", "- dash start"]), "dash-start\n");
    assert_eq!(title(&qm, "dash-start"), "- dash start");
}

#[test]
fn new_keeps_its_flags_around_dash_leading_text() {
    let qm = Qm::new();
    qm.ok(&["new", "--project=My App", "- dash start", "--session", "sess-1", "--description", "- a list"]);
    let item = qm.read("work-items/dash-start.md");
    assert!(item.contains("project: My App") && item.contains("- id: sess-1"), "{item}");
    assert!(item.contains("## Description\n\n- a list\n"), "{item}");
}

#[test]
fn dash_text_is_never_read_as_an_abbreviated_option() {
    let qm = Qm::new();
    assert_eq!(qm.ok(&["new", "-d does stuff"]), "d-does-stuff\n");
    assert_eq!(title(&qm, "d-does-stuff"), "-d does stuff");
    qm.ok(&["new", "Target"]);
    qm.ok(&["note", "target", "-k keeps going"]);
    assert_eq!(notes(&qm, "target"), vec!["- DATE: -k keeps going"]);
}

#[test]
fn note_takes_a_dash_leading_text_and_keeps_kind() {
    let qm = Qm::new();
    qm.ok(&["new", "Target"]);
    qm.ok(&["note", "target", "- a bullet"]);
    qm.ok(&["note", "target", "--kind", "open", "- chosen"]);
    assert_eq!(notes(&qm, "target"), vec!["- DATE: - a bullet", "- DATE [open]: - chosen"]);
}

#[test]
fn double_dash_ends_options() {
    let qm = Qm::new();
    qm.ok(&["new", "Target"]);
    qm.ok(&["note", "target", "--", "--kind", "is", "text"]);
    qm.ok(&["new", "--", "-x"]);
    qm.ok(&["retitle", "target", "--", "-renamed"]);
    assert_eq!(notes(&qm, "target"), vec!["- DATE: --kind is text"]);
    assert_eq!(title(&qm, "x"), "-x");
    assert_eq!(title(&qm, "target"), "-renamed");
}

#[test]
fn describe_drops_the_double_dash() {
    let qm = Qm::new();
    qm.ok(&["new", "Target"]);
    qm.ok(&["describe", "target", "--", "- first point"]);
    let item = qm.read("work-items/target.md");
    assert!(item.contains("## Description\n\n- first point\n"), "{item}");
}

#[test]
fn loose_counts_a_dash_text_as_one_prompt() {
    let qm = Qm::new();
    let out = qm.run(&["loose", "- one prompt", "second"]);
    assert_eq!(out.code, 1);
    assert!(out.stderr.starts_with("usage: qm loose [--project P]") && out.stderr.contains("[--] [\"first prompt\"]"), "{}", out.stderr);
}

#[test]
fn a_bad_flag_is_a_one_line_error() {
    let qm = Qm::new();
    let out = qm.run(&["new", "Title", "--bogus"]);
    assert_eq!((out.code, out.stderr.as_str()), (1, "qm: invalid option: --bogus\n"));
    qm.ok(&["new", "Some slug"]);
    let out = qm.run(&["note", "some-slug", "text", "--kind"]);
    assert_eq!((out.code, out.stderr.as_str()), (1, "qm: missing argument: --kind\n"));
}
