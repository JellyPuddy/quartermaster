//! An option-looking argument whose second character is multi-byte is an invalid option, not a panic.

mod common;
use common::*;

#[test]
fn a_multibyte_short_option_is_refused_by_name() {
    let qm = Qm::new();
    qm.ok(&["new", "T"]);
    for (args, shown) in [(vec!["note", "t", "-é"], "-é"), (vec!["new", "-ö"], "-ö"), (vec!["note", "t", "-éa"], "-éa")] {
        let out = qm.run_with(&args, "", &[]);
        assert_eq!(out.code, 1, "{args:?}");
        assert!(out.stderr.contains(&format!("invalid option: {shown}")) && !out.stderr.contains("panicked"), "{args:?}: {}", out.stderr);
    }
}
