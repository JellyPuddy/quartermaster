//! The usage ledger is a record: a save never overwrites a file that isn't a ledger, and concurrent savers
//! keep each other's sessions.

mod common;
use common::*;
use quartermaster::session_log::SessionLog;
use quartermaster::usage_ledger::UsageLedger;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Barrier, Mutex};

static ENV: Mutex<()> = Mutex::new(());

const OLD_LEDGER: &str = r#"{"v":1,"sessions":{"old-session":{"main":["/x",1,1.0],"files":{}}}}"#;
const TRUNCATED: &str = r#"{"v":1,"sessions":{"old-session":{"main":["/x",1,1.0],"fil"#;

struct World {
    qm: Qm,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl World {
    fn new() -> World {
        let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let qm = Qm::new();
        std::env::set_var("QM_ROOT", qm.root.path());
        std::env::set_var("QM_TRANSCRIPTS_DIR", qm.root.path().join("transcripts"));
        World { qm, _guard: guard }
    }

    fn root(&self) -> &Path {
        self.qm.root.path()
    }

    fn ledger_path(&self) -> PathBuf {
        self.root().join("usage-cache.json")
    }

    fn write_ledger(&self, content: &str) {
        fs::write(self.ledger_path(), content).unwrap();
    }

    fn asides(&self) -> Vec<PathBuf> {
        let mut found: Vec<PathBuf> = fs::read_dir(self.root()).unwrap().map(|e| e.unwrap().path()).filter(|p| p.to_string_lossy().contains("usage-cache.json.corrupt-")).collect();
        found.sort();
        found
    }

    /// A captured session whose transcript spent a few tokens.
    fn start(&self, id: &str) {
        let transcript = self.root().join(format!("transcripts/p/{id}.jsonl"));
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::write(&transcript, format!("{{\"type\":\"assistant\",\"message\":{{\"id\":\"{id}-m\",\"model\":\"claude-opus-5-5\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":10}}}}}}\n")).unwrap();
        let start = format!("{{\"v\":1,\"event\":\"start\",\"session_id\":\"{id}\",\"cwd\":\"/srv/app\",\"transcript_path\":\"{}\",\"ts\":\"2026-01-01T00:00:00Z\"}}\n", transcript.display());
        let mut log = fs::OpenOptions::new().create(true).append(true).open(self.root().join("sessions.jsonl")).unwrap();
        std::io::Write::write_all(&mut log, start.as_bytes()).unwrap();
    }

    /// A ledger that has tallied session `id` and not yet saved.
    fn tallied(&self, id: &str) -> UsageLedger {
        self.start(id);
        let mut ledger = UsageLedger::new();
        let sessions = SessionLog::read().sessions();
        ledger.session_usage(sessions.iter().find(|s| s.id == id).unwrap()).unwrap();
        ledger
    }

    fn saved_sessions(&self) -> Vec<String> {
        let data: serde_json::Value = serde_json::from_str(&fs::read_to_string(self.ledger_path()).unwrap()).unwrap();
        let mut ids: Vec<String> = data["sessions"].as_object().unwrap().keys().cloned().collect();
        ids.sort();
        ids
    }
}

fn contents(paths: &[PathBuf]) -> Vec<String> {
    paths.iter().map(|p| fs::read_to_string(p).unwrap()).collect()
}

#[test]
fn saving_over_an_unparseable_ledger_keeps_it_aside_and_logs_why() {
    let w = World::new();
    w.write_ledger(TRUNCATED);

    w.tallied("s1").save();

    let asides = w.asides();
    assert_eq!(asides.len(), 1);
    let name = asides[0].file_name().unwrap().to_string_lossy().into_owned();
    assert!(regex::Regex::new(r"\.corrupt-\d{8}T\d{6}Z$").unwrap().is_match(&name), "{name}");
    assert_eq!(contents(&asides), vec![TRUNCATED], "the unreadable record is kept byte for byte");
    assert_eq!(w.saved_sessions(), vec!["s1"]);
    let log = fs::read_to_string(w.root().join("qm.log")).unwrap();
    assert!(regex::Regex::new(r"\[usage-ledger\] \S+: .*corrupt-").unwrap().is_match(&log), "{log}");
}

#[test]
fn a_json_file_not_shaped_as_a_ledger_is_kept_aside_too() {
    let w = World::new();
    w.write_ledger("[1, 2]");
    w.tallied("s1").save();
    assert_eq!(contents(&w.asides()), vec!["[1, 2]"]);
}

#[test]
fn reading_an_unparseable_ledger_leaves_it_in_place() {
    let w = World::new();
    w.write_ledger(TRUNCATED);
    let mut ledger = w.tallied("s1");

    assert!(w.asides().is_empty());
    assert_eq!(fs::read_to_string(w.ledger_path()).unwrap(), TRUNCATED);
    ledger.save();
    ledger.save();
    assert_eq!(w.asides().len(), 1, "a second save finds a ledger, not the corrupt file");
}

#[test]
fn an_unchanged_ledger_never_saves_so_never_moves_a_corrupt_file() {
    let w = World::new();
    w.write_ledger(TRUNCATED);
    UsageLedger::new().save();
    assert!(w.asides().is_empty());
    assert_eq!(fs::read_to_string(w.ledger_path()).unwrap(), TRUNCATED);
}

#[test]
fn two_savers_who_both_saw_the_corrupt_file_keep_each_others_sessions() {
    let w = World::new();
    w.write_ledger(TRUNCATED);
    let (mut first, mut second) = (w.tallied("s1"), w.tallied("s2"));

    first.save();
    second.save();

    assert_eq!(contents(&w.asides()), vec![TRUNCATED]);
    assert_eq!(w.saved_sessions(), vec!["s1", "s2"]);
}

#[test]
fn concurrent_savers_set_the_corrupt_file_aside_once_and_lose_no_session() {
    let w = World::new();
    let ids: Vec<String> = (1..=6).map(|n| format!("s{n}")).collect();
    w.write_ledger(TRUNCATED);
    let ledgers: Vec<UsageLedger> = ids.iter().map(|id| w.tallied(id)).collect();
    let barrier = Barrier::new(ledgers.len());

    std::thread::scope(|scope| {
        for mut ledger in ledgers {
            let barrier = &barrier;
            scope.spawn(move || {
                barrier.wait();
                ledger.save();
            });
        }
    });

    assert_eq!(contents(&w.asides()), vec![TRUNCATED]);
    assert_eq!(w.saved_sessions(), ids);
}

#[test]
fn saving_over_a_valid_ledger_merges_and_sets_nothing_aside() {
    let w = World::new();
    w.write_ledger(OLD_LEDGER);
    w.tallied("s1").save();
    assert!(w.asides().is_empty());
    assert_eq!(w.saved_sessions(), vec!["old-session", "s1"]);
}

#[test]
fn a_ledger_that_cannot_be_read_is_not_saved_over() {
    let w = World::new();
    fs::create_dir(w.ledger_path()).unwrap(); // exists, but reading it fails
    w.tallied("s1").save();
    assert!(w.ledger_path().is_dir() && w.asides().is_empty());
    assert!(fs::read_to_string(w.root().join("qm.log")).unwrap().contains("[usage-ledger]"));
}
