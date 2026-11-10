//! ConfigFile, ConfigCheck, ConfigSchema and the emitter on throwaway files (the port of upstream's
//! config_file_test.rb).

use quartermaster::config_check::Probe;
use quartermaster::config_features::features;
use quartermaster::config_file::{digest_of, emit, parse_value, ConfigFile, WriteError, HEADER};
use quartermaster::config_schema as schema;
use serde_yaml::Value;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

/// Answers the warnings' folder and PATH checks from fixed lists.
struct Stub {
    dirs: Vec<&'static str>,
    commands: Vec<&'static str>,
}

impl Probe for Stub {
    fn dir(&self, path: &str) -> bool {
        self.dirs.contains(&path)
    }
    fn command(&self, name: &str) -> bool {
        self.commands.contains(&name)
    }
}

fn all_there() -> Box<Stub> {
    Box::new(Stub { dirs: vec!["/code/app", "/code/plain", "/skills/bench", "/run"], commands: vec!["pf", "app-test-db"] })
}

struct Fixture {
    _dir: tempfile::TempDir,
    file: PathBuf,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("config.yml");
    Fixture { _dir: dir, file }
}

impl Fixture {
    fn load(&self, text: &str) -> ConfigFile {
        fs::write(&self.file, text).unwrap();
        ConfigFile::load_with(&self.file, all_there())
    }
    fn load_with(&self, text: &str, probe: Stub) -> ConfigFile {
        fs::write(&self.file, text).unwrap();
        ConfigFile::load_with(&self.file, Box::new(probe))
    }
    fn read(&self) -> String {
        fs::read_to_string(&self.file).unwrap()
    }
    fn bak(&self) -> PathBuf {
        self.file.with_file_name("config.yml.bak")
    }
    fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(self.file.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).filter(|n| n != ".config.yml.lock").collect();
        names.sort();
        names
    }
}

fn yaml(s: &str) -> Value {
    serde_yaml::from_str(s).unwrap()
}

fn issues_of(text: &str) -> Vec<(String, String, String)> {
    fixture().load(text).issues().into_iter().map(|i| (i.level.to_string(), i.path, i.message)).collect()
}

const FULL: &str = r#"# my own comment
my_notes:
  keep: [1, 2]
prices:
  claude-opus-5-5: { output: 30, input: 5 }
overview_artifact: https://claude.ai/artifact/abc
projects:
  Plain: /code/plain
  App:
    test_db: app-test-db
    root: /code/app
    dev_server:
      modes: [dev, tunnel]
      command: pf
      default_mode: tunnel
      state_file: /run/current
    review_skill: /review-app
    pr_prerequisites: true
    benchmark: { database: app_bench, skill: /skills/bench, notes: "Line one.\nLine two.\n" }
    ide_command: [code, PATH]
loose_starters:
  backlog:
    label: Sprint backlog
    prompt: Load the open issues. Then give a one-line count of them and
ide_label: MyIDE
ide_command: [zsh, -ic, "myide PATH"]
default_project: App
"#;

#[test]
fn writing_lays_the_file_out_in_qms_order_with_the_header() {
    let f = fixture();
    let mut config = f.load(FULL);
    assert!(config.issues().is_empty());
    config.write(None).ok().unwrap();
    assert_eq!(
        f.read(),
        "# Edited by qm (Settings view / qm config); key reference: docs/overview.md
projects:
  Plain: /code/plain
  App:
    root: /code/app
    dev_server:
      command: pf
      modes: [dev, tunnel]
      default_mode: tunnel
      state_file: /run/current
    test_db: app-test-db
    review_skill: /review-app
    pr_prerequisites: true
    benchmark:
      database: app_bench
      skill: /skills/bench
      notes: |
        Line one.
        Line two.
    ide_command: [code, PATH]
default_project: App
ide_command: [zsh, -ic, myide PATH]
ide_label: MyIDE
loose_starters:
  backlog:
    label: Sprint backlog
    prompt: Load the open issues. Then give a one-line count of them and
overview_artifact: https://claude.ai/artifact/abc
prices:
  claude-opus-5-5:
    input: 5
    output: 30
my_notes:
  keep: [1, 2]
"
    );
}

#[test]
fn a_round_trip_keeps_every_value_and_writes_the_same_text_again() {
    let f = fixture();
    let mut config = f.load(FULL);
    config.write(None).ok().unwrap();
    let written = f.read();
    assert_eq!(yaml(FULL), yaml(&written));
    let mut again = ConfigFile::load_with(&f.file, all_there());
    again.write(None).ok().unwrap();
    assert_eq!(written, f.read());
}

#[test]
fn unknown_top_level_keys_are_kept_but_unknown_keys_under_schema_mappings_are_errors() {
    let f = fixture();
    let mut config = f.load("projects:\n  App: { root: /code/app, typo: 1, dev_server: { command: pf, colour: red } }\nloose_starters: { a: { prompt: Go, emoji: x } }\nprices: { claude-x: { input: 1, discount: 2 } }\nsomeday: { anything: [goes] }\n");
    let found: Vec<(String, String)> = config.issues().into_iter().map(|i| (i.level.to_string(), i.path)).collect();
    let want = ["projects.App.typo", "projects.App.dev_server.colour", "loose_starters.a.emoji", "prices.claude-x.discount"];
    assert_eq!(found, want.iter().map(|p| ("error".to_string(), p.to_string())).collect::<Vec<_>>());
    for path in ["projects.App.typo", "projects.App.dev_server", "loose_starters.a.emoji", "prices.claude-x.discount"] {
        config.unset(path).unwrap();
    }
    config.write(None).ok().unwrap();
    assert_eq!(yaml(&f.read())["someday"], yaml("{ anything: [goes] }"));
}

#[test]
fn every_error() {
    let cases: [(&str, &str, &str); 19] = [
        ("projects: [::", "", "not valid YAML"),
        ("- a list", "", "not a mapping"),
        ("projects: { App: { root: 5 } }", "projects.App.root", "must be a path"),
        ("projects: { App: { dev_server: pf } }", "projects.App.root", "needs a root"),
        ("projects: { App: [a] }", "projects.App", "must be a mapping or a root"),
        ("projects: { App: { root: /code/app, pr_prerequisites: 'yes' } }", "projects.App.pr_prerequisites", "true or false"),
        ("projects: { App: { root: /code/app, dev_server: { command: pf, modes: { a: 1 } } } }", "projects.App.dev_server.modes", "list of names"),
        ("projects: { App: { root: /code/app, dev_server: { modes: [dev] } } }", "projects.App.dev_server.command", "needs a command"),
        ("projects: { App: { root: /code/app, dev_server: { command: pf, modes: [dev], default_mode: prod } } }", "projects.App.dev_server.default_mode", "one of the modes: dev"),
        ("projects: { App: { root: /code/app, benchmark: { database: app_bench } } }", "projects.App.benchmark", "both database and skill"),
        ("projects: { App: { root: /code/app, benchmark: { database: app-bench, skill: /skills/bench } } }", "projects.App.benchmark.database", "letters, digits and _"),
        ("projects: { App: { root: /code/app, ide_command: [code, .] } }", "projects.App.ide_command", "needs a PATH"),
        ("projects: {}\nide_command: code PATH", "ide_command", "command list"),
        ("projects: {}\nide_command: ['', PATH]", "ide_command", "start with a program"),
        ("projects: { App: /code/app }\ndefault_project: Web", "default_project", "must name a project (App)"),
        ("projects: {}\nloose_starters: { a: { label: A } }", "loose_starters.a.prompt", "needs a prompt"),
        ("projects: {}\nprices: { claude-x: { input: cheap } }", "prices.claude-x.input", "must be a number"),
        ("projects: {}\noverview_artifact: [a]", "overview_artifact", "must be text"),
        ("projects: {}\nautomations: { token_source: api_key }", "automations.token_source", "one of: claude_code"),
    ];
    for (text, path, message) in cases {
        let found = issues_of(text);
        assert_eq!(found.iter().map(|i| (i.0.as_str(), i.1.as_str())).collect::<Vec<_>>(), vec![("error", path)], "{text}");
        assert!(found[0].2.contains(message), "{text}: {}", found[0].2);
    }
}

#[test]
fn every_warning_and_warnings_never_block_a_write() {
    let f = fixture();
    let mut config = f.load_with(
        "projects:\n  App:\n    root: /code/app\n    dev_server: { command: pf --quiet, state_file: /run/current }\n    test_db: app-test-db\n    benchmark: { database: app_bench, skill: /skills/bench }\n    ide_label: Code\nide_label: MyIDE\n",
        Stub { dirs: vec![], commands: vec![] },
    );
    let found: Vec<(String, String, String)> = config.issues().into_iter().map(|i| (i.level.to_string(), i.path, i.message)).collect();
    let want = [
        ("projects.App.root", "folder /code/app doesn't exist"),
        ("projects.App.dev_server.command", "pf is not on PATH"),
        ("projects.App.dev_server.state_file", "folder /run doesn't exist"),
        ("projects.App.test_db", "app-test-db is not on PATH"),
        ("projects.App.benchmark.skill", "folder /skills/bench doesn't exist"),
        ("projects.App.ide_label", "ide_label does nothing without ide_command"),
        ("ide_label", "ide_label does nothing without ide_command"),
    ];
    assert_eq!(found, want.iter().map(|(p, m)| ("warning".to_string(), p.to_string(), m.to_string())).collect::<Vec<_>>());
    config.write(None).ok().unwrap();
    assert_eq!(yaml(&f.read())["projects"]["App"]["ide_label"], Value::String("Code".into()));
}

#[test]
fn errors_refuse_the_write_and_leave_the_file_alone() {
    let f = fixture();
    let mut config = f.load("projects: { App: { dev_server: pf } }\n");
    let Err(WriteError::Invalid(issues)) = config.write(None) else { panic!("expected Invalid") };
    assert_eq!(issues.iter().map(|i| i.path.as_str()).collect::<Vec<_>>(), vec!["projects.App.root"]);
    assert_eq!(f.read(), "projects: { App: { dev_server: pf } }\n");
    assert!(!f.bak().exists());
}

#[test]
fn a_file_changed_since_loading_is_refused_as_stale() {
    let f = fixture();
    let mut config = f.load("projects: {}\n");
    fs::write(&f.file, "projects: { Other: /code/plain }\n").unwrap();
    config.set("projects.App", Value::String("/code/app".into())).unwrap();
    assert!(matches!(config.write(None), Err(WriteError::Stale)));
    assert_eq!(f.read(), "projects: { Other: /code/plain }\n");

    let mut fresh = ConfigFile::load_with(&f.file, all_there());
    assert!(matches!(fresh.write(Some(&config.digest)), Err(WriteError::Stale)));
    assert!(fresh.write(Some(&digest_of("projects: { Other: /code/plain }\n"))).is_ok());
}

#[test]
fn a_write_keeps_the_previous_file_as_bak_and_replaces_by_rename() {
    use std::os::unix::fs::MetadataExt;
    let f = fixture();
    let mut config = f.load("# hand-written\nprojects: { App: /code/app }\n");
    let before = fs::metadata(&f.file).unwrap().ino();
    config.set("projects.App.test_db", Value::String("app-test-db".into())).unwrap();
    let new_digest = config.write(None).ok().unwrap();

    assert_eq!(fs::read_to_string(f.bak()).unwrap(), "# hand-written\nprojects: { App: /code/app }\n");
    assert_ne!(fs::metadata(&f.file).unwrap().ino(), before);
    assert_eq!(f.names(), vec!["config.yml", "config.yml.bak"]);
    assert_eq!(digest_of(&f.read()), new_digest);
    assert_eq!(config.digest, new_digest);
}

#[test]
fn a_write_keeps_the_file_mode_and_leaves_no_temp_file() {
    let f = fixture();
    let mut config = f.load("projects: { App: /code/app }\n");
    fs::set_permissions(&f.file, fs::Permissions::from_mode(0o600)).unwrap();
    config.set("projects.App.test_db", Value::String("app-test-db".into())).unwrap();
    config.write(None).ok().unwrap();
    assert_eq!(fs::metadata(&f.file).unwrap().permissions().mode() & 0o7777, 0o600);
    assert_eq!(f.names(), vec!["config.yml", "config.yml.bak"]);
}

#[test]
fn a_missing_file_is_written_fresh() {
    let f = fixture();
    let mut config = ConfigFile::load_with(&f.file, all_there());
    config.set("projects.App.root", Value::String("/code/app".into())).unwrap();
    config.write(None).ok().unwrap();
    assert_eq!(f.read(), format!("{HEADER}\nprojects:\n  App: /code/app\n"));
    assert!(!f.bak().exists());
}

#[test]
fn set_and_get_open_shorthands_and_unset_removes() {
    let f = fixture();
    let mut config = f.load("projects: { App: /code/app }\n");
    assert_eq!(config.get("projects.App.root"), Some(Value::String("/code/app".into())));

    config.set("projects.App.dev_server", Value::String("pf".into())).unwrap();
    assert_eq!(config.get("projects.App.dev_server.command"), Some(Value::String("pf".into())));
    config.set("projects.App.dev_server.modes", parse_value("[dev, ngrok]")).unwrap();
    assert_eq!(config.get("projects.App"), Some(yaml("{ root: /code/app, dev_server: { command: pf, modes: [dev, ngrok] } }")));

    config.unset("projects.App.dev_server").unwrap();
    config.unset("projects.Nope.test_db").unwrap();
    assert_eq!(config.get("projects.App"), Some(yaml("{ root: /code/app }")));
    assert_eq!(config.get("projects.Nope.root"), None);
}

#[test]
fn set_refuses_paths_the_schema_does_not_list() {
    let f = fixture();
    let mut config = f.load("projects: {}\n");
    for path in ["projects.App.typo", "colour", "prices.claude-x.discount", "projects.App.dev_server.command.x"] {
        assert!(config.set(path, Value::String("x".into())).is_err(), "{path}");
    }
}

#[test]
fn values_parse_as_yaml() {
    let parsed: Vec<Value> = ["[dev, ngrok]", "true", "4", "0.25", "~/code/app", "pf", "null", "[unclosed", "!tag x"].iter().map(|s| parse_value(s)).collect();
    let s = |t: &str| Value::String(t.into());
    assert_eq!(parsed, vec![yaml("[dev, ngrok]"), Value::Bool(true), yaml("4"), yaml("0.25"), s("~/code/app"), s("pf"), Value::Null, s("[unclosed"), s("!tag x")]);
}

#[test]
fn the_earlier_seeds_empty_projects_key_reads_as_no_projects() {
    let f = fixture();
    let mut config = f.load("# qm configuration\nprojects:\n#   my-app: ~/code/my-app\n");
    assert!(config.issues().is_empty());
    config.set("ide_command", yaml("[code, PATH]")).unwrap();
    config.write(None).ok().unwrap();
    assert_eq!(f.read(), format!("{HEADER}\nprojects: {{}}\nide_command: [code, PATH]\n"));
}

#[test]
fn unset_values_and_emptied_mappings_are_dropped_on_write() {
    let f = fixture();
    let mut config = f.load("projects: { App: /code/app }\n");
    config.replace(yaml("projects: { App: { root: /code/app, test_db: '', review_skill: ~, benchmark: { notes: ' ' } } }\nide_label: ''\nloose_starters: {}\n"));
    config.write(None).ok().unwrap();
    assert_eq!(f.read(), format!("{HEADER}\nprojects:\n  App: /code/app\n"));
}

#[test]
fn the_seed_is_what_qm_writes_for_no_projects() {
    let seed = include_str!("../src/config_seed.yml");
    assert_eq!(seed, "# Edited by qm (Settings view / qm config); key reference: docs/overview.md\nprojects: {}\n");
    assert_eq!(seed, emit(&yaml("projects: {}")));
}

#[test]
fn the_schema_finds_keys_and_containers_by_concrete_path() {
    let mode = schema::lookup("projects.App.dev_server.default_mode").unwrap();
    let price = schema::lookup("prices.claude-x.output").unwrap();
    assert_eq!((mode.kind, mode.options_from), ("enum", Some("projects.*.dev_server.modes")));
    assert_eq!((price.kind, price.section), ("number", "prices"));
    assert_eq!(schema::lookup("projects.App.ide_command").unwrap().inherits, Some("ide_command"));
    assert_eq!(schema::lookup("projects.App.review_skill").unwrap().default, Some("/code-review"));
    assert!(schema::lookup("projects.App.dev_server").is_none());
    assert_eq!(schema::container_of("projects.App.dev_server").unwrap().pattern, "projects.*.dev_server");
    assert!(schema::lookup("projects..root").is_none());
    assert!(!schema::known("projects.App.typo"));
    assert_eq!(schema::TYPES, ["string", "path", "text", "bool", "number", "string_list", "argv", "enum"]);
    let mut paths: Vec<&str> = schema::KEYS.iter().map(|k| k.path).collect();
    paths.sort();
    paths.dedup();
    assert_eq!(paths.len(), schema::KEYS.len());
    assert!(schema::KEYS.iter().all(|k| schema::TYPES.contains(&k.kind)));
}

#[test]
fn price_keys_follow_the_usage_kinds() {
    let fields: Vec<&str> = schema::KEYS.iter().filter_map(|k| k.path.strip_prefix("prices.*.")).collect();
    assert_eq!(fields, quartermaster::transcript_usage::KINDS);
}

#[test]
fn features_say_on_off_inherit_and_mark_issues() {
    let data = yaml("projects:\n  App:\n    root: /code/app\n    dev_server: { command: pf, modes: [dev, ngrok, tunnel, prod] }\n    test_db: app-test-db\n    pr_prerequisites: true\n    benchmark: { database: app_bench, skill: /skills/bench }\n    ide_command: [code, PATH]\n  Plain: /code/plain\nide_command: [zsh, -ic, \"myide PATH\"]\nide_label: MyIDE\n");
    let issue = |level, path: &str| quartermaster::config_check::Issue { level, path: path.into(), message: "x".into() };
    let issues = vec![issue("warning", "projects.App.test_db"), issue("error", "projects.Plain.benchmark")];
    let grid = features(&data, &issues);
    let cell = |project: &str, feature: &str| (grid[project][feature]["state"].as_str().unwrap().to_string(), grid[project][feature]["value"].as_str().map(String::from));
    assert_eq!(cell("App", "dev_server"), ("on".into(), Some("pf · 4 modes".into())));
    assert_eq!(cell("App", "test_db"), ("warning".into(), Some("app-test-db".into())));
    assert_eq!(cell("App", "review"), ("inherit".into(), Some("default".into())));
    assert_eq!(cell("App", "ships_by_release"), ("on".into(), Some("yes".into())));
    assert_eq!(cell("App", "benchmarks"), ("on".into(), Some("app_bench".into())));
    assert_eq!(cell("App", "ide"), ("on".into(), Some("IDE".into())));
    assert_eq!(cell("Plain", "dev_server"), ("off".into(), None));
    assert_eq!(cell("Plain", "benchmarks"), ("error".into(), None));
    assert_eq!(cell("Plain", "ide"), ("inherit".into(), Some("global".into())));
    assert_eq!(features(&data, &[])["Plain"]["ide"]["title"], "MyIDE: zsh -ic myide PATH");
}

/// docs/overview.md §config.yml names every schema key as a dotted path (`{a, b}` expands, `<name>` is a
/// map key).
#[test]
fn overview_names_every_config_key_path() {
    fn expand(span: &str) -> Vec<String> {
        let Some(open) = span.find('{') else { return vec![span.to_string()] };
        let Some(close) = span[open..].find('}').map(|c| c + open) else { return vec![span.to_string()] };
        span[open + 1..close].split(',').flat_map(|alt| expand(&format!("{}{}{}", &span[..open], alt.trim(), &span[close + 1..]))).collect()
    }
    let overview = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/docs/overview.md")).unwrap();
    let section = overview.split("\n## config.yml\n").nth(1).unwrap().split("\n## ").next().unwrap();
    let placeholder = regex::Regex::new(r"<\w+>").unwrap();
    let documented: Vec<String> = regex::Regex::new(r"`([^`]+)`").unwrap().captures_iter(section).flat_map(|c| expand(&placeholder.replace_all(&c[1], "*"))).collect();
    let missing: Vec<&str> = schema::KEYS.iter().map(|k| k.path).filter(|p| !documented.iter().any(|d| d == p)).collect();
    assert!(missing.is_empty(), "docs/overview.md §config.yml must name these keys: {missing:?}");
}
