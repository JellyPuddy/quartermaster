//! The LaunchAgent that runs `qm automation tick` every five minutes: its plist text, and installing or
//! removing it in the user's launchd GUI domain. Only an explicit install or uninstall changes anything; every
//! launchctl call goes through the command runner.

use std::path::{Path, PathBuf};

use crate::error::{QmError, Res};
use crate::{atomic_file, command_runner, data_root, delegate};

pub const LABEL: &str = "com.quartermaster.automation-tick";
pub const INTERVAL: u32 = 300;

pub struct TickInstaller {
    agents_dir: PathBuf,
    path_env: String,
    qm_root: Option<String>,
    root: PathBuf,
    uid: u32,
    program: String,
    launchctl: String,
}

/// `~/Library/LaunchAgents`.
pub fn agents_dir() -> PathBuf {
    data_root::expand_path("~/Library/LaunchAgents")
}

fn escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn string(value: &str) -> String {
    format!("<string>{}</string>", escape(value))
}

impl TickInstaller {
    /// Installs for this process: its PATH and QM_ROOT, the user's agents directory, the launcher's realpath.
    pub fn new() -> TickInstaller {
        let launcher = std::fs::canonicalize(delegate::checkout_launcher()).unwrap_or_else(|_| delegate::checkout_launcher());
        TickInstaller {
            agents_dir: agents_dir(),
            path_env: std::env::var("PATH").unwrap_or_default(),
            qm_root: std::env::var("QM_ROOT").ok().map(|_| data_root::root().to_string_lossy().into_owned()),
            root: data_root::root(),
            // SAFETY: getuid has no preconditions.
            uid: unsafe { libc::getuid() },
            program: launcher.to_string_lossy().into_owned(),
            launchctl: "launchctl".into(),
        }
    }

    pub fn with_agents_dir(mut self, dir: &Path) -> TickInstaller {
        self.agents_dir = dir.to_path_buf();
        self
    }

    /// The PATH the agent runs with, and the QM_ROOT it carries (none: the live root).
    pub fn with_environment(mut self, path: &str, qm_root: Option<&str>) -> TickInstaller {
        self.path_env = path.to_string();
        self.qm_root = qm_root.map(String::from);
        self
    }

    pub fn with_root(mut self, root: &Path) -> TickInstaller {
        self.root = root.to_path_buf();
        self
    }

    pub fn with_uid(mut self, uid: u32) -> TickInstaller {
        self.uid = uid;
        self
    }

    pub fn with_program(mut self, program: &str) -> TickInstaller {
        self.program = program.to_string();
        self
    }

    /// The launchctl to run (a stand-in in tests).
    pub fn with_launchctl(mut self, program: &str) -> TickInstaller {
        self.launchctl = program.to_string();
        self
    }

    pub fn plist_path(&self) -> PathBuf {
        self.agents_dir.join(format!("{LABEL}.plist"))
    }

    pub fn log_path(&self) -> PathBuf {
        self.root.join("automations").join("tick.log")
    }

    pub fn installed(&self) -> bool {
        self.plist_path().exists()
    }

    pub fn plist(&self) -> String {
        let log = self.log_path().to_string_lossy().into_owned();
        let mut environment = format!("    <key>PATH</key>\n    {}\n", string(&self.path_env));
        if let Some(root) = &self.qm_root {
            environment.push_str(&format!("    <key>QM_ROOT</key>\n    {}\n", string(root)));
        }
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  {label}\n  <key>ProgramArguments</key>\n  <array>\n    {program}\n    {automation}\n    {tick}\n  </array>\n  <key>StartInterval</key>\n  <integer>{INTERVAL}</integer>\n  <key>RunAtLoad</key>\n  <false/>\n  <key>StandardOutPath</key>\n  {out}\n  <key>StandardErrorPath</key>\n  {out}\n  <key>EnvironmentVariables</key>\n  <dict>\n{environment}  </dict>\n</dict>\n</plist>\n",
            label = string(LABEL),
            program = string(&self.program),
            automation = string("automation"),
            tick = string("tick"),
            out = string(&log),
        )
    }

    /// A label launchd already holds is booted out first, so a reinstall picks up a changed plist; a failed
    /// bootstrap leaves no plist behind.
    pub fn install(&self) -> Res<()> {
        std::fs::create_dir_all(&self.agents_dir)?;
        std::fs::create_dir_all(self.log_path().parent().unwrap_or(Path::new(".")))?;
        atomic_file::write(&self.plist_path(), &self.plist())?;
        self.launchctl(&["bootout", &self.target()]);
        let plist = self.plist_path().to_string_lossy().into_owned();
        let result = self.launchctl(&["bootstrap", &self.domain(), &plist]);
        if result.success {
            return Ok(());
        }
        let _ = std::fs::remove_file(self.plist_path());
        Err(QmError::argument(format!("launchctl bootstrap failed: {}", crate::ruby_text::strip(&result.err))))
    }

    /// launchd may no longer hold the label; the plist goes either way.
    pub fn uninstall(&self) -> Res<()> {
        self.launchctl(&["bootout", &self.target()]);
        match std::fs::remove_file(self.plist_path()) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    fn domain(&self) -> String {
        format!("gui/{}", self.uid)
    }

    fn target(&self) -> String {
        format!("{}/{LABEL}", self.domain())
    }

    fn launchctl(&self, args: &[&str]) -> command_runner::CmdResult {
        let argv: Vec<&str> = std::iter::once(self.launchctl.as_str()).chain(args.iter().copied()).collect();
        command_runner::call(&argv)
    }
}

impl Default for TickInstaller {
    fn default() -> Self {
        Self::new()
    }
}
