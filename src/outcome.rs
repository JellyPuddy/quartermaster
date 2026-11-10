use std::ffi::OsStr;

/// How a command ended.
pub enum Outcome {
    /// Finished: the exit code and what to print.
    Done { code: i32, stdout: String, stderr: String },
    /// A form the command does not take: an argument spelling an option parser would accept that this one
    /// does not (an abbreviation, a short switch, an odd number), or data in a shape it does not handle.
    /// Nothing was written; `refuse` says so.
    Refused,
}

pub fn done(stdout: String) -> Outcome {
    Outcome::Done { code: 0, stdout, stderr: String::new() }
}

/// Ruby's `abort(message)`: the message on stderr, exit 1.
pub fn abort(message: &str) -> Outcome {
    Outcome::Done { code: 1, stdout: String::new(), stderr: format!("{message}\n") }
}

/// Ends a command qm does not take as given, naming what was typed.
pub fn refuse<S: AsRef<OsStr>>(args: &[S]) -> ! {
    let shown: Vec<String> = args.iter().map(|a| a.as_ref().to_string_lossy().into_owned()).collect();
    eprintln!("qm: can't do this as given: qm {}", shown.join(" "));
    eprintln!("qm help lists the forms each command takes; odd data in a file it reads can also cause this");
    std::process::exit(1);
}
