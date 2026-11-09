//! config.yml as qm writes it: Psych's layout without Ruby (`psych` spells the scalars) — block mappings,
//! sequences flush under their key, flow lists of plain scalars (`[dev, tunnel]`), `|` blocks for multi-line
//! text, unfolded lines, and paths and flags unquoted when they read back the same.

use regex::Regex;
use serde_yaml::{Mapping, Value};
use std::sync::OnceLock;

use crate::psych;
use crate::yaml_scalar::text;

/// A mapping or list as qm writes it (no document marker, a trailing newline).
pub fn dump(value: &Value) -> String {
    let mut lines = vec![];
    match value {
        Value::Mapping(m) if !m.is_empty() => map_lines(m, 0, &mut lines),
        Value::Sequence(s) if !s.is_empty() && !flows(s) => seq_lines(s, 0, &mut lines),
        other => match inline(other, false) {
            Inline::Text(t) => lines.push(t),
            Inline::Literal(t) => lines.push(quoted(&t)),
        },
    }
    lines.iter().map(|l| format!("{l}\n")).collect()
}

enum Inline {
    Text(String),
    /// A multi-line string: a `|` block.
    Literal(String),
}

fn pad(n: usize) -> String {
    " ".repeat(n)
}

fn quoted(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

fn plain_path(s: &str) -> bool {
    static PATH: OnceLock<Regex> = OnceLock::new();
    let re = PATH.get_or_init(|| Regex::new(r"^[-/~.A-Za-z0-9_][A-Za-z0-9_/.~+@:-]*(?: [A-Za-z0-9_/.~+@:-]+)*$").unwrap());
    re.is_match(s) && !s.contains(": ") && psych::reads_as_non_string(s) == Some(false)
}

/// Psych double-quotes every string starting with a non-word character; paths and flags (`/code/app`, `~/x`,
/// `-a`) read back the same without quotes.
fn string_text(s: &str) -> String {
    let spelled = psych::scalar_unfolded(s);
    if spelled.starts_with('"') && plain_path(s) {
        return if s.ends_with(':') { format!("'{s}'") } else { s.to_string() };
    }
    spelled
}

fn block_allowed(s: &str) -> bool {
    let printable = |c: char| matches!(c, '\n' | ' '..='~' | '\u{85}' | '\u{a0}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}') && c != '\u{feff}';
    !s.ends_with(' ') && !s.contains(" \n") && s.chars().all(printable)
}

fn inline(v: &Value, in_flow: bool) -> Inline {
    match v {
        Value::Null => Inline::Text(String::new()),
        Value::Bool(b) => Inline::Text(b.to_string()),
        Value::Number(n) => Inline::Text(n.to_string()),
        Value::String(s) if s.contains('\n') => {
            if block_allowed(s) { Inline::Literal(s.clone()) } else { Inline::Text(quoted(s)) }
        }
        Value::String(s) => {
            let t = string_text(s);
            let unsafe_in_flow = in_flow && !t.starts_with(['"', '\'']) && t.contains([',', '?', '[', ']', '{', '}']);
            Inline::Text(if unsafe_in_flow { format!("'{}'", t.replace('\'', "''")) } else { t })
        }
        other => Inline::Text(serde_yaml::to_string(other).unwrap_or_default().trim().to_string()),
    }
}

fn flows(items: &[Value]) -> bool {
    items.iter().all(|v| !matches!(v, Value::Mapping(_) | Value::Sequence(_)) && !matches!(v, Value::String(s) if s.contains('\n')))
}

fn flow(items: &[Value]) -> String {
    let parts: Vec<String> = items.iter().map(|v| if let Inline::Text(t) = inline(v, true) { t } else { String::new() }).collect();
    format!("[{}]", parts.join(", "))
}

fn literal_lines(s: &str, indent: usize, out: &mut Vec<String>, head: &str) {
    let chomp = if !s.ends_with('\n') { "-" } else if s.ends_with("\n\n") { "+" } else { "" };
    let hint = if s.starts_with([' ', '\n']) { "2" } else { "" };
    out.push(format!("{head} |{hint}{chomp}"));
    for line in s.strip_suffix('\n').unwrap_or(s).split('\n') {
        out.push(if line.is_empty() { String::new() } else { format!("{}{line}", pad(indent))});
    }
}

fn map_lines(m: &Mapping, indent: usize, out: &mut Vec<String>) {
    for (k, v) in m {
        let head = format!("{}{}:", pad(indent), match inline(&Value::String(text(k)), false) { Inline::Text(t) => t, Inline::Literal(t) => quoted(&t) });
        match v {
            Value::Mapping(c) if !c.is_empty() => {
                out.push(head);
                map_lines(c, indent + 2, out);
            }
            Value::Mapping(_) => out.push(format!("{head} {{}}")),
            Value::Sequence(s) if s.is_empty() => out.push(format!("{head} []")),
            Value::Sequence(s) if flows(s) => out.push(format!("{head} {}", flow(s))),
            Value::Sequence(s) => {
                out.push(head);
                seq_lines(s, indent, out);
            }
            scalar => match inline(scalar, false) {
                Inline::Text(t) if t.is_empty() => out.push(head),
                Inline::Text(t) => out.push(format!("{head} {t}")),
                Inline::Literal(t) => literal_lines(&t, indent + 2, out, &head),
            },
        }
    }
}

fn seq_lines(items: &[Value], indent: usize, out: &mut Vec<String>) {
    let dash = format!("{}-", pad(indent));
    for v in items {
        match v {
            Value::Mapping(c) if !c.is_empty() => nested(out, indent, |o| map_lines(c, indent + 2, o)),
            Value::Mapping(_) => out.push(format!("{dash} {{}}")),
            Value::Sequence(s) if s.is_empty() => out.push(format!("{dash} []")),
            Value::Sequence(s) if flows(s) => out.push(format!("{dash} {}", flow(s))),
            Value::Sequence(s) => nested(out, indent, |o| seq_lines(s, indent + 2, o)),
            scalar => match inline(scalar, false) {
                Inline::Text(t) if t.is_empty() => out.push(dash.clone()),
                Inline::Text(t) => out.push(format!("{dash} {t}")),
                Inline::Literal(t) => literal_lines(&t, indent + 2, out, &dash),
            },
        }
    }
}

/// A collection that is a list item: its first line carries the dash in place of its own padding.
fn nested(out: &mut Vec<String>, indent: usize, fill: impl FnOnce(&mut Vec<String>)) {
    let mut lines = vec![];
    fill(&mut lines);
    if let Some(first) = lines.first_mut() {
        *first = format!("{}- {}", pad(indent), &first[indent + 2..]);
    }
    out.extend(lines);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn yaml(s: &str) -> Value {
        serde_yaml::from_str(s).unwrap()
    }

    #[test]
    fn lists_of_plain_scalars_are_flow_and_paths_stay_unquoted() {
        assert_eq!(dump(&yaml("ide_command: [zsh, -ic, \"myide PATH\"]\nroot: /code/app\nhome: ~/x\n")), "ide_command: [zsh, -ic, myide PATH]\nroot: /code/app\nhome: ~/x\n");
    }

    #[test]
    fn multi_line_text_is_a_block_and_odd_strings_are_quoted() {
        assert_eq!(dump(&yaml("n: \"a\\nb\\n\"\nm: \"a\\nb\"\nt: 'true'\nc: 'a: b'\nd: '-5'\n")), "n: |\n  a\n  b\nm: |-\n  a\n  b\nt: 'true'\nc: 'a: b'\nd: \"-5\"\n");
    }

    #[test]
    fn a_comma_in_a_flow_item_is_quoted_and_nested_lists_are_blocks() {
        assert_eq!(dump(&yaml("a: ['x,y', z]\nb:\n- [1, 2]\n- k: v\n  w: [3]\n- - p\n  - q: 1\nc: {}\nd: []\ne: ~\n")), "a: ['x,y', z]\nb:\n- [1, 2]\n- k: v\n  w: [3]\n- - p\n  - q: 1\nc: {}\nd: []\ne:\n");
    }

    #[test]
    fn long_lines_are_not_folded() {
        let long = "word ".repeat(40).trim().to_string();
        assert_eq!(dump(&yaml(&format!("k: {long}"))), format!("k: {long}\n"));
    }
}
