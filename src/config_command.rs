//! `qm config`: config.yml by dotted path, through `ConfigFile`, so it refuses exactly what the Settings view
//! refuses. Errors go to stderr, exit 1 and write nothing; warnings go to stderr and the write happens.

use serde_yaml::{Mapping, Value};

use crate::cli_format::puts;
use crate::config_check::Issue;
use crate::config_emit::dump;
use crate::config_file::{parse_value, ConfigFile, WriteError};
use crate::config_schema as schema;
use crate::data_root;
use crate::outcome::{abort, done, Outcome};
use crate::work_item::WorkItem;
use crate::yaml_scalar::text;

const USAGE: &str = "usage: qm config get [PATH] | set PATH VALUE | unset PATH | path  (PATH dotted, e.g. projects.App.test_db; VALUE is YAML: [dev, ngrok], true, 4)";

pub fn run(argv: &[String]) -> Outcome {
    let (sub, path, rest) = (argv.first().map(String::as_str), argv.get(1), argv.get(2..).unwrap_or(&[]));
    match (sub, path) {
        (Some("path"), _) => done(puts(&data_root::config_file().to_string_lossy())),
        (Some("get"), path) => get(path.map(String::as_str)),
        (Some("set"), Some(path)) if !rest.is_empty() => set(path, crate::config_file::typed_for(path, parse_value(&rest.join(" ")))),
        (Some("unset"), Some(path)) => unset(path),
        _ => abort(USAGE),
    }
}

fn issue_line(i: &Issue) -> String {
    if i.path.is_empty() { i.message.clone() } else { format!("{}: {}", i.path, i.message) }
}

fn refusal(errors: &[Issue]) -> Outcome {
    Outcome::Done { code: 1, stdout: String::new(), stderr: errors.iter().map(|i| format!("qm: error: {}\n", issue_line(i))).collect() }
}

fn unknown(message: String) -> Outcome {
    abort(&format!("qm: {message}"))
}

/// A scalar prints bare (a shell can use it); a subtree as YAML; an unset key prints nothing and exits 1.
fn get(path: Option<&str>) -> Outcome {
    let config = ConfigFile::load(&data_root::config_file());
    let Some(path) = path.filter(|p| !p.is_empty()) else { return done(config.text) };
    if !schema::known(path) {
        return unknown(format!("unknown config key: {path}"));
    }
    if config.parse_error.is_some() {
        return refusal(&config.errors());
    }
    match config.get(path) {
        None | Some(Value::Null) => Outcome::Done { code: 1, stdout: String::new(), stderr: String::new() },
        Some(v @ (Value::Mapping(_) | Value::Sequence(_))) => done(dump(&v)),
        Some(v) => done(puts(&text(&v))),
    }
}

fn set(path: &str, value: Value) -> Outcome {
    let mut config = ConfigFile::load(&data_root::config_file());
    if let Err(e) = config.set(path, value.clone()) {
        return unknown(e);
    }
    let warnings = match write(&mut config, path) {
        Ok(w) => w,
        Err(refused) => return refused,
    };
    Outcome::Done { code: 0, stdout: dump(&Value::Mapping(Mapping::from_iter([(Value::String(path.into()), value)]))), stderr: warnings }
}

fn unset(path: &str) -> Outcome {
    let mut config = ConfigFile::load(&data_root::config_file());
    let present = config.parse_error.is_some() || config.get(path).is_some_and(|v| !v.is_null());
    if let Err(e) = config.unset(path) {
        return unknown(e);
    }
    if !present {
        return done(puts(&format!("{path} is not set")));
    }
    let mut warnings = match write(&mut config, path) {
        Ok(w) => w,
        Err(refused) => return refused,
    };
    if schema::container_of(path).is_some_and(|c| c.pattern == "projects.*") {
        let name = schema::segments(path).last().copied().unwrap_or("");
        let count = WorkItem::all().map(|items| items.iter().filter(|i| i.project().as_deref() == Some(name)).count()).unwrap_or(0);
        if count > 0 {
            let have = if count == 1 { "1 work item still has".to_string() } else { format!("{count} work items still have") };
            warnings.push_str(&format!("qm: warning: {have} project {name} (qm move SLUG PROJECT reassigns one)\n"));
        }
    }
    Outcome::Done { code: 0, stdout: String::new(), stderr: warnings }
}

/// Writes, or refuses with every error; the warnings about the changed path come back as stderr text.
fn write(config: &mut ConfigFile, path: &str) -> Result<String, Outcome> {
    let errors = config.errors();
    if !errors.is_empty() {
        return Err(refusal(&errors));
    }
    match config.write(None) {
        Ok(_) => {}
        Err(WriteError::Invalid(found)) => return Err(refusal(&found)),
        Err(e) => return Err(abort(&format!("qm: {}", e.message()))),
    }
    Ok(config.warnings().iter().filter(|i| related(&i.path, path)).map(|i| format!("qm: warning: {}\n", issue_line(i))).collect())
}

fn related(issue_path: &str, path: &str) -> bool {
    let under = |a: &str, b: &str| a == b || a.starts_with(&format!("{b}."));
    under(issue_path, path) || under(path, issue_path)
}
