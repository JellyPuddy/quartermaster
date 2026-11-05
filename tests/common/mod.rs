#![allow(dead_code)]
//! Helpers shared by the black-box test files.

use regex::Regex;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::TempDir;

pub struct Qm {
    pub root: TempDir,
}

pub struct Out {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

pub fn bin() -> PathBuf {
    match std::env::var("QM_BIN") {
        Ok(p) => PathBuf::from(p),
        Err(_) => Path::new(env!("CARGO_MANIFEST_DIR")).join("quartermaster"),
    }
}

/// Dates, timestamps and pids vary per run; everything else is compared verbatim.
pub fn normalize(s: &str) -> String {
    let ts = Regex::new(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:\d{2})?").unwrap();
    let date = Regex::new(r"\d{4}-\d{2}-\d{2}").unwrap();
    let pid = Regex::new(r#""pid":\d+"#).unwrap();
    let dur = Regex::new(r#""duration_s":\d+"#).unwrap();
    let s = ts.replace_all(s, "TS");
    let s = date.replace_all(&s, "DATE");
    let s = pid.replace_all(&s, r#""pid":PID"#);
    dur.replace_all(&s, r#""duration_s":N"#).into_owned()
}

impl Qm {
    pub fn new() -> Self {
        Qm { root: tempfile::tempdir().unwrap() }
    }

    pub fn run_with(&self, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> Out {
        let mut cmd = Command::new(bin());
        cmd.args(args)
            .env("QM_ROOT", self.root.path())
            .env("LANG", "C.UTF-8")
            .env("LC_ALL", "C.UTF-8")
            .env("QM_TMUX_SOCKET", "qm-test-characterization")
            .env_remove("QM_SKIP")
            .env_remove("QM_ASIDE")
            .env_remove("QM_LOOSE")
            .env_remove("QM_ITEM")
            .current_dir(self.root.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().expect("spawn qm");
        let _ = child.stdin.take().unwrap().write_all(stdin.as_bytes()); // a hook that exits unread closes the pipe
        let o = child.wait_with_output().unwrap();
        Out {
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
            code: o.status.code().unwrap_or(-1),
        }
    }

    pub fn run(&self, args: &[&str]) -> Out {
        self.run_with(args, "", &[])
    }

    pub fn ok(&self, args: &[&str]) -> String {
        let o = self.run(args);
        assert_eq!(o.code, 0, "qm {args:?} failed: {}", o.stderr);
        o.stdout
    }

    pub fn read(&self, rel: &str) -> String {
        normalize(&std::fs::read_to_string(self.root.path().join(rel)).unwrap_or_default())
    }

    pub fn exists(&self, rel: &str) -> bool {
        self.root.path().join(rel).exists()
    }
}

impl Qm {
    /// Output with the data root, git hashes and the per-run temp dirs replaced by stable markers.
    pub fn norm(&self, s: &str) -> String {
        let root = self.root.path().to_string_lossy().into_owned();
        let sha = Regex::new(r"\b[0-9a-f]{7,40}\b").unwrap();
        let s = normalize(&s.replace(&root, "ROOT"));
        sha.replace_all(&s, "SHA").into_owned()
    }
}

/// Compares against `tests/fixtures/golden/<name>`; `QM_UPDATE_GOLDEN=1` rewrites it.
pub fn golden(name: &str, actual: &str) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden").join(name);
    if std::env::var("QM_UPDATE_GOLDEN").is_ok_and(|v| !v.is_empty()) {
        std::fs::write(&path, actual).unwrap();
    }
    let expected = std::fs::read_to_string(&path).unwrap_or_else(|_| panic!("missing golden {name}"));
    assert_eq!(actual, expected, "golden {name} differs");
}

pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t.test"])
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

pub fn repo(dir: &Path, branch: &str) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", branch]);
    std::fs::write(dir.join("a.txt"), "a\n").unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-q", "-m", "first"]);
}

pub fn payload(id: &str, cwd: &Path) -> String {
    format!(r#"{{"session_id":"{id}","cwd":"{}","source":"startup","transcript_path":"/nonexistent/x.jsonl"}}"#, cwd.display())
}

pub fn strip_ansi(s: &str) -> String {
    Regex::new("\x1b\\[[0-9;]*m").unwrap().replace_all(s, "").into_owned()
}

