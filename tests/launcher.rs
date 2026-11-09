//! The `quartermaster` launcher script: what the `~/bin/qm` symlink and the hooks run. It finds the
//! release binary beside it through any chain of symlinks, passes arguments, stdin and the exit code on,
//! and when there is no binary says so, except for a hook, which must never break a session.

use std::fs;
use std::io::Write;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn launcher() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster")
}

/// A stand-in for the binary: records what it was given.
fn fake(path: &Path, code: i32) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("#!/bin/sh\necho \"args: $*\"\necho \"stdin: $(cat)\"\nexit {code}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn checkout(dir: &Path) -> PathBuf {
    let checkout = dir.join("checkout");
    fs::create_dir_all(&checkout).unwrap();
    fs::copy(launcher(), checkout.join("quartermaster")).unwrap();
    checkout
}

fn run(program: &Path, env: &[(&str, &str)], args: &[&str], stdin: &str) -> Output {
    let mut cmd = Command::new(program);
    cmd.args(args).env_remove("QM_BIN");
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

fn out(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

fn err(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

#[test]
fn it_runs_the_release_binary_beside_it_and_passes_everything_on() {
    let dir = tempfile::tempdir().unwrap();
    let checkout = checkout(dir.path());
    fake(&checkout.join("target/release/qm"), 7);
    let o = run(&checkout.join("quartermaster"), &[], &["note", "slug", "two words"], "payload");
    assert_eq!(out(&o), "args: note slug two words\nstdin: payload\n");
    assert_eq!(o.status.code(), Some(7), "the exit code is the binary's");
}

#[test]
fn it_finds_the_checkout_through_absolute_and_relative_symlinks() {
    let dir = tempfile::tempdir().unwrap();
    let checkout = checkout(dir.path());
    fake(&checkout.join("target/release/qm"), 0);
    let bin = dir.path().join("bin");
    fs::create_dir_all(&bin).unwrap();
    symlink(checkout.join("quartermaster"), bin.join("qm")).unwrap();
    symlink("qm", bin.join("quartermaster")).unwrap(); // a link to a link, relative
    symlink("../checkout/quartermaster", bin.join("rel")).unwrap();
    for name in ["qm", "quartermaster", "rel"] {
        let o = run(&bin.join(name), &[], &["list"], "");
        assert_eq!(out(&o), "args: list\nstdin: \n", "{name}");
    }
}

#[test]
fn qm_bin_names_another_binary() {
    let dir = tempfile::tempdir().unwrap();
    let checkout = checkout(dir.path());
    fake(&checkout.join("target/release/qm"), 0);
    let other = dir.path().join("other-qm");
    fake(&other, 3);
    let o = run(&checkout.join("quartermaster"), &[("QM_BIN", other.to_str().unwrap())], &["x"], "");
    assert_eq!((out(&o), o.status.code()), ("args: x\nstdin: \n".to_string(), Some(3)));
}

#[test]
fn without_a_binary_it_says_so_but_a_hook_stays_silent() {
    let dir = tempfile::tempdir().unwrap();
    let checkout = checkout(dir.path());
    // a debug build is not taken: the release build is what a user installs
    fake(&checkout.join("target/debug/qm"), 0);
    let o = run(&checkout.join("quartermaster"), &[], &["list"], "");
    assert_eq!(o.status.code(), Some(127));
    assert!(err(&o).contains("no built binary") && err(&o).contains("cargo build --release"), "{}", err(&o));
    assert_eq!(out(&o), "");
    for hook in ["hook-session-start", "hook-session-end"] {
        let o = run(&checkout.join("quartermaster"), &[], &[hook], "{}");
        assert_eq!((o.status.code(), out(&o), err(&o)), (Some(0), String::new(), String::new()), "{hook}");
    }
}
