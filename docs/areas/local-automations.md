# Local automations

**Code:** `lib/quartermaster/tick_installer.rb`
**Tests:** `test/tick_installer_test.rb`
**Depends on:** [automations](automations.md) (the shared store, item and GUI tab), [gui-shell](gui-shell.md) (`CommandRunner`)

## What it does

Local automations (`runner: local`) are scheduled Claude Code runs on this machine, driven by
qm. The store, the `kind: automation` item and the GUI tab they share with cloud routines live
on [automations](automations.md); this page owns what only local runs have.

**Tick installer** — `TickInstaller` owns the one LaunchAgent that runs `qm automation tick`
every 300 s. Its label is `com.quartermaster.automation-tick`; its plist lives at
`~/Library/LaunchAgents/<label>.plist` (directory injectable). The plist (`plist`, written by
hand, values XML-escaped) holds `ProgramArguments` = the realpath of the `quartermaster`
launcher, `automation`, `tick`; `StartInterval` 300; `RunAtLoad` false; stdout and stderr both
appended to `<root>/automations/tick.log`; and `EnvironmentVariables` with the installing
process's `PATH` (launchd's own PATH has no asdf shims, Homebrew, tmux or claude) plus
`QM_ROOT` when it is set. `install` creates the log's directory, writes the plist atomically,
runs `launchctl bootout gui/<uid>/<label>` (its failure ignored, so a reinstall picks up a
changed plist) and then `launchctl bootstrap gui/<uid> <plist>`; a failed bootstrap removes the
plist and raises an `ArgumentError` carrying launchctl's message. `uninstall` boots the label
out and removes the plist, whether or not launchd still held it. `installed?` is whether the
plist exists.

## Rules

- The LaunchAgent is installed or removed only on the user's explicit command or button, never
  as a side effect of anything else.
- Every `launchctl` call goes through `CommandRunner`; tests pass a stub runner and a temp
  LaunchAgents directory and never reach real launchctl.
- `installed?` reads only the plist file; it never asks launchctl.

## Data

- `automations/tick.log` — the tick's stdout and stderr, appended by launchd.
- `~/Library/LaunchAgents/com.quartermaster.automation-tick.plist` — outside the data root.
