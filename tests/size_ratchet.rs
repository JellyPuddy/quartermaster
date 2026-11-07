//! Big files may only shrink: a file over its threshold is pinned at its size in `tests/size_limits.json`,
//! and CLAUDE.md (paid by every session) is always pinned. `QM_LOWER_LIMITS=1 cargo test --test
//! size_ratchet` locks shrinkage in; it never raises a limit.

use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

const ALWAYS_PINNED: &str = "CLAUDE.md"; // measured in bytes, every other file in lines
const THRESHOLDS: [(&str, &str, usize); 5] = [("src", "rs", 400), ("gui/js", "js", 400), ("gui/css", "css", 400), ("gui", "html", 400), ("tests", "rs", 800)];
const SLACK: f64 = 0.9; // a pinned file at or below 90% of its limit must be lowered
const ADVICE: &str = "Split the file along a real seam, or deliberately raise its limit in tests/size_limits.json, saying so in its own line of the commit message.";

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn limits_file() -> PathBuf {
    repo().join("tests/size_limits.json")
}

fn threshold_by_path(root: &Path) -> Vec<(String, usize)> {
    let mut out = vec![];
    for (dir, ext, max) in THRESHOLDS {
        let Ok(entries) = fs::read_dir(root.join(dir)) else { continue };
        let mut names: Vec<String> = entries.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.is_file() && p.extension().is_some_and(|e| e == ext)).map(|p| p.strip_prefix(root).unwrap().to_string_lossy().into_owned()).collect();
        names.sort();
        out.extend(names.into_iter().map(|n| (n, max)));
    }
    out
}

fn size(root: &Path, path: &str) -> Option<usize> {
    let full = root.join(path);
    if !full.is_file() {
        return None;
    }
    if path == ALWAYS_PINNED { fs::metadata(&full).ok().map(|m| m.len() as usize) } else { fs::read(&full).ok().map(|b| b.iter().filter(|c| **c == b'\n').count()) }
}

fn unit(path: &str) -> &'static str {
    if path == ALWAYS_PINNED { "bytes" } else { "lines" }
}

fn problems(root: &Path, limits: &Map<String, Value>) -> Vec<String> {
    let mut out = vec![];
    for (path, limit) in limits {
        let limit = limit.as_u64().unwrap() as usize;
        match size(root, path) {
            None => out.push(format!("{path} is pinned but gone: run `QM_LOWER_LIMITS=1 cargo test --test size_ratchet`.")),
            Some(now) if now > limit => out.push(format!("{path} grew to {now} {}, past its limit of {limit}. {ADVICE}", unit(path))),
            Some(now) if (now as f64) <= limit as f64 * SLACK => out.push(format!("{path} shrank to {now} {} (limit {limit}): lock that in with `QM_LOWER_LIMITS=1 cargo test --test size_ratchet`.", unit(path))),
            Some(_) => {}
        }
    }
    if size(root, ALWAYS_PINNED).is_some() && !limits.contains_key(ALWAYS_PINNED) {
        out.push(format!("{ALWAYS_PINNED} must be pinned in tests/size_limits.json."));
    }
    for (path, max) in threshold_by_path(root) {
        if limits.contains_key(&path) {
            continue;
        }
        let now = size(root, &path).unwrap_or(0);
        if now > max {
            out.push(format!("{path} has {now} lines, over the {max}-line threshold. {ADVICE}"));
        }
    }
    out
}

/// Lowers each limit to the file's current size, drops deleted files and files back at or under their
/// threshold. Never raises a limit, never pins a new file.
fn lowered(root: &Path, limits: &Map<String, Value>) -> Map<String, Value> {
    let thresholds = threshold_by_path(root);
    let mut out = Map::new();
    for (path, limit) in limits {
        let Some(now) = size(root, path) else { continue };
        if path != ALWAYS_PINNED && thresholds.iter().any(|(p, max)| p == path && now <= *max) {
            continue;
        }
        out.insert(path.clone(), Value::from(now.min(limit.as_u64().unwrap() as usize)));
    }
    out
}

fn load(file: &Path) -> Map<String, Value> {
    serde_json::from_str::<Value>(&fs::read_to_string(file).unwrap()).unwrap().as_object().unwrap().clone()
}

fn write(limits: &Map<String, Value>, file: &Path) {
    let mut sorted: Vec<(&String, &Value)> = limits.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let body: Map<String, Value> = sorted.into_iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    fs::write(file, format!("{}\n", serde_json::to_string_pretty(&Value::Object(body)).unwrap())).unwrap();
}

fn in_tree(lines_by_path: &[(&str, usize)]) -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    for (path, lines) in lines_by_path {
        let full = root.path().join(path);
        fs::create_dir_all(full.parent().unwrap()).unwrap();
        fs::write(full, "x\n".repeat(*lines)).unwrap();
    }
    root
}

fn limits(pairs: &[(&str, u64)]) -> Map<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), Value::from(*v))).collect()
}

#[test]
fn the_tree_keeps_within_its_limits() {
    let current = load(&limits_file());
    if std::env::var_os("QM_LOWER_LIMITS").is_some_and(|v| !v.is_empty()) {
        let after = lowered(&repo(), &current);
        write(&after, &limits_file());
        for path in current.keys().chain(after.keys()) {
            if current.get(path) != after.get(path) {
                eprintln!("{path}: {:?} -> {:?}", current.get(path), after.get(path));
            }
        }
        return;
    }
    let found = problems(&repo(), &current);
    assert!(found.is_empty(), "{}", found.join("\n"));
}

#[test]
fn the_baseline_lists_only_pinned_files() {
    let pinned = load(&limits_file());
    assert!(pinned.contains_key(ALWAYS_PINNED));
    let thresholds = threshold_by_path(&repo());
    for (path, limit) in &pinned {
        if path == ALWAYS_PINNED {
            continue;
        }
        let max = thresholds.iter().find(|(p, _)| p == path).unwrap_or_else(|| panic!("{path} is outside the ratchet's scope")).1;
        assert!(limit.as_u64().unwrap() as usize > max, "{path} is pinned at or under its threshold");
    }
}

#[test]
fn a_pinned_file_growing_past_its_limit_fails_and_within_it_passes() {
    let root = in_tree(&[("src/big.rs", 500), ("CLAUDE.md", 100)]);
    let found = problems(root.path(), &limits(&[("src/big.rs", 499), ("CLAUDE.md", 200)]));
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("big.rs grew to 500 lines, past its limit of 499. Split the file") && found[0].contains("raise its limit in tests/size_limits.json"));
    assert!(problems(root.path(), &limits(&[("src/big.rs", 520), ("CLAUDE.md", 200)])).is_empty());
}

#[test]
fn claude_md_is_measured_in_bytes_and_must_be_pinned() {
    let root = in_tree(&[("CLAUDE.md", 100)]);
    assert!(problems(root.path(), &limits(&[("CLAUDE.md", 99)]))[0].contains("CLAUDE.md grew to 200 bytes"));
    assert_eq!(problems(root.path(), &limits(&[])), vec!["CLAUDE.md must be pinned in tests/size_limits.json.".to_string()]);
}

#[test]
fn an_unpinned_file_crossing_its_threshold_fails() {
    let root = in_tree(&[("src/a.rs", 401), ("src/b.rs", 400), ("gui/js/c.js", 401), ("tests/d.rs", 800), ("tests/e.rs", 801), ("elsewhere/f.rs", 9000), ("CLAUDE.md", 10)]);
    let found = problems(root.path(), &limits(&[("CLAUDE.md", 9000)]));
    let mut flagged: Vec<&str> = found.iter().map(|p| p.split(' ').next().unwrap()).filter(|p| *p != "CLAUDE.md").collect();
    flagged.sort();
    assert_eq!(flagged, vec!["gui/js/c.js", "src/a.rs", "tests/e.rs"]);
    assert!(found.join("\n").contains("over the 800-line threshold"));
}

#[test]
fn a_pinned_file_shrinking_ten_percent_or_going_away_asks_for_lowering() {
    let root = in_tree(&[("src/big.rs", 450), ("src/near.rs", 451), ("CLAUDE.md", 45)]);
    let found = problems(root.path(), &limits(&[("src/big.rs", 500), ("src/near.rs", 500), ("CLAUDE.md", 100)]));
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found[0].contains("big.rs shrank to 450 lines (limit 500)") && found[0].contains("QM_LOWER_LIMITS"));
    assert!(found[1].contains("CLAUDE.md shrank"));
    let gone = in_tree(&[("CLAUDE.md", 10)]);
    let found = problems(gone.path(), &limits(&[("src/gone.rs", 500), ("CLAUDE.md", 20)]));
    assert_eq!(found.len(), 1);
    assert!(found[0].starts_with("src/gone.rs is pinned but gone"));
}

#[test]
fn lowering_lowers_and_drops_but_never_raises() {
    let root = in_tree(&[("src/shrunk.rs", 450), ("src/grew.rs", 600), ("src/small.rs", 380), ("src/fresh.rs", 900), ("CLAUDE.md", 25)]);
    let now = lowered(root.path(), &limits(&[("src/shrunk.rs", 500), ("src/grew.rs", 550), ("src/small.rs", 500), ("src/gone.rs", 500), ("CLAUDE.md", 60)]));
    let claude = fs::metadata(root.path().join("CLAUDE.md")).unwrap().len();
    assert_eq!(now, limits(&[("src/shrunk.rs", 450), ("src/grew.rs", 550), ("CLAUDE.md", claude)]));
    let tiny = in_tree(&[("CLAUDE.md", 1)]);
    assert_eq!(lowered(tiny.path(), &limits(&[("CLAUDE.md", 9000)])).keys().collect::<Vec<_>>(), vec!["CLAUDE.md"]);
}

#[test]
fn writing_round_trips_sorted() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("limits.json");
    write(&limits(&[("b", 2), ("CLAUDE.md", 3), ("a", 1)]), &file);
    assert_eq!(load(&file).keys().cloned().collect::<Vec<_>>(), vec!["CLAUDE.md", "a", "b"]);
}
