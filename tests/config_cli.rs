//! `qm config` through the real executable, on a QM_ROOT config.yml (the port of upstream's
//! config_cli_test.rb).

mod common;
use common::*;
use serde_yaml::Value;
use std::fs;

struct World {
    qm: Qm,
    repo: tempfile::TempDir,
}

fn world() -> World {
    let qm = Qm::new();
    let repo = tempfile::tempdir().unwrap();
    let w = World { qm, repo };
    w.write(&format!("projects:\n  App:\n    root: {}\n    dev_server: sh\n", w.repo.path().display()));
    w
}

impl World {
    fn file(&self) -> std::path::PathBuf {
        self.qm.root.path().join("config.yml")
    }
    fn write(&self, text: &str) {
        fs::write(self.file(), text).unwrap();
    }
    fn read(&self) -> String {
        fs::read_to_string(self.file()).unwrap()
    }
    fn data(&self) -> Value {
        serde_yaml::from_str(&self.read()).unwrap()
    }
    fn config(&self, args: &[&str]) -> Out {
        let mut argv = vec!["config"];
        argv.extend(args);
        self.qm.run(&argv)
    }
    fn bak(&self) -> std::path::PathBuf {
        self.qm.root.path().join("config.yml.bak")
    }
}

#[test]
fn path_prints_the_file_location() {
    let w = world();
    let o = w.config(&["path"]);
    assert_eq!((o.code, o.stdout), (0, format!("{}\n", w.file().display())));
}

#[test]
fn set_writes_a_list_a_bool_and_a_number() {
    let w = world();
    let o = w.config(&["set", "projects.App.dev_server.modes", "[dev, ngrok]"]);
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert_eq!(w.data()["projects"]["App"]["dev_server"]["modes"], serde_yaml::from_str::<Value>("[dev, ngrok]").unwrap());
    assert_eq!(w.config(&["set", "projects.App.pr_prerequisites", "true"]).code, 0);
    assert_eq!(w.data()["projects"]["App"]["pr_prerequisites"], Value::Bool(true));
    assert_eq!(w.config(&["set", "prices.claude-opus-5-5.input", "4"]).code, 0);
    assert_eq!(w.data()["prices"]["claude-opus-5-5"]["input"], serde_yaml::from_str::<Value>("4").unwrap());
}

#[test]
fn set_echoes_what_it_wrote() {
    let w = world();
    let o = w.config(&["set", "projects.App.dev_server.modes", "[dev, ngrok]"]);
    assert_eq!((o.code, o.stdout.as_str()), (0, "projects.App.dev_server.modes: [dev, ngrok]\n"));
}

#[test]
fn set_of_an_unknown_path_fails_and_writes_nothing() {
    let w = world();
    let before = w.read();
    let o = w.config(&["set", "projects.App.typo", "x"]);
    assert_eq!((o.code, o.stdout.as_str()), (1, ""));
    assert!(o.stderr.contains("unknown config key: projects.App.typo"), "{}", o.stderr);
    assert_eq!(w.read(), before);
}

#[test]
fn set_of_a_wrong_type_fails_on_stderr_and_writes_nothing() {
    let w = world();
    let before = w.read();
    let o = w.config(&["set", "projects.App.pr_prerequisites", "maybe"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("error: projects.App.pr_prerequisites: must be true or false"), "{}", o.stderr);
    assert_eq!(w.read(), before);
    assert!(!w.bak().exists());
}

#[test]
fn set_with_a_warning_writes_and_warns_on_stderr() {
    let w = world();
    let o = w.config(&["set", "projects.App.test_db", "no-such-test-db-cmd-xyz"]);
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert!(o.stderr.contains("warning: projects.App.test_db: no-such-test-db-cmd-xyz is not on PATH"), "{}", o.stderr);
    assert_eq!(o.stdout, "projects.App.test_db: no-such-test-db-cmd-xyz\n");
    assert_eq!(w.data()["projects"]["App"]["test_db"], Value::String("no-such-test-db-cmd-xyz".into()));
    assert!(w.bak().exists());
}

#[test]
fn set_without_a_value_prints_usage() {
    let o = world().config(&["set", "projects.App.test_db"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("usage: qm config"), "{}", o.stderr);
}

#[test]
fn get_prints_a_scalar_bare_and_a_subtree_as_yaml() {
    let w = world();
    w.config(&["set", "projects.App.dev_server.modes", "[dev, ngrok]"]);
    let o = w.config(&["get", "projects.App.root"]);
    assert_eq!((o.code, o.stdout), (0, format!("{}\n", w.repo.path().display())));
    let o = w.config(&["get", "projects.App.dev_server"]);
    assert_eq!(serde_yaml::from_str::<Value>(&o.stdout).unwrap(), serde_yaml::from_str::<Value>("{command: sh, modes: [dev, ngrok]}").unwrap());
}

#[test]
fn get_without_a_path_prints_the_whole_file() {
    let w = world();
    let o = w.config(&["get"]);
    assert_eq!((o.code, o.stdout), (0, w.read()));
}

#[test]
fn get_of_an_unset_key_prints_nothing_and_exits_1() {
    let o = world().config(&["get", "projects.App.test_db"]);
    assert_eq!((o.code, o.stdout.as_str(), o.stderr.as_str()), (1, "", ""));
}

#[test]
fn get_of_an_unknown_path_fails() {
    let o = world().config(&["get", "nope"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("unknown config key: nope"), "{}", o.stderr);
}

#[test]
fn unset_removes_the_key() {
    let w = world();
    w.config(&["set", "projects.App.test_db", "x"]);
    let o = w.config(&["unset", "projects.App.test_db"]);
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert!(w.data()["projects"]["App"].get("test_db").is_none());
}

#[test]
fn unset_of_an_unknown_path_fails_even_when_absent() {
    let o = world().config(&["unset", "foo.bar.baz"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("unknown config key: foo.bar.baz"), "{}", o.stderr);
}

#[test]
fn unset_of_an_absent_known_key_says_so() {
    let w = world();
    let before = w.read();
    let o = w.config(&["unset", "projects.App.test_db"]);
    assert_eq!((o.code, o.stdout.as_str()), (0, "projects.App.test_db is not set\n"));
    assert_eq!(w.read(), before);
}

#[test]
fn unset_of_a_project_warns_with_its_work_item_count() {
    let w = world();
    for (title, project) in [("One", "App"), ("Two", "App"), ("Elsewhere", "Other")] {
        w.qm.ok(&["new", title, "--project", project]);
    }
    let o = w.config(&["unset", "projects.App"]);
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert!(o.stderr.contains("warning: 2 work items still have project App"), "{}", o.stderr);
    assert_eq!(w.data()["projects"], serde_yaml::from_str::<Value>("{}").unwrap());
}

#[test]
fn unset_refused_by_an_error_writes_nothing() {
    let w = world();
    w.write(&format!("projects:\n  App:\n    root: {}\ndefault_project: App\n", w.repo.path().display()));
    let before = w.read();
    let o = w.config(&["unset", "projects.App"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("error: default_project: default_project must name a project"), "{}", o.stderr);
    assert_eq!(w.read(), before);
}

#[test]
fn an_unparsable_file_refuses_a_set() {
    let w = world();
    w.write("projects: [unclosed\n");
    let o = w.config(&["set", "default_project", "App"]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("not valid YAML"), "{}", o.stderr);
    assert_eq!(w.read(), "projects: [unclosed\n");
}

#[test]
fn no_subcommand_prints_usage() {
    let o = world().config(&[]);
    assert_eq!(o.code, 1);
    assert!(o.stderr.contains("usage: qm config"), "{}", o.stderr);
}

#[test]
fn help_lists_qm_config() {
    let o = world().qm.run(&["help"]);
    assert!(o.stdout.contains("qm config get [PATH]") && o.stdout.contains("qm config set PATH VALUE"), "{}", o.stdout);
}
