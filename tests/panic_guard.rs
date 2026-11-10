//! A panicking hook or status line exits 0 and stays silent; a hook's panic is logged to `qm.log`.

use quartermaster::panic_guard::contained;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(()); // the panic hook and QM_ROOT are process-wide

#[test]
fn a_hook_that_panics_exits_zero_and_logs_the_payload() {
    let _g = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let root = tempfile::tempdir().unwrap();
    std::env::set_var("QM_ROOT", root.path());
    let code = contained("hook-session-start", || -> i32 { panic!("slice out of range in the work item") });
    assert_eq!(code, 0);
    let log = std::fs::read_to_string(root.path().join("qm.log")).unwrap();
    assert!(log.contains("[hook-session-start] Panic:") && log.contains("slice out of range in the work item"), "{log}");
}

#[test]
fn a_status_line_that_panics_exits_zero_and_records_nothing() {
    let _g = ENV.lock().unwrap_or_else(|p| p.into_inner());
    let root = tempfile::tempdir().unwrap();
    let missing = root.path().join("never-created");
    std::env::set_var("QM_ROOT", &missing);
    assert_eq!(contained("statusline", || -> i32 { panic!("odd input") }), 0);
    assert!(!missing.exists());
}

#[test]
fn a_normal_run_keeps_its_exit_code() {
    let _g = ENV.lock().unwrap_or_else(|p| p.into_inner());
    assert_eq!(contained("hook-session-end", || 7), 7);
}
