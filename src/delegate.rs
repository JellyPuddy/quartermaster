use std::path::PathBuf;

/// The checkout this binary lives in: `<checkout>/target/<profile>/qm` resolved at run time, so a moved
/// checkout, or a binary built elsewhere and named by `QM_BIN`, answers for its own files. Without that
/// layout (a test binary, an installed copy) the checkout it was built from.
pub fn checkout() -> PathBuf {
    let beside = std::env::current_exe().ok().and_then(|exe| std::fs::canonicalize(exe).ok()).and_then(|exe| Some(exe.parent()?.parent()?.parent()?.to_path_buf()));
    match beside {
        Some(dir) if dir.join("quartermaster").is_file() && dir.join("gui").is_dir() => dir,
        _ => PathBuf::from(env!("CARGO_MANIFEST_DIR")),
    }
}

/// The launcher of the checkout: the script the symlinks and hook registrations point at.
pub fn checkout_launcher() -> PathBuf {
    checkout().join("quartermaster")
}
