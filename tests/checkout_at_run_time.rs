//! The checkout is found from where the binary runs, not from where it was built: a checkout moved after
//! the build, or a binary run from another one, answers with its own launcher and hook paths.

use std::path::Path;
use std::process::Command;

#[test]
fn a_binary_in_a_moved_checkout_names_that_checkouts_launcher() {
    let dir = tempfile::tempdir().unwrap();
    let moved = std::fs::canonicalize(dir.path()).unwrap().join("moved");
    std::fs::create_dir_all(moved.join("target/release")).unwrap();
    std::fs::create_dir_all(moved.join("gui")).unwrap();
    std::fs::write(moved.join("quartermaster"), "#!/bin/sh\n").unwrap();
    std::fs::copy(env!("CARGO_BIN_EXE_qm"), moved.join("target/release/qm")).unwrap();
    let out = Command::new(moved.join("target/release/qm")).arg("install-hooks").env("QM_ROOT", dir.path().join("root")).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains(&format!("{} hook-session-start", moved.join("quartermaster").display())), "{text}");
    assert!(!text.contains(env!("CARGO_MANIFEST_DIR")) || Path::new(env!("CARGO_MANIFEST_DIR")) == moved, "{text}");
}
