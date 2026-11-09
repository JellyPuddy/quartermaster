use std::path::PathBuf;

/// The checkout this binary was built from.
pub fn checkout() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The launcher of the checkout: the script the symlinks and hook registrations point at.
pub fn checkout_launcher() -> PathBuf {
    checkout().join("quartermaster")
}
