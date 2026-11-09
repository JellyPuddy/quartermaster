//! Code reads config.yml only through `ConfigReader` (`ProjectConfig` asks it; the config_* modules own the
//! editable document). At run time the strict reader fails a test that asks for a key the schema doesn't
//! list; this scan catches the other way around it: code outside that layer opening the file or reading a
//! config key off a raw mapping.

mod common;
use common::Qm;
use quartermaster::config_schema as schema;
use quartermaster::project_config::{LoadFailure, ProjectConfig};
use regex::Regex;
use std::fs;
use std::path::Path;
use std::sync::Mutex;

static ENV: Mutex<()> = Mutex::new(());

/// Files allowed to touch the file and its raw mapping.
const ACCESSOR_LAYER: [&str; 8] = ["config_reader.rs", "config_schema.rs", "config_check.rs", "config_file.rs", "config_features.rs", "config_emit.rs", "config_command.rs", "project_config.rs"];

/// Where `config_file()` may appear outside the layer: its definition and the Settings endpoints.
const FILE_USERS: [&str; 3] = ["data_root.rs", "gui_settings.rs", "gui_local_automations.rs"];

/// Schema key names other data also uses (a JSON payload's `benchmark`, a job's label, transcripts'
/// input/output): a read of one can't be told from a config read by its spelling, so the scan leaves them out.
const SHARED_WORDS: [&str; 14] = ["root", "command", "label", "prompt", "input", "output", "database", "skill", "notes", "modes", "cache_read", "cache_write_5m", "cache_write_1h", "benchmark"];

fn config_words() -> Vec<String> {
    let mut words: Vec<String> = schema::KEYS.iter().map(|k| k.path).chain(schema::CONTAINERS.iter().map(|c| c.pattern)).flat_map(|p| p.split('.')).filter(|w| *w != "*" && !SHARED_WORDS.contains(w)).map(String::from).collect();
    words.sort();
    words.dedup();
    words
}

/// [line number, line] of each raw read of a config key in source text: `m.get("test_db")`, `get(m, "prices")`,
/// `x["ide_label"]`.
fn raw_reads(source: &str) -> Vec<(usize, String)> {
    let words = config_words().join("|");
    let read = Regex::new(&format!(r#"(?:\bget\(\s*[^,()]+,\s*|\.(?:get|get_mut|remove|contains_key)\(\s*|\[\s*)"(?:{words})""#)).unwrap();
    source.lines().enumerate().filter(|(_, l)| read.is_match(l)).map(|(i, l)| (i + 1, l.trim().to_string())).collect()
}

fn src_files() -> Vec<(String, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut out: Vec<(String, String)> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "rs")).map(|p| (p.file_name().unwrap().to_string_lossy().into_owned(), fs::read_to_string(&p).unwrap())).collect();
    out.sort();
    out
}

#[test]
fn the_scan_catches_raw_config_reads() {
    let hits = raw_reads("let a = data.get(\"projects\");\nlet b = get(m, \"prices\");\nlet c = x[\"ide_label\"];\nlet d = tokens.get(\"input\");\nlet e = y.insert(\"test_db\", v);\nlet f = m.remove(\"dev_server\");\n");
    assert_eq!(hits.iter().map(|h| h.0).collect::<Vec<_>>(), vec![1, 2, 3, 6]);
    assert!(config_words().contains(&"dev_server".to_string()) && config_words().contains(&"overview_artifact".to_string()));
}

#[test]
fn no_code_outside_the_accessor_layer_reads_config_keys_off_a_raw_mapping() {
    let hits: Vec<String> = src_files().iter().filter(|(name, _)| !ACCESSOR_LAYER.contains(&name.as_str())).flat_map(|(name, text)| raw_reads(text).into_iter().map(move |(n, l)| format!("src/{name}:{n}: {l}"))).collect();
    assert!(hits.is_empty(), "read config through ProjectConfig / ProjectSettings (ConfigReader), not the raw mapping: {hits:#?}");
}

#[test]
fn only_the_accessor_layer_opens_config_yml() {
    let hits: Vec<String> = src_files().into_iter().filter(|(name, _)| !ACCESSOR_LAYER.contains(&name.as_str()) && !FILE_USERS.contains(&name.as_str())).filter(|(_, text)| text.contains("config_file()") || text.contains("\"config.yml\"")).map(|(n, _)| n).collect();
    assert!(hits.is_empty(), "ask ProjectConfig::current (or ConfigFile to edit) instead of opening config.yml: {hits:?}");
}

#[test]
fn an_unknown_key_reads_nothing_and_is_logged_outside_strict_mode_and_panics_in_it() {
    let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    std::env::set_var("QM_ROOT", qm.root.path());
    std::env::remove_var("QM_CONFIG_STRICT");
    let reader = quartermaster::config_reader::ConfigReader::new(&serde_yaml::from_str("projects: {}\ncolour: red\n").unwrap());
    assert!(reader.get("colour").is_none());
    assert!(!reader.section("colour").is_mapping());
    assert!(fs::read_to_string(qm.root.path().join("qm.log")).unwrap().contains("config key colour is not in the schema"));

    std::env::set_var("QM_CONFIG_STRICT", "1");
    assert!(std::panic::catch_unwind(|| reader.get("colour")).is_err());
    std::env::remove_var("QM_CONFIG_STRICT");
}

#[test]
fn the_overview_url_and_price_overrides_come_from_the_current_config() {
    let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let qm = Qm::new();
    std::env::set_var("QM_ROOT", qm.root.path());
    std::env::set_var("QM_CONFIG_STRICT", "1");
    let file = qm.root.path().join("config.yml");
    fs::write(&file, "overview_artifact: \" https://claude.ai/artifact/abc \"\nprices:\n  claude-opus-5-5: { output: 30 }\n  broken: 7\n").unwrap();
    let config = ProjectConfig::current();
    assert_eq!(config.overview_artifact(), Some("https://claude.ai/artifact/abc"));
    let models: Vec<(&str, usize)> = config.prices().iter().map(|(m, f)| (m.as_str(), f.len())).collect();
    assert_eq!(models, vec![("claude-opus-5-5", 1)]);

    fs::write(&file, "overview_artifact: [::").unwrap();
    let broken = ProjectConfig::current();
    assert!(broken.overview_artifact().is_none() && matches!(broken.failure(), Some(LoadFailure::Syntax(_))));
    fs::write(&file, "- a list").unwrap();
    assert!(matches!(ProjectConfig::current().failure(), Some(LoadFailure::NotMapping)));
}
