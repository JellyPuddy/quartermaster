//! The Settings view's projects × features grid: per project, per feature a cell `{state, value, title}`
//! saying what qm would do with the config as written. State is `on`, `off`, `inherit` (unset, a fallback
//! applies: review → default, IDE → global), or `error` / `warning` when an issue sits under the feature's
//! keys (value and title still say what is set).

use serde_json::{json, Map, Value};
use serde_yaml::Value as Yaml;

use crate::config_check::Issue;
use crate::config_reader::ConfigReader;
use crate::project_config::{parse_ide, Ide, ProjectSettings};

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
    let config = ConfigReader::new(data);
    let global = parse_ide(config.get("ide_command"), config.get("ide_label"));
    let mut out = Map::new();
    for (name, project) in config.section("projects").entries() {
        let settings = ProjectSettings::read_any(&name, &project);
        out.insert(name.clone(), project_features(&settings, global.as_ref(), issues));
    }
    Value::Object(out)
}

fn project_features(settings: &ProjectSettings, global: Option<&Ide>, issues: &[Issue]) -> Value {
    let cells: Vec<(&str, Cell)> = vec![
        ("dev_server", match &settings.dev_server {
            Some(s) => Cell::on(format!("{} · {} mode{}", s.command, s.modes.len(), if s.modes.len() == 1 { "" } else { "s" }), format!("{}: {} (default {})", s.command, s.modes.join(", "), s.default_mode)),
            None => Cell::off(),
        }),
        ("test_db", match &settings.test_db {
            Some(t) => Cell::on(t.clone(), t.clone()),
            None => Cell::off(),
        }),
        ("review", if settings.review_skill_set {
            Cell::on(settings.review_skill.clone(), settings.review_skill.clone())
        } else {
            Cell::new("inherit", Some("default".into()), Some(settings.review_skill.clone()))
        }),
        ("ships_by_release", if settings.pr_prerequisites { Cell::on("yes".into(), "PRs ship by release".into()) } else { Cell::off() }),
        ("benchmarks", match &settings.benchmark {
            Some(b) => Cell::on(b.database.clone(), format!("{} · {}", b.database, b.skill)),
            None => Cell::off(),
        }),
        ("ide", match (&settings.ide, global) {
            (Some(i), _) => Cell::on(i.label.clone(), i.command.join(" ")),
            (None, Some(g)) => Cell::new("inherit", Some("global".into()), Some(format!("{}: {}", g.label, g.command.join(" ")))),
            (None, None) => Cell::off(),
        }),
    ];
    let mut out = Map::new();
    for (feature, mut cell) in cells {
        let keys = FEATURES.iter().find(|(f, _)| *f == feature).map(|(_, k)| *k).unwrap_or(&[]);
        let found: Vec<&Issue> = issues.iter().filter(|i| keys.iter().any(|k| under(&i.path, &format!("projects.{}.{k}", settings.name)))).collect();
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
