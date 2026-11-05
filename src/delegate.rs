use std::ffi::OsStr;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

/// The Ruby launcher, which still serves every command this binary has not ported.
pub fn launcher() -> PathBuf {
    match std::env::var_os("QM_RUBY_LAUNCHER") {
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("quartermaster"),
    }
}

/// Replaces this process with the Ruby qm, arguments and stdin untouched.
pub fn exec_ruby<S: AsRef<OsStr>>(args: &[S]) -> ! {
    let err = Command::new(launcher()).args(args).exec();
    eprintln!("qm: cannot run the Ruby launcher {}: {err}", launcher().display());
    std::process::exit(127);
}
