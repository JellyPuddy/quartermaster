//! The LaunchAgent that runs the tick: its plist, and installing or removing it. launchctl is a stand-in that
//! records its arguments and fails on demand; the agents directory is a temp dir. Nothing touches launchd.

use quartermaster::tick_installer::{TickInstaller, LABEL};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

struct World {
    dir: tempfile::TempDir,
}

impl World {
    fn new() -> World {
        let w = World { dir: tempfile::tempdir().unwrap() };
        std::fs::create_dir_all(w.agents()).unwrap();
        let script = "#!/bin/sh\nd=$(dirname \"$0\")\nprintf '%s ' \"$@\" >> \"$d/launchctl.log\"\necho >> \"$d/launchctl.log\"\nif [ -f \"$d/fail-$1\" ]; then cat \"$d/fail-$1\" >&2; exit 1; fi\n";
        std::fs::write(w.launchctl(), script).unwrap();
        std::fs::set_permissions(w.launchctl(), std::fs::Permissions::from_mode(0o755)).unwrap();
        w
    }

    fn agents(&self) -> PathBuf {
        self.dir.path().join("agents")
    }

    fn launchctl(&self) -> PathBuf {
        self.dir.path().join("launchctl")
    }

    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("launchctl.log")).unwrap_or_default().lines().map(|l| l.trim().to_string()).collect()
    }

    fn installer(&self, path: &str, qm_root: Option<&str>, root: &Path) -> TickInstaller {
        TickInstaller::new().with_agents_dir(&self.agents()).with_environment(path, qm_root).with_root(root).with_uid(501).with_program("/opt/qm/quartermaster").with_launchctl(&self.launchctl().to_string_lossy())
    }

    fn plist_file(&self) -> PathBuf {
        self.agents().join(format!("{LABEL}.plist"))
    }
}

const EXPECTED: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.quartermaster.automation-tick</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/qm/quartermaster</string>
    <string>automation</string>
    <string>tick</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/qm root/automations/tick.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/qm root/automations/tick.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin</string>
    <key>QM_ROOT</key>
    <string>/tmp/qm root</string>
  </dict>
</dict>
</plist>
"#;

#[test]
fn the_plist_runs_the_launcher_every_five_minutes_with_the_installing_path_and_root() {
    let w = World::new();
    assert_eq!(w.installer("/opt/homebrew/bin:/usr/bin", Some("/tmp/qm root"), Path::new("/tmp/qm root")).plist(), EXPECTED);
}

#[test]
fn without_qm_root_set_the_plist_carries_only_path() {
    let w = World::new();
    let plist = w.installer("/usr/bin", None, Path::new("/tmp/qm root")).plist();
    assert!(!plist.contains("QM_ROOT"));
    assert!(plist.contains("<key>PATH</key>\n    <string>/usr/bin</string>\n  </dict>"));
}

#[test]
fn values_are_xml_escaped() {
    let w = World::new();
    let plist = w.installer("/a&b:<c>", None, Path::new("/r&d")).plist();
    assert!(plist.contains("<string>/a&amp;b:&lt;c&gt;</string>"));
    assert!(plist.contains("<string>/r&amp;d/automations/tick.log</string>"));
}

#[test]
fn the_program_defaults_to_the_launchers_realpath() {
    let launcher = std::fs::canonicalize(concat!(env!("CARGO_MANIFEST_DIR"), "/quartermaster")).unwrap();
    let plist = TickInstaller::new().plist();
    assert!(plist.contains(&format!("<string>{}</string>\n    <string>automation</string>", launcher.display())), "{plist}");
}

#[test]
fn install_writes_the_plist_and_bootstraps_it_in_the_users_gui_domain() {
    let w = World::new();
    let root = w.dir.path().join("elsewhere");
    let tick = w.installer("/usr/bin", None, &root);
    assert!(!tick.installed());
    tick.install().unwrap();
    assert_eq!(std::fs::read_to_string(w.plist_file()).unwrap(), tick.plist());
    assert!(tick.installed());
    assert!(root.join("automations").is_dir(), "launchd needs the log's directory");
    assert_eq!(w.calls(), ["bootout gui/501/com.quartermaster.automation-tick".to_string(), format!("bootstrap gui/501 {}", w.plist_file().display())]);
}

#[test]
fn a_failed_bootstrap_leaves_no_plist_and_says_why() {
    let w = World::new();
    std::fs::write(w.dir.path().join("fail-bootstrap"), "Bootstrap failed: 5: Input/output error\n").unwrap();
    let tick = w.installer("/usr/bin", None, w.dir.path());
    let error = tick.install().unwrap_err();
    assert!(error.message.contains("Bootstrap failed: 5"), "{}", error.message);
    assert!(!tick.installed());
}

#[test]
fn uninstall_boots_out_and_removes_the_plist() {
    let w = World::new();
    let tick = w.installer("/usr/bin", None, w.dir.path());
    tick.install().unwrap();
    std::fs::remove_file(w.dir.path().join("launchctl.log")).unwrap();
    tick.uninstall().unwrap();
    assert!(!tick.installed());
    assert_eq!(w.calls(), ["bootout gui/501/com.quartermaster.automation-tick"]);
}

#[test]
fn uninstall_removes_the_plist_even_when_launchd_no_longer_has_it() {
    let w = World::new();
    std::fs::write(w.dir.path().join("fail-bootout"), "Boot-out failed: 3: No such process\n").unwrap();
    let tick = w.installer("/usr/bin", None, w.dir.path());
    std::fs::write(w.plist_file(), "stale").unwrap();
    tick.uninstall().unwrap();
    assert!(!tick.installed());
    tick.uninstall().unwrap();
}
