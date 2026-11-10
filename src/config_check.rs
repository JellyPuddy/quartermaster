//! The one validator of a config mapping, shared by the Settings view and `qm config`: issues
//! `{level, path, message}`. An error blocks a write (a value of the wrong type, a key the schema doesn't
//! list under a mapping it governs, a setting that can't work); a warning never does (a folder or command
//! that isn't there on this machine right now).

use serde_json::{json, Value as Json};
use serde_yaml::{Mapping, Value};

use crate::cli_format::short_path;
use crate::config_schema::{self as schema, Kind};
use crate::data_root;
use crate::ruby_text::strip;
use crate::yaml_scalar::text as scalar_text;

#[derive(Clone, Debug, PartialEq)]
pub struct Issue {
    pub level: &'static str,
    pub path: String,
    pub message: String,
}

impl Issue {
    pub fn to_json(&self) -> Json {
        json!({"level": self.level, "path": self.path, "message": self.message})
    }
}

/// What the warnings look at on this machine; tests pass a stub.
pub trait Probe {
    fn dir(&self, path: &str) -> bool;
    fn command(&self, name: &str) -> bool;
}

pub struct MachineProbe;

fn executable_file(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

impl Probe for MachineProbe {
    fn dir(&self, path: &str) -> bool {
        std::path::Path::new(path).is_dir()
    }

    fn command(&self, name: &str) -> bool {
        if name.contains('/') {
            return executable_file(&data_root::expand_path(name));
        }
        let mut dirs: Vec<std::path::PathBuf> = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
        dirs.push(data_root::expand_path("~/bin"));
        dirs.iter().any(|d| executable_file(&d.join(name)))
    }
}

fn type_message(kind: &str) -> &'static str {
    match kind {
        "string" | "text" | "enum" => "must be text",
        "path" => "must be a path",
        "bool" => "must be true or false",
        "number" => "must be a number",
        "string_list" => "must be a list of names, e.g. [dev, tunnel]",
        _ => "must be a command list, e.g. [open, -a, MyIDE, PATH]",
    }
}

fn is_scalar(v: &Value) -> bool {
    matches!(v, Value::String(_) | Value::Number(_))
}

fn is_text(v: Option<&Value>) -> bool {
    matches!(v, Some(Value::String(s)) if !strip(s).is_empty())
}

fn text_of(v: Option<&Value>) -> &str {
    match v {
        Some(Value::String(s)) => strip(s),
        _ => "",
    }
}

fn field<'a>(m: &'a Mapping, key: &str) -> Option<&'a Value> {
    m.get(key)
}

fn blank(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::String(s) => strip(s).is_empty(),
        Value::Mapping(m) => m.is_empty(),
        Value::Sequence(s) => s.is_empty(),
        _ => false,
    }
}

/// The mapping as qm keeps it: under the keys the schema governs, unset values (null, blank text, empty
/// lists) and emptied sub-mappings are dropped, and a bare `projects:` is no projects; everything else is
/// untouched.
pub fn tidy(data: &Value, pattern: &str) -> Value {
    let Value::Mapping(map) = data else { return data.clone() };
    let mut out = Mapping::new();
    for (key, value) in map {
        let key_text = scalar_text(key);
        let Some(child) = schema::child(pattern, &key_text) else {
            out.insert(key.clone(), value.clone());
            continue;
        };
        let mut value = if value.is_null() && child == "projects" { Value::Mapping(Mapping::new()) } else { value.clone() };
        if schema::container_at(&child).is_some() {
            value = tidy(&value, &child);
        }
        let kept = if pattern.is_empty() { key_text == "projects" } else { schema::container_at(pattern).is_some_and(|c| c.kind == Kind::Map) };
        if blank(&value) && !kept {
            continue;
        }
        out.insert(key.clone(), value);
    }
    Value::Mapping(out)
}

pub struct ConfigCheck<'a> {
    data: &'a Value,
    parse_error: Option<&'a str>,
    probe: &'a dyn Probe,
    issues: Vec<Issue>,
}

impl<'a> ConfigCheck<'a> {
    pub fn new(data: &'a Value, parse_error: Option<&'a str>, probe: &'a dyn Probe) -> Self {
        ConfigCheck { data, parse_error, probe, issues: vec![] }
    }

    pub fn issues(mut self) -> Vec<Issue> {
        if let Some(e) = self.parse_error {
            return vec![Issue { level: "error", path: String::new(), message: format!("config.yml {e}") }];
        }
        if !matches!(self.data, Value::Mapping(_)) {
            return vec![Issue { level: "error", path: String::new(), message: "config must be a mapping of keys".into() }];
        }
        let Value::Mapping(data) = tidy(self.data, "") else { return vec![] };
        for (key, value) in &data {
            let key = scalar_text(key);
            if let Some(child) = schema::child("", &key) {
                self.check_node(value, &child, &key);
            }
        }
        if let Some(Value::Mapping(projects)) = field(&data, "projects") {
            self.check_projects(projects);
        }
        self.check_globals(&data);
        if let Some(Value::Mapping(starters)) = field(&data, "loose_starters") {
            self.check_starters(starters);
        }
        self.issues
    }

    fn error(&mut self, path: &str, message: impl Into<String>) {
        self.issues.push(Issue { level: "error", path: path.into(), message: message.into() });
    }

    fn warning(&mut self, path: &str, message: impl Into<String>) {
        self.issues.push(Issue { level: "warning", path: path.into(), message: message.into() });
    }

    fn check_node(&mut self, value: &Value, pattern: &str, path: &str) {
        let Some(container) = schema::container_at(pattern) else {
            let key = schema::by_path(pattern);
            self.check_type(key.map(|k| k.kind).unwrap_or("string"), value, path);
            if let (Some(options), Value::String(text)) = (key.and_then(|k| k.options), value) {
                if !options.contains(&crate::ruby_text::strip(text)) {
                    self.error(path, format!("must be one of: {}", options.join(", ")));
                }
            }
            return;
        };
        let opened;
        let value = match (container.shorthand, value) {
            (Some(short), Value::String(_)) => {
                let mut m = Mapping::new();
                m.insert(Value::String(short.into()), value.clone());
                opened = Value::Mapping(m);
                &opened
            }
            _ => value,
        };
        let Value::Mapping(map) = value else {
            self.error(path, match container.shorthand {
                Some(short) => format!("must be a mapping or a {short}"),
                None => "must be a mapping".into(),
            });
            return;
        };
        for (key, child_value) in map {
            let key = scalar_text(key);
            match schema::child(pattern, &key) {
                Some(child) => self.check_node(child_value, &child, &format!("{path}.{key}")),
                None => self.error(&format!("{path}.{key}"), format!("unknown key {key}")),
            }
        }
    }

    fn check_type(&mut self, kind: &str, value: &Value, path: &str) {
        let ok = match kind {
            "string" | "path" | "text" | "enum" => matches!(value, Value::String(_)),
            "bool" => matches!(value, Value::Bool(_)),
            "number" => matches!(value, Value::Number(_)),
            "string_list" => matches!(value, Value::String(_)) || matches!(value, Value::Sequence(s) if s.iter().all(is_scalar)),
            "argv" => matches!(value, Value::Sequence(s) if s.iter().all(is_scalar)),
            _ => true,
        };
        if !ok {
            self.error(path, type_message(kind));
        }
    }

    fn check_projects(&mut self, projects: &Mapping) {
        for (name, value) in projects {
            let path = format!("projects.{}", scalar_text(name));
            let value = match value {
                Value::String(_) => {
                    let mut m = Mapping::new();
                    m.insert(Value::String("root".into()), value.clone());
                    m
                }
                Value::Mapping(m) => m.clone(),
                _ => continue,
            };
            self.check_root(&format!("{path}.root"), field(&value, "root"));
            self.check_dev_server(&format!("{path}.dev_server"), field(&value, "dev_server"));
            self.check_command(&format!("{path}.test_db"), field(&value, "test_db"));
            self.check_benchmark(&format!("{path}.benchmark"), field(&value, "benchmark"));
            self.check_ide(&path, &value);
        }
    }

    fn check_root(&mut self, path: &str, root: Option<&Value>) {
        if matches!(root, Some(v) if !v.is_null() && !v.is_string()) {
            return;
        }
        if !is_text(root) {
            return self.error(path, "a project needs a root: its main repo's folder");
        }
        self.check_dir(path, text_of(root));
    }

    fn check_dev_server(&mut self, path: &str, server: Option<&Value>) {
        let server = match server {
            Some(Value::String(s)) => {
                let mut m = Mapping::new();
                m.insert(Value::String("command".into()), Value::String(s.clone()));
                m
            }
            Some(Value::Mapping(m)) => m.clone(),
            _ => return,
        };
        if !is_text(field(&server, "command")) {
            return self.error(&format!("{path}.command"), "dev_server needs a command");
        }
        self.check_command(&format!("{path}.command"), field(&server, "command"));
        let modes: Option<Vec<String>> = match field(&server, "modes") {
            Some(Value::String(s)) => Some(vec![s.clone()]).map(|v| v.into_iter().filter(|m| !m.is_empty()).collect()),
            Some(Value::Sequence(items)) => Some(items.iter().map(scalar_text).filter(|m| !m.is_empty()).collect()),
            _ => None,
        };
        let default = field(&server, "default_mode");
        if let (true, Some(modes)) = (is_text(default), &modes) {
            if !modes.is_empty() && !modes.iter().any(|m| m == text_of(default)) {
                self.error(&format!("{path}.default_mode"), format!("default_mode must be one of the modes: {}", modes.join(", ")));
            }
        }
        if is_text(field(&server, "state_file")) {
            let file = text_of(field(&server, "state_file"));
            let dir = std::path::Path::new(file).parent().map(|p| p.to_string_lossy().into_owned()).filter(|p| !p.is_empty()).unwrap_or_else(|| ".".into());
            self.check_dir(&format!("{path}.state_file"), &dir);
        }
    }

    fn check_benchmark(&mut self, path: &str, bench: Option<&Value>) {
        let Some(Value::Mapping(bench)) = bench else { return };
        let (database, skill) = (field(bench, "database"), field(bench, "skill"));
        if !(is_text(database) && is_text(skill)) {
            return self.error(path, "benchmark needs both database and skill");
        }
        let db = text_of(database);
        if !db.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return self.error(&format!("{path}.database"), "database must be letters, digits and _ only");
        }
        self.check_dir(&format!("{path}.skill"), text_of(skill));
    }

    fn check_ide(&mut self, path: &str, value: &Mapping) {
        let prefix = if path.is_empty() { String::new() } else { format!("{path}.") };
        let command = field(value, "ide_command");
        if let Some(Value::Sequence(argv)) = command {
            if argv.iter().all(is_scalar) {
                if argv.is_empty() || strip(&scalar_text(&argv[0])).is_empty() {
                    self.error(&format!("{prefix}ide_command"), "ide_command must start with a program");
                } else if argv.iter().all(|a| !scalar_text(a).contains("PATH")) {
                    self.error(&format!("{prefix}ide_command"), "ide_command needs a PATH element where the checkout's path goes");
                }
            }
        }
        if is_text(field(value, "ide_label")) && command.is_none_or(|c| c.is_null()) {
            self.warning(&format!("{prefix}ide_label"), "ide_label does nothing without ide_command");
        }
    }

    fn check_globals(&mut self, data: &Mapping) {
        self.check_ide("", data);
        let default = field(data, "default_project");
        if !is_text(default) {
            return;
        }
        let names: Vec<String> = match field(data, "projects") {
            Some(Value::Mapping(p)) => p.keys().map(scalar_text).collect(),
            _ => vec![],
        };
        if !names.iter().any(|n| n == text_of(default)) {
            self.error("default_project", format!("default_project must name a project ({})", names.join(", ")));
        }
    }

    fn check_starters(&mut self, starters: &Mapping) {
        for (key, starter) in starters {
            let Value::Mapping(starter) = starter else { continue };
            if !is_text(field(starter, "prompt")) {
                self.error(&format!("loose_starters.{}.prompt", scalar_text(key)), "a loose-chat starter needs a prompt");
            }
        }
    }

    fn check_command(&mut self, path: &str, command: Option<&Value>) {
        if !is_text(command) {
            return;
        }
        let name = text_of(command).split_whitespace().next().unwrap_or("");
        if !self.probe.command(name) {
            self.warning(path, format!("{name} is not on PATH"));
        }
    }

    fn check_dir(&mut self, path: &str, dir: &str) {
        let expanded = data_root::expand_path(strip(dir)).to_string_lossy().into_owned();
        if !self.probe.dir(&expanded) {
            self.warning(path, format!("folder {} doesn't exist", short_path(Some(&expanded))));
        }
    }
}
