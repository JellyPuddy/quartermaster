//! `command_runner::call_bounded`: output and success as usual, a command past its time limit killed with
//! its whole process group.

use quartermaster::command_runner::call_bounded;
use std::time::Instant;

#[test]
fn a_command_inside_its_limit_answers_as_usual() {
    let dir = tempfile::tempdir().unwrap();
    let r = call_bounded(&["sh", "-c", "pwd; echo oops >&2; exit 3"], Some(&dir.path().to_string_lossy()), 10);
    assert!(!r.success);
    assert_eq!(std::fs::canonicalize(r.out.trim()).unwrap(), std::fs::canonicalize(dir.path()).unwrap());
    assert_eq!(r.err, "oops\n");
    assert!(call_bounded(&["true"], None, 10).success);
}

#[test]
fn a_command_past_its_limit_is_killed_with_its_children() {
    let dir = tempfile::tempdir().unwrap();
    let marker = dir.path().join("survivor");
    let script = format!("(sleep 2; touch {}) & sleep 30", marker.display());
    let started = Instant::now();
    let r = call_bounded(&["sh", "-c", &script], None, 1);
    assert!(started.elapsed().as_secs() < 10, "the limit was not enforced");
    assert_eq!((r.success, r.out.as_str(), r.err.as_str()), (false, "", "timed out after 1 s"));
    std::thread::sleep(std::time::Duration::from_millis(2500));
    assert!(!marker.exists(), "the child outlived the process group's kill");
}

#[test]
fn a_program_that_does_not_exist_fails_with_its_reason() {
    let r = call_bounded(&["qm-no-such-program"], None, 5);
    assert!(!r.success && r.err.contains("No such file or directory - qm-no-such-program"), "{}", r.err);
}
