use std::ffi::OsStr;
use std::path::PathBuf;

/// The checkout this binary was built from.
pub fn checkout() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The launcher of the checkout: the script the symlinks and hook registrations point at.
pub fn checkout_launcher() -> PathBuf {
    checkout().join("quartermaster")
}

/// Ends a command qm does not take as given: an argument spelling an option parser would accept that this
/// one does not (an abbreviation, a short switch, an odd number), or data in a shape it does not handle.
pub fn refuse<S: AsRef<OsStr>>(args: &[S]) -> ! {
    let shown: Vec<String> = args.iter().map(|a| a.as_ref().to_string_lossy().into_owned()).collect();
    eprintln!("qm: can't do this as given: qm {}", shown.join(" "));
    eprintln!("qm help lists the forms each command takes; odd data in a file it reads can also cause this");
    std::process::exit(1);
}
