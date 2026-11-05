/// Ruby's `String#strip` (ASCII whitespace, plus NUL at the end).
pub fn strip(s: &str) -> &str {
    s.trim_start_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r'])
        .trim_end_matches([' ', '\t', '\n', '\u{b}', '\u{c}', '\r', '\0'])
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
