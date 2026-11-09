//! How a work item reaches the disk: whole files for lock-free readers, and a stale handle never
//! writing a deleted item back.

mod common;
use common::*;
use quartermaster::work_item::WorkItem;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

static ENV: Mutex<()> = Mutex::new(());

fn long_item(qm: &Qm, title: &str) {
    qm.ok(&["new", title, "--project", "MyApp", "--description", &"long history\n".repeat(20_000)]);
}

#[test]
fn concurrent_qm_note_processes_all_land() {
    let qm = Qm::new();
    long_item(&qm, "Shared");
    let handles: Vec<_> = (1..=12)
        .map(|i| {
            let root = qm.root.path().to_path_buf();
            std::thread::spawn(move || Qm::at(&root).run(&["note", "shared", &format!("n{i}")]))
        })
        .collect();
    for h in handles {
        let out = h.join().unwrap();
        assert_eq!(out.code, 0, "{}", out.stderr);
    }
    let shown = qm.ok(&["show", "shared"]);
    for i in 1..=12 {
        assert!(shown.contains(&format!("n{i}\n")), "note n{i} missing:\n{}", &shown[shown.len().saturating_sub(400)..]);
    }
}

#[test]
fn a_reader_racing_saves_never_sees_a_partial_file() {
    let qm = Qm::new();
    long_item(&qm, "Busy");
    let path = qm.root.path().join("work-items/busy.md");
    let stop = Arc::new(AtomicBool::new(false));
    let reader = {
        let (path, stop) = (path.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut torn = 0;
            while !stop.load(Ordering::Relaxed) {
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                if !text.starts_with("---\n") || !text.contains("long history") {
                    torn += 1;
                }
            }
            torn
        })
    };
    for i in 0..60 {
        qm.ok(&["note", "busy", &format!("n{i}")]);
    }
    stop.store(true, Ordering::Relaxed);
    assert_eq!(reader.join().unwrap(), 0, "a read saw a truncated or missing item");
}

#[test]
fn a_save_leaves_no_temp_file_and_keeps_the_items_permissions() {
    let qm = Qm::new();
    qm.ok(&["new", "Private", "--project", "MyApp"]);
    let path = qm.root.path().join("work-items/private.md");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    qm.ok(&["note", "private", "still private"]);
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let mut names: Vec<String> = std::fs::read_dir(path.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    assert_eq!(names, vec![".lock", "private.md"]);
}

#[test]
fn a_stale_handle_never_resurrects_a_deleted_item() {
    let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    std::env::set_var("QM_ROOT", qm.root.path());
    WorkItem::create("Gone", "MyApp", None, None, None, None).unwrap();
    let mut handle = WorkItem::find("gone").unwrap();
    std::fs::remove_file(WorkItem::path_for("gone")).unwrap();
    let error = handle.add_note("too late", "decision").unwrap_err();
    assert_eq!(error.message, "no work item 'gone'");
    assert!(!WorkItem::path_for("gone").exists());
}
