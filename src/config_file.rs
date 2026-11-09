//! config.yml as an editable document: the Settings view and `qm config` both load it, change it by dotted
//! path or as a whole, check it (`config_check`) and write it back. qm owns the written layout (header,
//! the schema's key order, `|` blocks for multi-line text); comments are dropped, keys the schema doesn't
//! govern are kept as they are. A write holds the file's flock, is atomic (`atomic_file`), keeps the
//! previous file as config.yml.bak and is refused when the file changed since it was loaded.

use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use serde_yaml::{Mapping, Value};

use crate::atomic_file;
use crate::config_check::{tidy, ConfigCheck, Issue, MachineProbe, Probe};
use crate::config_emit::dump;
use crate::config_schema::{self as schema, Kind};
use crate::sha256;
use crate::yaml_scalar::text;

pub const HEADER: &str = "# Edited by qm (Settings view / qm config); key reference: docs/overview.md";

pub enum WriteError {
    /// config.yml changed since it was loaded.
    Stale,
    Invalid(Vec<Issue>),
    Io(String),
}

impl WriteError {
    pub fn message(&self) -> String {
        match self {
            WriteError::Stale => "config.yml changed since it was loaded; reload and redo the change".into(),
            WriteError::Invalid(issues) => issues.iter().map(|i| format!("{}: {}", i.path, i.message)).collect::<Vec<_>>().join("; "),
            WriteError::Io(e) => e.clone(),
        }
    }
}

pub struct ConfigFile {
    file: PathBuf,
    pub text: String,
    pub digest: String,
    pub data: Value,
    pub parse_error: Option<String>,
    probe: Box<dyn Probe>,
}

pub fn digest_of(text: &str) -> String {
    sha256::hex(text.as_bytes())
}

/// A `qm config set` value: YAML (`[dev, ngrok]` a list, `true` a bool, `4` a number); text YAML can't read
/// stays a string.
pub fn parse_value(source: &str) -> Value {
    match serde_yaml::from_str::<Value>(source) {
        Ok(Value::Tagged(_)) | Err(_) => Value::String(source.to_string()),
        Ok(Value::Null) if !matches!(source.trim(), "" | "~" | "null" | "Null" | "NULL") => Value::String(source.to_string()),
        Ok(v) => v,
    }
}

fn key(k: &str) -> Value {
    Value::String(k.to_string())
}

fn opened(shorthand: Option<&str>, node: Option<&Value>) -> Option<Value> {
    match (shorthand, node) {
        (Some(sh), Some(Value::String(s))) => Some(Value::Mapping(Mapping::from_iter([(key(sh), Value::String(s.clone()))]))),
        (_, other) => other.cloned(),
    }
}

impl ConfigFile {
    pub fn load(file: &Path) -> ConfigFile {
        Self::load_with(file, Box::new(MachineProbe))
    }

    pub fn load_with(file: &Path, probe: Box<dyn Probe>) -> ConfigFile {
        let text = std::fs::read_to_string(file).unwrap_or_default();
        let (data, parse_error) = parse(&text);
        ConfigFile { file: file.to_path_buf(), digest: digest_of(&text), text, data, parse_error, probe }
    }

    /// The value at a dotted path, None when absent; the whole mapping for "".
    pub fn get(&self, path: &str) -> Option<Value> {
        if path.is_empty() {
            return Some(self.data.clone());
        }
        let mut pattern = String::new();
        let mut node = Some(self.data.clone());
        for k in schema::segments(path) {
            let shorthand = schema::container_at(&pattern).and_then(|c| c.shorthand);
            let current = opened(shorthand, node.as_ref());
            pattern = schema::child(&pattern, k).unwrap_or_else(|| "-".into());
            node = match current {
                Some(Value::Mapping(m)) => m.get(k).cloned(),
                _ => None,
            };
        }
        node
    }

    /// Sets a schema-known path, creating mappings on the way and opening a shorthand (a project's plain
    /// path, a dev_server's plain command) into its mapping.
    pub fn set(&mut self, path: &str, value: Value) -> Result<(), String> {
        let (keys, last) = self.split(path, true)?;
        if let Some(parent) = self.parent(&keys, true) {
            parent.insert(key(&last), value);
        }
        Ok(())
    }

    pub fn unset(&mut self, path: &str) -> Result<(), String> {
        let (keys, last) = self.split(path, false)?;
        if let Some(parent) = self.parent(&keys, false) {
            parent.shift_remove(last.as_str());
        }
        Ok(())
    }

    /// Swaps in a whole mapping (the GUI's draft).
    pub fn replace(&mut self, data: Value) {
        self.parse_error = None;
        self.data = data;
    }

    pub fn issues(&self) -> Vec<Issue> {
        ConfigCheck::new(&self.data, self.parse_error.as_deref(), self.probe.as_ref()).issues()
    }

    pub fn errors(&self) -> Vec<Issue> {
        self.issues().into_iter().filter(|i| i.level == "error").collect()
    }

    pub fn warnings(&self) -> Vec<Issue> {
        self.issues().into_iter().filter(|i| i.level == "warning").collect()
    }

    /// Writes the document if it has no errors and the file still holds the text loaded with `digest`;
    /// returns the new digest.
    pub fn write(&mut self, digest: Option<&str>) -> Result<String, WriteError> {
        let errors = self.errors();
        if !errors.is_empty() {
            return Err(WriteError::Invalid(errors));
        }
        let io = |e: std::io::Error| WriteError::Io(e.to_string());
        let dir = self.file.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(dir).map_err(io)?;
        let lock = std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join(".config.yml.lock")).map_err(io)?;
        // SAFETY: the descriptor stays open until `lock` drops at the end of this function.
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        let exists = self.file.exists();
        let current = if exists { std::fs::read_to_string(&self.file).map_err(io)? } else { String::new() };
        if digest_of(&current) != digest.unwrap_or(&self.digest) {
            return Err(WriteError::Stale);
        }
        let text = emit(&self.data);
        if exists {
            std::fs::write(self.file.with_file_name("config.yml.bak"), &current).map_err(io)?;
        }
        atomic_file::write(&self.file, &text).map_err(io)?;
        self.digest = digest_of(&text);
        self.text = text;
        Ok(self.digest.clone())
    }

    fn split(&self, path: &str, create: bool) -> Result<(Vec<String>, String), String> {
        let mut keys: Vec<String> = schema::segments(path).into_iter().map(String::from).collect();
        let parent = keys[..keys.len().saturating_sub(1)].join(".");
        let known = schema::known(path) || (!create && schema::container_of(&parent).is_some());
        match keys.pop() {
            Some(last) if known => Ok((keys, last)),
            _ => Err(format!("unknown config key: {path}")),
        }
    }

    fn parent(&mut self, keys: &[String], create: bool) -> Option<&mut Mapping> {
        if !matches!(self.data, Value::Mapping(_)) {
            self.data = Value::Mapping(Mapping::new());
        }
        let Value::Mapping(root) = &mut self.data else { return None };
        descend(root, keys, String::new(), create)
    }
}

fn descend<'a>(node: &'a mut Mapping, keys: &[String], pattern: String, create: bool) -> Option<&'a mut Mapping> {
    let Some((first, rest)) = keys.split_first() else { return Some(node) };
    let pattern = schema::child(&pattern, first).unwrap_or_default();
    let shorthand = schema::container_at(&pattern).and_then(|c| c.shorthand);
    let child = match opened(shorthand, node.get(first.as_str())) {
        Some(Value::Mapping(m)) => m,
        _ if create => Mapping::new(),
        _ => return None,
    };
    node.insert(key(first), Value::Mapping(child));
    match node.get_mut(first.as_str()) {
        Some(Value::Mapping(m)) => descend(m, rest, pattern, create),
        _ => None,
    }
}

fn parse(source: &str) -> (Value, Option<String>) {
    match serde_yaml::from_str::<Value>(source) {
        Ok(Value::Null) => (Value::Mapping(Mapping::new()), None),
        Ok(v @ Value::Mapping(_)) => (v, None),
        Ok(_) => (Value::Mapping(Mapping::new()), Some("is not a mapping of keys".into())),
        Err(e) => (Value::Mapping(Mapping::new()), Some(format!("is not valid YAML: {e}"))),
    }
}

/// The file text qm writes for a config mapping.
pub fn emit(data: &Value) -> String {
    format!("{HEADER}\n{}", dump(&ordered(&tidy(data, ""), "")))
}

/// A mapping's keys in schema order (then any others in their own order); a map's keys as the user ordered
/// them; a project holding only its root in its plain-path shorthand.
fn ordered(value: &Value, pattern: &str) -> Value {
    let Value::Mapping(map) = value else { return value.clone() };
    let container = schema::container_at(pattern);
    if !pattern.is_empty() && container.is_none() {
        return value.clone();
    }
    let present: Vec<String> = map.keys().map(text).collect();
    let keys: Vec<String> = if container.is_some_and(|c| c.kind == Kind::Map) {
        present
    } else {
        let order = schema::order(pattern);
        order.iter().filter(|k| present.contains(k)).cloned().chain(present.iter().filter(|k| !order.contains(k)).cloned()).collect()
    };
    let mut out = Mapping::new();
    for k in keys {
        let Some((orig_key, v)) = map.iter().find(|(ok, _)| text(ok) == k) else { continue };
        let v = match schema::child(pattern, &k) {
            Some(child) => ordered(v, &child),
            None => v.clone(),
        };
        out.insert(orig_key.clone(), v);
    }
    if pattern == "projects.*" && out.len() == 1 {
        if let Some(root @ Value::String(_)) = out.get("root") {
            return root.clone();
        }
    }
    Value::Mapping(out)
}
