//! `qm retag` reads POSITION like Ruby's `Integer(position, exception: false) || 0`: the whole text must be an
//! integer, so `3x`, `3.5` and `3,` name no note, while `+1` is note 1.

mod common;
use common::*;

fn world() -> Qm {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    qm.ok(&["note", "t", "first"]);
    qm.ok(&["note", "t", "second"]);
    qm
}

#[test]
fn text_that_only_starts_with_a_number_names_no_note() {
    let qm = world();
    for bad in ["1x", "1.5", "1,", "abc"] {
        let out = qm.run_with(&["retag", "t", bad, "open"], "", &[]);
        assert_eq!(out.code, 1, "{bad}");
        assert!(out.stderr.contains("note #0 does not exist"), "{bad}: {}", out.stderr);
    }
    assert!(!qm.read("work-items/t.md").contains("[open]"));
}

#[test]
fn a_plus_sign_and_padding_are_read_as_ruby_reads_them() {
    let qm = world();
    let out = qm.run_with(&["retag", "t", "+2", "open"], "", &[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let item = qm.read("work-items/t.md");
    assert!(item.contains("[open]: second"), "{item}");
}
