//! The lines of an append-only log. One line that is not UTF-8 (a torn write, a stray byte) loses only
//! itself, never the whole log.

use std::path::Path;

/// The file's lines that are valid UTF-8, in order; none when the file can't be read.
pub fn read(path: &Path) -> Vec<String> {
    let Ok(bytes) = std::fs::read(path) else { return vec![] };
    bytes.split(|b| *b == b'\n').filter_map(|line| std::str::from_utf8(line).ok()).map(String::from).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_that_is_not_utf8_is_skipped_and_its_neighbours_kept() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("log.jsonl");
        std::fs::write(&path, b"{\"a\":1}\n{\"b\":\xff}\n{\"c\":3}\n").unwrap();
        let lines: Vec<String> = read(&path).into_iter().filter(|l| !l.is_empty()).collect();
        assert_eq!(lines, ["{\"a\":1}", "{\"c\":3}"]);
    }
}
