# Rust port

**Code:** `Cargo.toml`, `src/cli.rs`, `src/clock.rs`, `src/data_root.rs`, `src/delegate.rs`, `src/error.rs`, `src/feature_use.rs`, `src/front_edit.rs`, `src/git.rs`, `src/hook.rs`, `src/main.rs`, `src/note.rs`, `src/project_config.rs`, `src/project_map.rs`, `src/ruby_text.rs`, `src/session_log.rs`, `src/session_rows.rs`, `src/work_item.rs`, `src/yaml_scalar.rs`, `src/config_seed.yml`
**Tests:** `tests/characterization.rs`, `tests/interop.rs`, `tests/fixtures/golden/linked_context.txt`, and the unit tests inside the `src` files
**Depends on:** [capture](capture.md), [work-items](work-items.md), [cli](cli.md)

## What it does

`qm` is being ported from Ruby to Rust one area at a time. The Rust binary (`target/debug/qm`,
crate `quartermaster`) serves the commands it has ported and `exec`s the Ruby launcher
`./quartermaster` — arguments and stdin untouched — for every other word, so any command works
from either binary while the port is partial. `QM_RUBY_LAUNCHER` overrides where the fallback
looks; the default is the checkout the binary was built from.

Ported so far: the SessionStart and SessionEnd hooks (the same events, the same injected
context, byte for byte), `sessions`, `inbox` and `dismiss`, feature-use recording for those, the
session log, config.yml's project side, the project map, and a read-only work-item reader
(sections, notes, the injected digest). The hooks make exactly three work-item writes — attach
a session, detach it from an item when its transcript never existed, record a temp branch — and
`WorkItem` makes each as a targeted edit of that key's front-matter lines, under the same
`work-items/.lock` flock the Ruby side takes. Every other key and the body stay byte for byte.

`./quartermaster`, the `~/bin` symlinks and the hook registrations still point at Ruby. Switching
a hook to the Rust binary is the user's edit of `~/.claude/settings.json`; `qm install-hooks`
still prints the Ruby snippet.

## How it is tested

`tests/characterization.rs` is black-box: it runs the executable `QM_BIN` names (default the
Ruby launcher) against a throwaway `QM_ROOT` and compares stdout, stderr, exit codes and the
files written. The same file passes against Ruby and against Rust:
`QM_BIN=$PWD/target/debug/qm cargo test --test characterization`. The hook contexts and the
seeded `config.yml` are golden files in `tests/fixtures/golden/`, generated from Ruby with
`QM_UPDATE_GOLDEN=1` — regenerate only against the Ruby launcher. `tests/interop.rs` mixes the
two binaries on one data root. A command is ported only after the characterization suite
covers it and passes on both.

## Rules

- **No behavior change in a port**: output, exit codes and file contents match Ruby exactly,
  including its quirks; a bug found on the way is fixed in Ruby first, then ported.
- **Hooks never block or break a session**: errors are logged to `qm.log` and the exit is 0;
  only SessionStart prints.
- **A front-matter edit re-parses its own result and refuses to write** if the key is not a
  block list or the text no longer parses, rather than risk the user's work item.
- **Append-only stays append-only**: `sessions.jsonl` is written under flock, one line per event,
  with `v` first; readers skip unparsable lines and tolerate unknown fields.
- **Tests never touch live state**: `QM_ROOT`, throwaway git repos with signing off.
- **Stdlib-light**: crates are `serde_json` (order preserved), `serde_yaml`, `chrono`, `libc`.
- **Not ported yet** (still Ruby): every other command, the viewer, `qm gui`, chats, worktrees,
  PRs, diffs, rotation, benchmarks and `statusline/statusline.rb`.
