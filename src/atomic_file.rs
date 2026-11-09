//! Replaces a file whole: the content goes to a temp file beside it, which is renamed over the target,
//! so a reader without the writer's lock sees the old file or the new one, never a truncated one. A
//! replaced file keeps its mode.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

pub fn write(path: &Path, content: &str) -> std::io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temp = path.with_file_name(format!(".{name}.{}.{:?}.tmp", std::process::id(), std::thread::current().id()).replace(['(', ')'], ""));
    let mode = fs::metadata(path).ok().map(|m| m.permissions().mode() & 0o7777);
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).open(&temp)?;
        file.write_all(content.as_bytes())?;
        drop(file);
        if let Some(mode) = mode {
            fs::set_permissions(&temp, fs::Permissions::from_mode(mode))?;
        }
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn writes_a_new_file_and_leaves_no_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fresh.txt");
        write(&path, "hello\n").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "hello\n");
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn replaces_an_existing_file_keeping_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("kept.txt");
        fs::write(&path, "old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        write(&path, "new").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "new");
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o640);
    }

    #[test]
    fn a_failed_write_leaves_the_original_and_no_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("target");
        fs::create_dir(&path).unwrap(); // a directory can't be renamed over by a file
        assert!(write(&path, "x").is_err());
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}
