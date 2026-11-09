use serde_yaml::Value;

use crate::config_reader::ConfigReader;
use crate::data_root;
use crate::ruby_num::Num;
use crate::ruby_text::strip;
use crate::transcript_usage::KINDS;
use crate::yaml_scalar::{array, string, text};

pub struct Ide {
    pub label: String,
    pub command: Vec<String>,
}

/// The PRs view's Review button runs this skill when a project names none.
pub const DEFAULT_REVIEW_SKILL: &str = "/code-review";

impl Ide {
    pub const DEFAULT_LABEL: &'static str = "IDE";
    /// What "no IDE" messages tell the user to run.
    pub const CONFIG_COMMAND: &'static str = "qm config set ide_command '[open, -a, <IDE>, PATH]'";

    /// The command with the checkout's path in: an element that is exactly `PATH` becomes the path, `PATH`
    /// inside a longer element (a `sh -c` script) the shell-escaped path.
    pub fn argv(&self, path: &str) -> Vec<String> {
        self.command.iter().map(|arg| if arg == "PATH" { path.to_string() } else { arg.replace("PATH", &shell_escape(path)) }).collect()
    }
}

/// `Shellwords.escape`.
pub fn shell_escape(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '\n' => out.push_str("'\n'"),
            c if c.is_ascii_alphanumeric() || "_-.,:+/@".contains(c) => out.push(c),
            c => {
                out.push('\\');
                out.push(c);
            }
        }
    }
    out
}

#[derive(Clone)]
pub struct DevServer {
    pub command: String,
    pub modes: Vec<String>,
    pub default_mode: String,
    pub status_url: Option<String>,
    pub state_file: Option<String>,
}

/// Benchmark runs (docs/areas/benchmarks.md): the Postgres template a run reads (or clones), the skill
/// folder the planner follows, and extra prompt lines.
#[derive(Clone)]
pub struct Benchmark {
    pub database: String,
    pub skill: String,
    pub notes: Option<String>,
}

impl Benchmark {
    pub fn read_only_url(&self) -> String {
        format!("postgres:///{}?options=-c%20default_transaction_read_only%3Don", self.database)
    }
}

pub struct ProjectSettings {
    pub name: String,
    pub root: String,
    pub dev_server: Option<DevServer>,
    pub ide: Option<Ide>,
    pub pr_prerequisites: bool,
    pub test_db: Option<String>,
    /// The PRs view's Review button runs this skill (default `/code-review`).
    pub review_skill: String,
    /// Whether the project names its own review skill (else the default shows as inherited).
    pub review_skill_set: bool,
    pub benchmark: Option<Benchmark>,
}

/// Why config.yml read as an empty config.
pub enum LoadFailure {
    Syntax(String),
    NotMapping,
}

/// config.yml's project side, read through `ConfigReader`; an unreadable or malformed file reads as no
/// projects.
pub struct ProjectConfig {
    projects: Vec<ProjectSettings>,
    ide: Option<Ide>,
    default_name: String,
    default_raw: Value,
    starters: Vec<Starter>,
    prices: Vec<(String, Vec<(usize, Num)>)>,
    overview_artifact: Option<String>,
    automations_token_source: Option<String>,
    local_automations: LocalAutomations,
    failure: Option<LoadFailure>,
}

/// The local automations' tick settings, unset ones at their defaults (`automations.local_*`).
#[derive(Clone, Debug)]
pub struct LocalAutomations {
    pub paused: bool,
    pub max_running: f64,
    pub hold_five_hour: f64,
    pub hold_seven_day: f64,
}

/// A loose-chat starter (config.yml `loose_starters:`): its prompt has the chat load something first.
#[derive(Clone)]
pub struct Starter {
    pub key: String,
    pub label: String,
    pub prompt: String,
}

pub(crate) fn parse_ide(command: Option<&Value>, label: Option<&Value>) -> Option<Ide> {
    let items = match command {
        Some(Value::Sequence(items)) if !items.is_empty() => items,
        _ => return None,
    };
    if !items.iter().all(|a| matches!(a, Value::String(_) | Value::Number(_))) {
        return None;
    }
    let argv: Vec<String> = items.iter().map(text).collect();
    if strip(&argv[0]).is_empty() || argv.iter().all(|a| !a.contains("PATH")) {
        return None;
    }
    Some(Ide { label: string(label).unwrap_or_else(|| Ide::DEFAULT_LABEL.to_string()), command: argv })
}

fn expand(path: Option<&Value>) -> Option<String> {
    string(path).map(|p| data_root::expand_path(&p).to_string_lossy().into_owned())
}

pub(crate) fn parse_dev_server(server: &ConfigReader) -> Option<DevServer> {
    let command = string(server.get("command"))?;
    let default = string(server.get("default_mode"));
    let mut modes: Vec<String> = array(server.get("modes")).into_iter().map(text).filter(|m| !m.is_empty()).collect();
    if modes.is_empty() {
        modes = vec![default.clone().unwrap_or_else(|| "default".to_string())];
    }
    let default_mode = match &default {
        Some(d) if modes.contains(d) => d.clone(),
        _ => modes[0].clone(),
    };
    Some(DevServer { command, modes, default_mode, status_url: string(server.get("status_url")), state_file: expand(server.get("state_file")) })
}

impl ProjectSettings {
    /// A project qm can place (it has a root).
    fn read(name: &str, project: &ConfigReader) -> Option<ProjectSettings> {
        Some(Self::read_any(name, project)).filter(|s| !s.root.is_empty())
    }

    /// Whatever the project's entry sets, root or not (the Settings grid shows projects without one).
    pub(crate) fn read_any(name: &str, project: &ConfigReader) -> ProjectSettings {
        ProjectSettings {
            name: name.to_string(),
            root: expand(project.get("root")).unwrap_or_default(),
            dev_server: parse_dev_server(&project.section("dev_server")),
            ide: parse_ide(project.get("ide_command"), project.get("ide_label")),
            pr_prerequisites: matches!(project.get("pr_prerequisites"), Some(Value::Bool(true))),
            test_db: string(project.get("test_db")),
            review_skill: string(project.get("review_skill")).unwrap_or_else(|| DEFAULT_REVIEW_SKILL.to_string()),
            review_skill_set: string(project.get("review_skill")).is_some(),
            benchmark: parse_benchmark(&project.section("benchmark")),
        }
    }
}

/// The command that sets one of a project's keys, for "not configured" messages:
/// `qm config set projects.App.test_db <command>`.
pub fn config_command(project: &str, key: &str, value: &str) -> String {
    format!("qm config set projects.{project}.{key} {value}")
}

/// What "no project has a dev server" messages tell the user to run.
pub const DEV_SERVER_ANYWHERE: &str = "qm config set projects.<project>.dev_server.command <command>";

/// Both database and skill, or no benchmarks.
pub(crate) fn parse_benchmark(bench: &ConfigReader) -> Option<Benchmark> {
    let database = string(bench.get("database"))?;
    let skill = expand(bench.get("skill"))?;
    if database.is_empty() || !database.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return None;
    }
    Some(Benchmark { database, skill, notes: string(bench.get("notes")) })
}

impl ProjectConfig {
    pub fn current() -> ProjectConfig {
        let text = std::fs::read_to_string(data_root::config_file()).unwrap_or_default();
        Self::parse(&text)
    }

    pub fn parse(source: &str) -> ProjectConfig {
        let (data, failure) = match serde_yaml::from_str::<Value>(source) {
            Ok(v @ Value::Mapping(_)) => (v, None),
            Ok(Value::Null) => (Value::Null, None),
            Ok(_) => (Value::Null, Some(LoadFailure::NotMapping)),
            Err(e) => (Value::Null, Some(LoadFailure::Syntax(e.to_string()))),
        };
        let config = ConfigReader::new(&data);
        let projects = config.section("projects").entries().into_iter().filter_map(|(name, p)| ProjectSettings::read(&name, &p)).collect();
        let default_name = match config.get("default_project") {
            Some(Value::String(t)) => t.clone(),
            _ => String::new(),
        };
        let mut starters: Vec<Starter> = vec![];
        for (key, starter) in config.section("loose_starters").entries() {
            let Some(Value::String(prompt)) = starter.get("prompt").filter(|_| starter.is_mapping()) else { continue };
            if strip(prompt).is_empty() {
                continue;
            }
            let label = match starter.get("label") {
                Some(Value::String(l)) if !l.is_empty() => l.clone(),
                _ => key.clone(),
            };
            let starter = Starter { key: key.clone(), label, prompt: strip(prompt).to_string() };
            match starters.iter_mut().find(|s| s.key == key) {
                Some(existing) => *existing = starter,
                None => starters.push(starter),
            }
        }
        let prices = config
            .section("prices")
            .entries()
            .into_iter()
            .filter(|(_, fields)| fields.is_mapping())
            .map(|(model, fields)| {
                let numbers = KINDS.iter().enumerate().filter_map(|(i, kind)| if let Some(Value::Number(n)) = fields.get(kind) { Some((i, Num::from_yaml(n))) } else { None });
                (model, numbers.collect())
            })
            .collect();
        let automations = config.section("automations");
        let number = |key: &str, default: f64| match automations.get(key) {
            Some(Value::Number(n)) => n.as_f64().unwrap_or(default),
            _ => default,
        };
        let local_automations = LocalAutomations {
            paused: automations.get("local_paused") == Some(&Value::Bool(true)),
            max_running: number("local_max_running", 2.0),
            hold_five_hour: number("local_hold_five_hour", 80.0),
            hold_seven_day: number("local_hold_seven_day", 90.0),
        };
        ProjectConfig {
            projects,
            ide: parse_ide(config.get("ide_command"), config.get("ide_label")),
            default_name,
            default_raw: config.get("default_project").cloned().unwrap_or(Value::Null),
            starters,
            prices,
            overview_artifact: string(config.get("overview_artifact")),
            automations_token_source: string(automations.get("token_source")),
            local_automations,
            failure,
        }
    }

    /// The `prices:` overrides: per model, the kind index (`transcript_usage::KINDS`) and its number.
    pub fn prices(&self) -> &[(String, Vec<(usize, Num)>)] {
        &self.prices
    }

    /// The published phone page's claude.ai URL, None while unset.
    /// Where RoutinesClient gets a claude.ai login (`claude_code`); None while automations are off.
    pub fn automations_token_source(&self) -> Option<&str> {
        self.automations_token_source.as_deref()
    }

    pub fn overview_artifact(&self) -> Option<&str> {
        self.overview_artifact.as_deref()
    }

    /// The local automations' tick settings.
    pub fn local_automations(&self) -> &LocalAutomations {
        &self.local_automations
    }

    /// Why the file read as an empty config, None when it parsed.
    pub fn failure(&self) -> Option<&LoadFailure> {
        self.failure.as_ref()
    }

    /// `default_project:` as written, null when unset.
    pub fn default_project_raw(&self) -> &Value {
        &self.default_raw
    }

    /// key → starter, in config order.
    pub fn loose_starters(&self) -> &[Starter] {
        &self.starters
    }

    /// Where an issue number with no project goes: `default_project:` when it names a configured project,
    /// else the first one.
    pub fn default_project(&self) -> Option<String> {
        if self.projects.iter().any(|p| p.name == self.default_name) {
            return Some(self.default_name.clone());
        }
        self.projects.first().map(|p| p.name.clone())
    }

    /// One dev server serves one checkout at a time across projects: the first project that configures one.
    pub fn dev_server(&self) -> Option<&DevServer> {
        self.projects.iter().find_map(|p| p.dev_server.as_ref())
    }

    /// name → root, in config order.
    pub fn roots(&self) -> Vec<(&str, &str)> {
        self.projects.iter().map(|p| (p.name.as_str(), p.root.as_str())).collect()
    }

    pub fn settings(&self, project: Option<&str>) -> Option<&ProjectSettings> {
        let name = project?;
        self.projects.iter().find(|p| p.name == name)
    }

    /// `ProjectConfig#settings(project).review_skill`: a project's own, else the default.
    pub fn review_skill(&self, project: Option<&str>) -> String {
        self.settings(project).map(|s| s.review_skill.clone()).unwrap_or_else(|| DEFAULT_REVIEW_SKILL.to_string())
    }

    /// Every project name, in config order.
    pub fn project_names(&self) -> Vec<String> {
        self.projects.iter().map(|p| p.name.clone()).collect()
    }

    /// Every dev-server command config.yml configures, once each.
    pub fn dev_server_commands(&self) -> Vec<String> {
        let mut out: Vec<String> = vec![];
        for p in &self.projects {
            if let Some(d) = &p.dev_server {
                if !out.contains(&d.command) {
                    out.push(d.command.clone());
                }
            }
        }
        out
    }

    /// The project's own IDE, else the global one.
    pub fn ide(&self, project: Option<&str>) -> Option<&Ide> {
        self.settings(project).and_then(|s| s.ide.as_ref()).or(self.ide.as_ref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_broken_config_reads_as_no_projects() {
        assert!(ProjectConfig::parse("projects: [unclosed").roots().is_empty());
        assert!(ProjectConfig::parse("- just\n- a list").roots().is_empty());
        assert!(ProjectConfig::parse("").roots().is_empty());
    }

    #[test]
    fn projects_keep_their_order_and_need_a_root() {
        let c = ProjectConfig::parse("projects:\n  b: /srv/b\n  a:\n    root: /srv/a\n  none:\n    dev_server: x\n");
        assert_eq!(c.roots(), vec![("b", "/srv/b"), ("a", "/srv/a")]);
    }

    #[test]
    fn dev_server_modes_and_default() {
        let c = ProjectConfig::parse("projects:\n  p:\n    root: /r\n    dev_server:\n      command: ds\n      modes: [dev, tunnel]\n      default_mode: nope\n  q:\n    root: /q\n    dev_server: plain\n");
        let p = c.settings(Some("p")).unwrap().dev_server.as_ref().unwrap();
        assert_eq!((p.command.as_str(), p.default_mode.as_str()), ("ds", "dev"));
        let q = c.settings(Some("q")).unwrap().dev_server.as_ref().unwrap();
        assert_eq!((q.command.as_str(), q.default_mode.as_str()), ("plain", "default"));
    }

    #[test]
    fn ide_needs_a_path_placeholder_and_falls_back_to_the_global_one() {
        let c = ProjectConfig::parse("ide_command: [open, PATH]\nide_label: Glob\nprojects:\n  p:\n    root: /r\n    ide_command: [code, PATH]\n    ide_label: Mine\n  q:\n    root: /q\n    ide_command: [code]\n");
        assert_eq!(c.ide(Some("p")).unwrap().label, "Mine");
        assert_eq!(c.ide(Some("q")).unwrap().label, "Glob");
        assert_eq!(c.ide(None).unwrap().label, "Glob");
        assert!(ProjectConfig::parse("ide_command: [code]").ide(None).is_none());
    }

    #[test]
    fn pr_prerequisites_must_be_literally_true() {
        let c = ProjectConfig::parse("projects:\n  p:\n    root: /r\n    pr_prerequisites: true\n  q:\n    root: /q\n    pr_prerequisites: 'yes'\n");
        assert!(c.settings(Some("p")).unwrap().pr_prerequisites);
        assert!(!c.settings(Some("q")).unwrap().pr_prerequisites);
    }
}
