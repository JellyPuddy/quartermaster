//! The one way code reads config values: a reader over a mapping at a schema pattern ("" the top level,
//! "projects.*" a project) hands out the raw value of a key the schema lists there, or a reader one level
//! down. A shorthand opens into its mapping (a project given as a path is its root); anything that isn't a
//! mapping reads as an empty one. Asking for a key the schema doesn't list is a bug in the asker: it panics
//! while QM_CONFIG_STRICT=1 (the tests) and otherwise logs to qm.log and reads nothing.

use serde_yaml::{Mapping, Value};

use crate::config_schema as schema;
use crate::data_root;
use crate::yaml_scalar::text;

pub const STRICT_ENV: &str = "QM_CONFIG_STRICT";

pub struct ConfigReader {
    data: Mapping,
    is_mapping: bool,
    pattern: String,
    path: String,
}

impl ConfigReader {
    /// A reader over a whole config mapping.
    pub fn new(data: &Value) -> ConfigReader {
        Self::at(data, "", "")
    }

    pub fn at(data: &Value, pattern: &str, path: &str) -> ConfigReader {
        let shorthand = schema::container_at(pattern).and_then(|c| c.shorthand);
        let (data, is_mapping) = match (data, shorthand) {
            (Value::Mapping(m), _) => (m.clone(), true),
            (Value::String(_), Some(short)) => (Mapping::from_iter([(Value::String(short.into()), data.clone())]), true),
            _ => (Mapping::new(), false),
        };
        ConfigReader { data, is_mapping, pattern: pattern.into(), path: path.into() }
    }

    /// The dotted path read from, for messages ("projects.App").
    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn is_mapping(&self) -> bool {
        self.is_mapping
    }

    /// The raw value under a key the schema lists here, None when unset (a null reads as unset).
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.known(key)?;
        self.data.get(key).filter(|v| !v.is_null())
    }

    /// A reader for the mapping under a key.
    pub fn section(&self, key: &str) -> ConfigReader {
        match self.known(key) {
            Some(pattern) => Self::at(self.data.get(key).unwrap_or(&Value::Null), &pattern, &self.child_path(key)),
            None => Self::at(&Value::Null, "-", &self.child_path(key)),
        }
    }

    /// A map's entries (projects, starters, models), in config order: name and its reader.
    pub fn entries(&self) -> Vec<(String, ConfigReader)> {
        self.data
            .iter()
            .map(|(key, value)| {
                let name = text(key);
                let pattern = self.known(&name).unwrap_or_else(|| "-".into());
                (name.clone(), Self::at(value, &pattern, &self.child_path(&name)))
            })
            .collect()
    }

    fn child_path(&self, key: &str) -> String {
        if self.path.is_empty() { key.to_string() } else { format!("{}.{key}", self.path) }
    }

    fn known(&self, key: &str) -> Option<String> {
        let found = schema::child(&self.pattern, key);
        if found.is_none() {
            let message = format!("config key {} is not in the schema", self.child_path(key));
            if std::env::var(STRICT_ENV).is_ok_and(|v| v == "1") {
                panic!("{message}");
            }
            data_root::log_error("config-read", "UnknownKey", &message);
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn yaml(s: &str) -> Value {
        serde_yaml::from_str(s).unwrap()
    }

    #[test]
    fn a_shorthand_opens_into_its_mapping_and_a_non_mapping_reads_empty() {
        let projects = ConfigReader::new(&yaml("projects: { App: /code/app, Web: { root: /w, dev_server: pf } }")).section("projects");
        let entries = projects.entries();
        assert_eq!(entries[0].1.get("root"), Some(&Value::String("/code/app".into())));
        assert_eq!(entries[1].1.section("dev_server").get("command"), Some(&Value::String("pf".into())));
        assert_eq!(entries[0].1.path(), "projects.App");
        let none = ConfigReader::new(&yaml("[a]")).section("projects");
        assert!(!none.is_mapping() && none.entries().is_empty());
    }

    #[test]
    #[should_panic(expected = "projects.App.tset_db")]
    fn an_unknown_key_panics_while_strict() {
        std::env::set_var(STRICT_ENV, "1");
        let reader = ConfigReader::new(&yaml("projects: { App: /code/app }"));
        reader.section("projects").entries()[0].1.get("tset_db");
    }
}
