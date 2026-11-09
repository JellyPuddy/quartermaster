//! Every config.yml key, listed once: its dotted path (`*` for a map key: a project name, a starter key, a
//! model), type, help text, the Settings section it sits in, whether it is rarely changed (collapsed), and
//! what an unset value falls back to (`inherits` another key's path, or a `default`). Containers are the
//! mappings keys live in; a container's shorthand is the one key a plain string stands for (a project given
//! as a path is its root). `ConfigFile` validates and writes against this; the GUI draws its form from
//! `payload`.

use serde_json::{json, Map, Value};

use crate::project_config::{Ide, DEFAULT_REVIEW_SKILL};

#[derive(Clone, Copy)]
pub struct Key {
    pub path: &'static str,
    /// string/path/text/bool/number/string_list/argv/enum
    pub kind: &'static str,
    pub help: &'static str,
    pub section: &'static str,
    pub collapsed: bool,
    pub inherits: Option<&'static str>,
    pub default: Option<&'static str>,
    pub options_from: Option<&'static str>,
}

impl Key {
    const fn new(path: &'static str, kind: &'static str, help: &'static str, section: &'static str) -> Key {
        Key { path, kind, help, section, collapsed: false, inherits: None, default: None, options_from: None }
    }
    const fn rare(mut self) -> Key {
        self.collapsed = true;
        self
    }
    const fn inherits(mut self, path: &'static str) -> Key {
        self.inherits = Some(path);
        self
    }
    const fn default(mut self, value: &'static str) -> Key {
        self.default = Some(value);
        self
    }
    const fn options_from(mut self, path: &'static str) -> Key {
        self.options_from = Some(path);
        self
    }

    fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("path".into(), json!(self.path));
        m.insert("type".into(), json!(self.kind));
        m.insert("help".into(), json!(self.help));
        m.insert("section".into(), json!(self.section));
        m.insert("collapsed".into(), json!(self.collapsed));
        for (name, value) in [("inherits", self.inherits), ("default", self.default), ("options_from", self.options_from)] {
            if let Some(v) = value {
                m.insert(name.into(), json!(v));
            }
        }
        Value::Object(m)
    }
}

pub const TYPES: [&str; 8] = ["string", "path", "text", "bool", "number", "string_list", "argv", "enum"];

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    /// any key → the child `<path>.*`
    Map,
    /// only listed keys
    Object,
}

pub struct Container {
    pub pattern: &'static str,
    pub kind: Kind,
    pub shorthand: Option<&'static str>,
}

const fn container(pattern: &'static str, kind: Kind, shorthand: Option<&'static str>) -> Container {
    Container { pattern, kind, shorthand }
}

pub static CONTAINERS: [Container; 8] = [
    container("projects", Kind::Map, None),
    container("projects.*", Kind::Object, Some("root")),
    container("projects.*.dev_server", Kind::Object, Some("command")),
    container("projects.*.benchmark", Kind::Object, None),
    container("loose_starters", Kind::Map, None),
    container("loose_starters.*", Kind::Object, None),
    container("prices", Kind::Map, None),
    container("prices.*", Kind::Object, None),
];

/// Top-level keys in the order a written file lists them.
pub const TOP_LEVEL: [&str; 7] = ["projects", "default_project", "ide_command", "ide_label", "loose_starters", "overview_artifact", "prices"];

const PRICE_HELP: [&str; 5] = [
    "USD per million input tokens",
    "USD per million tokens written to the 5-minute cache",
    "USD per million tokens written to the 1-hour cache",
    "USD per million cache-read tokens",
    "USD per million output tokens",
];

macro_rules! price_key {
    ($field:literal, $help:expr) => {
        Key::new(concat!("prices.*.", $field), "number", $help, "prices").rare()
    };
}

pub static KEYS: [Key; 25] = [
    Key::new("projects.*.root", "path", "The project's main repo root; sessions in it or its worktrees get this project.", "basics"),
    Key::new("projects.*.dev_server.command", "string", "The dev server command: qm runs `<command> switch PATH MODE`, `<command> stop`, `<command> status`.", "dev_server"),
    Key::new("projects.*.dev_server.modes", "string_list", "The modes `switch` accepts (default: one mode, `default`).", "dev_server"),
    Key::new("projects.*.dev_server.default_mode", "enum", "The mode Work on this starts in (default: the first mode).", "dev_server").options_from("projects.*.dev_server.modes"),
    Key::new("projects.*.dev_server.status_url", "string", "Answers JSON {mode, root, switching} while it serves.", "dev_server").rare(),
    Key::new("projects.*.dev_server.state_file", "path", "Holds `<mode> <root>` of what it serves.", "dev_server").rare(),
    Key::new("projects.*.test_db", "string", "Test-DB command: `<test_db> prepare` in each new worktree, `<test_db> drop PATH` on cleanup.", "worktrees"),
    Key::new("projects.*.review_skill", "string", "The PRs view's Review skill.", "pull_requests").default(DEFAULT_REVIEW_SKILL),
    Key::new("projects.*.pr_prerequisites", "bool", "PRs ship by release: sessions are told about `qm pr-requires`.", "pull_requests"),
    Key::new("projects.*.benchmark.database", "string", "The Postgres database benchmark runs read (or clone as a template); letters, digits and _ only.", "benchmarks").rare(),
    Key::new("projects.*.benchmark.skill", "path", "The benchmark skill's folder (SKILL.md, bin/example_bench.rb).", "benchmarks").rare(),
    Key::new("projects.*.benchmark.notes", "text", "Extra lines for the benchmark planner's prompt.", "benchmarks").rare(),
    Key::new("projects.*.ide_command", "argv", "This project's own IDE command, overriding the global one.", "ide").rare().inherits("ide_command"),
    Key::new("projects.*.ide_label", "string", "This project's IDE name, overriding the global one.", "ide").rare().inherits("ide_label"),
    Key::new("default_project", "enum", "Where a bare issue number starts (default: the first project).", "general").options_from("projects"),
    Key::new("ide_command", "argv", "Open in …: an argv with PATH, the checkout (shell-escaped inside a longer element, e.g. a `sh -c` script).", "ide"),
    Key::new("ide_label", "string", "The IDE buttons' name.", "ide").default(Ide::DEFAULT_LABEL),
    Key::new("loose_starters.*.label", "string", "The preset's name in the loose-chat dialog (default: its key).", "starters").rare(),
    Key::new("loose_starters.*.prompt", "text", "The opening prompt; it ends mid-sentence (\"… Then give a one-line count of them and\").", "starters").rare(),
    Key::new("overview_artifact", "string", "The published phone page's URL.", "phone").rare(),
    price_key!("input", PRICE_HELP[0]),
    price_key!("cache_write_5m", PRICE_HELP[1]),
    price_key!("cache_write_1h", PRICE_HELP[2]),
    price_key!("cache_read", PRICE_HELP[3]),
    price_key!("output", PRICE_HELP[4]),
];

pub fn segments(path: &str) -> Vec<&str> {
    if path.is_empty() { vec![] } else { path.split('.').collect() }
}

pub fn matches(pattern: &str, path: &str) -> bool {
    let (want, have) = (segments(pattern), segments(path));
    want.len() == have.len() && want.iter().zip(&have).all(|(w, h)| if *w == "*" { !h.is_empty() } else { w == h })
}

/// The Key a concrete dotted path names ("projects.App.test_db"), or None.
pub fn lookup(path: &str) -> Option<&'static Key> {
    KEYS.iter().find(|k| matches(k.path, path))
}

pub fn by_path(pattern: &str) -> Option<&'static Key> {
    KEYS.iter().find(|k| k.path == pattern)
}

/// The container pattern a concrete path names ("projects.App" → "projects.*"), or None.
pub fn container_of(path: &str) -> Option<&'static Container> {
    CONTAINERS.iter().find(|c| matches(c.pattern, path))
}

pub fn container_at(pattern: &str) -> Option<&'static Container> {
    CONTAINERS.iter().find(|c| c.pattern == pattern)
}

pub fn known(path: &str) -> bool {
    lookup(path).is_some() || container_of(path).is_some()
}

/// The pattern of a child key under a container pattern ("" the top level), or None when the schema
/// doesn't list it.
pub fn child(pattern: &str, key: &str) -> Option<String> {
    let candidate = if pattern.is_empty() {
        key.to_string()
    } else if container_at(pattern).is_some_and(|c| c.kind == Kind::Map) {
        format!("{pattern}.*")
    } else {
        format!("{pattern}.{key}")
    };
    (by_path(&candidate).is_some() || container_at(&candidate).is_some()).then_some(candidate)
}

/// The order keys under a container pattern are written in.
pub fn order(pattern: &str) -> Vec<String> {
    if pattern.is_empty() {
        return TOP_LEVEL.iter().map(|s| s.to_string()).collect();
    }
    let prefix = format!("{pattern}.");
    let mut out: Vec<String> = vec![];
    for k in KEYS.iter().filter(|k| k.path.starts_with(&prefix)) {
        let first = k.path[prefix.len()..].split('.').next().unwrap_or("").to_string();
        if first != "*" && !out.contains(&first) {
            out.push(first);
        }
    }
    out
}

pub fn payload() -> Value {
    let containers: Map<String, Value> = CONTAINERS
        .iter()
        .map(|c| {
            let mut m = Map::new();
            m.insert("kind".into(), json!(if c.kind == Kind::Map { "map" } else { "object" }));
            if let Some(s) = c.shorthand {
                m.insert("shorthand".into(), json!(s));
            }
            (c.pattern.to_string(), Value::Object(m))
        })
        .collect();
    json!({"types": TYPES, "keys": KEYS.iter().map(Key::to_json).collect::<Vec<_>>(), "containers": containers, "topLevel": TOP_LEVEL, "features": crate::config_features::FEATURE_IDS})
}
