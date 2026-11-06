/// Ruby's `String#strip` (ASCII whitespace, plus NUL at the end).
pub fn strip(s: &str) -> &str {
    s.trim_start_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r'])
        .trim_end_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r', '\0'])
}

/// `String#inspect` of an ASCII string (UTF-8 encoded); None for anything with other characters.
pub fn inspect_ascii(s: &str) -> Option<String> {
    if !s.is_ascii() {
        return None;
    }
    let mut out = String::from("\"");
    let chars: Vec<char> = s.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{c}' => out.push_str("\\f"),
            '\u{b}' => out.push_str("\\v"),
            '\u{8}' => out.push_str("\\b"),
            '\u{7}' => out.push_str("\\a"),
            '\u{1b}' => out.push_str("\\e"),
            '#' if matches!(chars.get(i + 1), Some('{' | '$' | '@')) => out.push_str("\\#"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    Some(out)
}

/// Ruby's `String#rstrip`.
pub fn rstrip(s: &str) -> &str {
    s.trim_end_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r', '\0'])
}

/// `str[0, n]` by characters.
pub fn prefix(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_and_prefix_follow_ruby() {
        assert_eq!(strip(" \t x y\n\0"), "x y");
        assert_eq!(prefix("héllo wörld", 4), "héll");
        assert_eq!(prefix("ab", 8), "ab");
    }
}
