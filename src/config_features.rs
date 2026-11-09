//! The Settings view's projects × features grid: per project, per feature a cell `{state, value, title}`
//! saying what qm would do with the config as written. State is `on`, `off`, `inherit` (unset, a fallback
//! applies: review → default, IDE → global), or `error` / `warning` when an issue sits under the feature's
//! keys (value and title still say what is set).

use serde_json::{json, Map, Value};
use serde_yaml::Value as Yaml;

use crate::config_check::Issue;
use crate::project_config::{parse_benchmark, parse_dev_server, parse_ide, Ide, DEFAULT_REVIEW_SKILL};
use crate::yaml_scalar::{get, string, text};

/// Each feature's id and the key paths (under `projects.<name>`) whose issues mark its cell.
const FEATURES: [(&str, &[&str]); 6] = [
    ("dev_server", &["dev_server"]),
    ("test_db", &["test_db"]),
    ("review", &["review_skill"]),
    ("ships_by_release", &["pr_prerequisites"]),
    ("benchmarks", &["benchmark"]),
    ("ide", &["ide_command", "ide_label"]),
];

pub const FEATURE_IDS: [&str; 6] = ["dev_server", "test_db", "review", "ships_by_release", "benchmarks", "ide"];

/// name → feature → cell for every project in a config mapping.
pub fn features(data: &Yaml, issues: &[Issue]) -> Value {
    let empty = serde_yaml::Mapping::new();
    let top = match data {
        Yaml::Mapping(m) => m,
        _ => &empty,
    };
    let global = parse_ide(get(top, "ide_command"), get(top, "ide_label"));
    let mut out = Map::new();
    if let Some(Yaml::Mapping(projects)) = get(top, "projects") {
        for (name, value) in projects {
            let name = text(name);
            out.insert(name.clone(), project_features(&name, value, global.as_ref(), issues));
        }
    }
    Value::Object(out)
}

fn project_features(name: &str, value: &Yaml, global: Option<&Ide>, issues: &[Issue]) -> Value {
    let empty = serde_yaml::Mapping::new();
    let raw = match value {
        Yaml::Mapping(m) => m,
        _ => &empty,
    };
    let get_raw = |key: &str| if matches!(value, Yaml::Mapping(_)) { get(raw, key) } else { None };
    let server = parse_dev_server(get_raw("dev_server"));
    let bench = parse_benchmark(get_raw("benchmark"));
    let ide = parse_ide(get_raw("ide_command"), get_raw("ide_label"));
    let review = string(get_raw("review_skill"));
    let ships = matches!(get_raw("pr_prerequisites"), Some(Yaml::Bool(true)));
    let cells: Vec<(&str, Cell)> = vec![
        ("dev_server", match &server {
            Some(s) => Cell::on(format!("{} · {} mode{}", s.command, s.modes.len(), if s.modes.len() == 1 { "" } else { "s" }), format!("{}: {} (default {})", s.command, s.modes.join(", "), s.default_mode)),
            None => Cell::off(),
        }),
        ("test_db", match string(get_raw("test_db")) {
            Some(t) => Cell::on(t.clone(), t),
            None => Cell::off(),
        }),
        ("review", match review {
            Some(r) => Cell::on(r.clone(), r),
            None => Cell::new("inherit", Some("default".into()), Some(DEFAULT_REVIEW_SKILL.into())),
        }),
        ("ships_by_release", if ships { Cell::on("yes".into(), "PRs ship by release".into()) } else { Cell::off() }),
        ("benchmarks", match &bench {
            Some(b) => Cell::on(b.database.clone(), format!("{} · {}", b.database, b.skill)),
            None => Cell::off(),
        }),
        ("ide", match (&ide, global) {
            (Some(i), _) => Cell::on(i.label.clone(), i.command.join(" ")),
            (None, Some(g)) => Cell::new("inherit", Some("global".into()), Some(format!("{}: {}", g.label, g.command.join(" ")))),
            (None, None) => Cell::off(),
        }),
    ];
    let mut out = Map::new();
    for (feature, mut cell) in cells {
        let keys = FEATURES.iter().find(|(f, _)| *f == feature).map(|(_, k)| *k).unwrap_or(&[]);
        let found: Vec<&Issue> = issues.iter().filter(|i| keys.iter().any(|k| under(&i.path, &format!("projects.{name}.{k}")))).collect();
        if !found.is_empty() {
            cell.state = if found.iter().any(|i| i.level == "error") { "error" } else { "warning" };
        }
        out.insert(feature.to_string(), cell.to_json());
    }
    Value::Object(out)
}

struct Cell {
    state: &'static str,
    value: Option<String>,
    title: Option<String>,
}

impl Cell {
    fn new(state: &'static str, value: Option<String>, title: Option<String>) -> Cell {
        Cell { state, value, title }
    }
    fn on(value: String, title: String) -> Cell {
        Cell::new("on", Some(value), Some(title))
    }
    fn off() -> Cell {
        Cell::new("off", None, None)
    }
    fn to_json(&self) -> Value {
        json!({"state": self.state, "value": self.value, "title": self.title})
    }
}

fn under(path: &str, prefix: &str) -> bool {
    path == prefix || path.starts_with(&format!("{prefix}."))
}
