//! Targeted edits of a work item's YAML front matter. Only the touched key's lines change, so
//! every other key (rotations, snoozes, anything a newer qm wrote) survives byte for byte.

use crate::error::{QmError, Res};

/// A scalar as Psych would write it: plain when safe, single-quoted otherwise.
pub fn scalar(s: &str) -> String {
    let plain_chars = s.chars().all(|c| c.is_ascii_alphanumeric() || "_./-".contains(c));
    let starts_ok = s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
    let lower = s.to_ascii_lowercase();
    let reserved = ["true", "false", "yes", "no", "on", "off", "null", "y", "n"].contains(&lower.as_str());
    let numeric = s.parse::<f64>().is_ok() || s.starts_with("0x") || s.starts_with("0o");
    let date = s.len() >= 10 && s.as_bytes()[4] == b'-' && s[..4].bytes().all(|c| c.is_ascii_digit());
    if plain_chars && starts_ok && !reserved && !numeric && !date {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "''"))
    }
}

/// The lines of `key`'s block: (index of the key line, index just past its last line).
pub fn block(lines: &[String], key: &str) -> Option<(usize, usize)> {
    let at = lines.iter().position(|l| l == &format!("{key}:") || l.starts_with(&format!("{key}: ")))?;
    let mut end = at + 1;
    while end < lines.len() && (lines[end].starts_with("- ") || lines[end] == "-" || lines[end].starts_with(' ')) {
        end += 1;
    }
    Some((at, end))
}

/// Adds `entry_lines` as one more item of the block-sequence `key`, creating the key at the end.
pub fn push_item(lines: &mut Vec<String>, key: &str, entry_lines: Vec<String>) -> Res<()> {
    match block(lines, key) {
        None => {
            lines.push(format!("{key}:"));
            lines.extend(entry_lines);
        }
        Some((at, end)) => {
            let key_line = lines[at].clone();
            if key_line == format!("{key}: []") {
                lines[at] = format!("{key}:");
                for (i, l) in entry_lines.into_iter().enumerate() {
                    lines.insert(at + 1 + i, l);
                }
            } else if key_line == format!("{key}:") {
                for (i, l) in entry_lines.into_iter().enumerate() {
                    lines.insert(end + i, l);
                }
            } else {
                return Err(QmError::new("RuntimeError", format!("front matter '{key}' is not a block list; edit it with the Ruby qm")));
            }
        }
    }
    Ok(())
}

/// Splits a block's item lines into items (a `- ` line plus its indented continuation).
pub fn items(lines: &[String], at: usize, end: usize) -> Vec<(usize, usize)> {
    let mut out = vec![];
    let mut i = at + 1;
    while i < end {
        let start = i;
        i += 1;
        while i < end && lines[i].starts_with(' ') {
            i += 1;
        }
        out.push((start, i));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(String::from).collect()
    }

    #[test]
    fn scalars_are_plain_unless_yaml_would_read_them_as_something_else() {
        assert_eq!(scalar("feat/x-1.2"), "feat/x-1.2");
        for risky in ["true", "No", "null", "123", "1e3", "2026-01-02", "a: b", "- x", "", "it's"] {
            assert!(scalar(risky).starts_with('\''), "{risky}");
        }
        assert_eq!(scalar("it's"), "'it''s'");
    }

    #[test]
    fn push_item_creates_replaces_and_extends() {
        let mut l = lines("v: 1\ntitle: T");
        push_item(&mut l, "sessions", vec!["- id: a".into()]).unwrap();
        assert_eq!(l.join("\n"), "v: 1\ntitle: T\nsessions:\n- id: a");
        push_item(&mut l, "sessions", vec!["- id: b".into()]).unwrap();
        assert_eq!(l.join("\n"), "v: 1\ntitle: T\nsessions:\n- id: a\n- id: b");
        let mut empty = lines("sessions: []\nstate: x");
        push_item(&mut empty, "sessions", vec!["- id: a".into()]).unwrap();
        assert_eq!(empty.join("\n"), "sessions:\n- id: a\nstate: x");
    }

    #[test]
    fn push_item_keeps_the_keys_after_a_block_and_refuses_flow_lists() {
        let mut l = lines("sessions:\n- id: a\n  extra: 1\nstate: x");
        push_item(&mut l, "sessions", vec!["- id: b".into()]).unwrap();
        assert_eq!(l.join("\n"), "sessions:\n- id: a\n  extra: 1\n- id: b\nstate: x");
        let mut flow = lines("temp_branches: [a]");
        assert!(push_item(&mut flow, "temp_branches", vec!["- b".into()]).is_err());
    }

    #[test]
    fn items_group_continuation_lines() {
        let l = lines("sessions:\n- id: a\n  extra: 1\n- id: b");
        let (at, end) = block(&l, "sessions").unwrap();
        assert_eq!(items(&l, at, end), vec![(1, 3), (3, 4)]);
    }
}
