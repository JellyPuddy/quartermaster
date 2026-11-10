//! A local automation's `when:` guard: a shell command whose stdout lines are the items to run for.

use quartermaster::automation_guard::{parse, run};
use serde_json::{json, Value};

fn dir() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

#[test]
fn each_non_empty_line_is_an_item_and_a_json_line_with_a_key_is_taken_as_it_is() {
    let (items, problems) = parse("{\"key\":\"pr-1\",\"url\":\"https://x/1\"}\nplain line\n\n  padded  \n{\"url\":\"no key\"}\n{\"key\":\" \"}\n{not json\n[1]\n");
    assert_eq!(
        items,
        [
            json!({"key": "pr-1", "url": "https://x/1"}),
            json!({"key": "plain line", "line": "plain line"}),
            json!({"key": "padded", "line": "padded"}),
            json!({"key": "{not json", "line": "{not json"}),
            json!({"key": "[1]", "line": "[1]"}),
        ]
    );
    let errors: Vec<&Value> = problems.iter().map(|p| &p["error"]).collect();
    assert_eq!(errors, ["a guard's JSON item needs a string key", "a guard's JSON item needs a string key"]);
    assert_eq!(problems[0]["item"], "{\"url\":\"no key\"}");
}

#[test]
fn a_guard_runs_in_the_given_directory_and_gives_its_stdout() {
    let d = dir();
    std::fs::write(d.path().join("seen.txt"), "x").unwrap();
    let (items, problems) = run("ls; echo ignored >&2", &d.path().to_string_lossy()).unwrap();
    assert_eq!(items, [json!({"key": "seen.txt", "line": "seen.txt"})]);
    assert!(problems.is_empty());
}

#[test]
fn a_failing_guard_fails_as_a_whole_with_the_stderr_tail() {
    let d = dir();
    let failed = run("echo one >&2; echo two >&2; echo three >&2; echo four >&2; echo out; exit 2", &d.path().to_string_lossy()).unwrap_err();
    assert_eq!(failed.0, "guard failed: two\nthree\nfour");
    assert_eq!(run("exit 1", &d.path().to_string_lossy()).unwrap_err().0, "guard failed: exited non-zero with nothing on stderr");
    let long = run("printf 'x%.0s' $(seq 1 400) >&2; exit 1", &d.path().to_string_lossy()).unwrap_err();
    assert_eq!(long.0.len(), "guard failed: ".len() + 300);
}

#[test]
fn a_missing_working_directory_fails_the_guard() {
    let failed = run("echo a", "/nonexistent/qm-test").unwrap_err();
    assert!(failed.0.contains("doesn't exist"), "{}", failed.0);
}
