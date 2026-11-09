//! config.yml read as Psych reads it for the keys the schema calls boolean: a plain `yes`, `no`, `on` or `off`
//! (any case) is a boolean there, while serde_yaml reads them as text and cannot tell a quoted `'yes'`, which
//! stays a string, from a plain one. A small scanner finds which scalars are written plain, by key path, in block
//! and flow mappings; only those on a schema `bool` key become booleans, so the check, the writer and every
//! reader see one value.

use serde_yaml::Value;

use crate::config_schema as schema;
use crate::yaml_scalar::psych_bool;

/// `serde_yaml::from_str::<Value>` with the schema's boolean keys read the Psych way.
pub fn parse(source: &str) -> Result<Value, serde_yaml::Error> {
    let mut value = serde_yaml::from_str::<Value>(source)?;
    let plain = plain_scalar_paths(source);
    if !plain.is_empty() {
        fix(&mut value, "", &plain);
    }
    Ok(value)
}

fn fix(value: &mut Value, path: &str, plain: &[String]) {
    let Value::Mapping(map) = value else { return };
    for (k, v) in map.iter_mut() {
        let Value::String(name) = k else { continue };
        let here = if path.is_empty() { name.clone() } else { format!("{path}.{name}") };
        match v {
            Value::String(s) if plain.contains(&here) && schema::lookup(&here).is_some_and(|key| key.kind == "bool") => {
                if let Some(b) = psych_bool(s) {
                    *v = Value::Bool(b);
                }
            }
            Value::Mapping(_) => fix(v, &here, plain),
            _ => {}
        }
    }
}

fn join(prefix: &str, key: &str) -> String {
    if prefix.is_empty() { key.to_string() } else { format!("{prefix}.{key}") }
}

/// The dotted paths whose value is written as a plain scalar. Sequences are opaque: nothing under one is listed.
fn plain_scalar_paths(source: &str) -> Vec<String> {
    let mut out = vec![];
    let mut stack: Vec<(usize, Option<String>)> = vec![];
    let mut block_scalar_above: Option<usize> = None;
    let mut lines = source.lines();
    while let Some(line) = lines.next() {
        let trimmed = line.trim_start_matches(' ');
        let indent = line.len() - trimmed.len();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(n) = block_scalar_above {
            if indent > n {
                continue;
            }
            block_scalar_above = None;
        }
        if trimmed.starts_with('#') {
            continue;
        }
        while stack.last().is_some_and(|(i, _)| *i >= indent) {
            stack.pop();
        }
        if trimmed.starts_with("- ") || trimmed == "-" {
            stack.push((indent, None));
            continue;
        }
        let opaque = stack.iter().any(|(_, k)| k.is_none());
        let prefix: String = stack.iter().filter_map(|(_, k)| k.as_deref()).collect::<Vec<_>>().join(".");
        if trimmed.starts_with('{') && stack.is_empty() {
            let text = gather_flow(trimmed, &mut lines);
            flow_mapping(&text.chars().collect::<Vec<_>>(), &mut 0, "", &mut out);
            continue;
        }
        let Some((key, rest)) = split_key(trimmed) else { continue };
        let value = strip_comment(rest).trim();
        match value.chars().next() {
            None => stack.push((indent, Some(key))),
            Some('|' | '>') => block_scalar_above = Some(indent),
            Some('{') => {
                let text = gather_flow(value, &mut lines);
                if !opaque {
                    flow_mapping(&text.chars().collect::<Vec<_>>(), &mut 0, &join(&prefix, &key), &mut out);
                }
            }
            Some('[') => {
                gather_flow(value, &mut lines);
            }
            Some('\'' | '"' | '!' | '&' | '*') => {}
            Some(_) => {
                if !opaque {
                    out.push(join(&prefix, &key));
                }
            }
        }
    }
    out
}

/// A `key: rest` line's key (unquoted) and what follows the colon; None for a line that is no mapping entry.
fn split_key(line: &str) -> Option<(String, &str)> {
    let first = line.chars().next()?;
    if first == '"' || first == '\'' {
        let end = quoted_end(line.as_bytes(), 0)?;
        let rest = line[end..].trim_start().strip_prefix(':')?;
        return Some((line[1..end - 1].to_string(), rest));
    }
    if matches!(first, '[' | '{' | '?' | '!' | '&' | '*' | '|' | '>') {
        return None;
    }
    let at = line.find(": ").or_else(|| line.strip_suffix(':').map(|l| l.len()))?;
    Some((line[..at].trim_end().to_string(), &line[at + 1..]))
}

/// The index just past the quoted scalar starting at `from`.
fn quoted_end(b: &[u8], from: usize) -> Option<usize> {
    let q = b[from];
    let mut i = from + 1;
    while i < b.len() {
        if q == b'"' && b[i] == b'\\' {
            i += 2;
            continue;
        }
        if b[i] == q {
            if q == b'\'' && b.get(i + 1) == Some(&b'\'') {
                i += 2;
                continue;
            }
            return Some(i + 1);
        }
        i += 1;
    }
    None
}

fn strip_comment(s: &str) -> &str {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if (b[i] == b'\'' || b[i] == b'"') && i == s.len() - s.trim_start().len() {
            match quoted_end(b, i) {
                Some(end) => i = end,
                None => return s,
            }
            continue;
        }
        if b[i] == b'#' && (i == 0 || b[i - 1] == b' ') {
            return &s[..i];
        }
        i += 1;
    }
    s
}

/// `first` and as many following lines as it takes to close its brackets.
fn gather_flow(first: &str, lines: &mut std::str::Lines) -> String {
    let mut text = strip_comment(first).to_string();
    while depth(&text) > 0 {
        let Some(next) = lines.next() else { break };
        text.push(' ');
        text.push_str(strip_comment(next.trim()));
    }
    text
}

fn depth(text: &str) -> i32 {
    let b = text.as_bytes();
    let (mut i, mut d) = (0, 0);
    while i < b.len() {
        match b[i] {
            b'\'' | b'"' => match quoted_end(b, i) {
                Some(end) => {
                    i = end;
                    continue;
                }
                None => return d,
            },
            b'{' | b'[' => d += 1,
            b'}' | b']' => d -= 1,
            _ => {}
        }
        i += 1;
    }
    d
}

fn skip_space(c: &[char], i: &mut usize) {
    while *i < c.len() && c[*i].is_whitespace() {
        *i += 1;
    }
}

/// Skips the quoted scalar or bracketed collection at `i`.
fn skip_nested(c: &[char], i: &mut usize) {
    let text: String = c[*i..].iter().collect();
    let b = text.as_bytes();
    let mut end = 0;
    if b[0] == b'\'' || b[0] == b'"' {
        end = quoted_end(b, 0).unwrap_or(b.len());
    } else {
        let (mut d, mut k) = (0, 0);
        while k < b.len() {
            if b[k] == b'\'' || b[k] == b'"' {
                k = quoted_end(b, k).unwrap_or(b.len());
                continue;
            }
            if b[k] == b'{' || b[k] == b'[' {
                d += 1;
            } else if b[k] == b'}' || b[k] == b']' {
                d -= 1;
                if d == 0 {
                    end = k + 1;
                    break;
                }
            }
            k += 1;
        }
        if end == 0 {
            end = b.len();
        }
    }
    *i += text[..end].chars().count();
}

/// Lists the plain scalars of the flow mapping at `c[*i]` (a `{`), under `prefix`.
fn flow_mapping(c: &[char], i: &mut usize, prefix: &str, out: &mut Vec<String>) {
    *i += 1;
    loop {
        skip_space(c, i);
        if *i >= c.len() {
            return;
        }
        match c[*i] {
            '}' => {
                *i += 1;
                return;
            }
            ',' => {
                *i += 1;
                continue;
            }
            _ => {}
        }
        let key = if c[*i] == '"' || c[*i] == '\'' {
            let start = *i;
            skip_nested(c, i);
            c[start + 1..(*i).saturating_sub(1).max(start + 1)].iter().collect::<String>()
        } else {
            let start = *i;
            while *i < c.len() && !matches!(c[*i], ':' | ',' | '}') {
                *i += 1;
            }
            c[start..*i].iter().collect::<String>().trim().to_string()
        };
        skip_space(c, i);
        if c.get(*i) != Some(&':') {
            continue;
        }
        *i += 1;
        skip_space(c, i);
        let Some(&first) = c.get(*i) else { return };
        let path = join(prefix, &key);
        match first {
            '{' => flow_mapping(c, i, &path, out),
            '[' | '\'' | '"' | '!' | '&' | '*' => skip_nested_value(c, i),
            ',' | '}' => {}
            _ => {
                while *i < c.len() && !matches!(c[*i], ',' | '}' | ']') {
                    *i += 1;
                }
                out.push(path);
            }
        }
    }
}

fn skip_nested_value(c: &[char], i: &mut usize) {
    if matches!(c[*i], '[' | '\'' | '"') {
        skip_nested(c, i);
    } else {
        while *i < c.len() && !matches!(c[*i], ',' | '}') {
            *i += 1;
        }
    }
}
