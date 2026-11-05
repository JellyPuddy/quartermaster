use std::path::Path;
use std::process::{Command, Stdio};

/// Output of `git -C cwd args`, stripped; None when cwd is no directory or git fails.
pub fn git(cwd: Option<&str>, args: &[&str]) -> Option<String> {
    let cwd = cwd?;
    if !Path::new(cwd).is_dir() {
        return None;
    }
    let out = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}
