# Rust port

**Code:** `Cargo.toml`, `src/attention.rs`, `src/cli.rs`, `src/cli_format.rs`, `src/clock.rs`, `src/data_root.rs`, `src/delegate.rs`, `src/error.rs`, `src/feature_use.rs`, `src/front_edit.rs`, `src/git.rs`, `src/hook.rs`, `src/item_usage.rs`, `src/lib.rs`, `src/main.rs`, `src/note.rs`, `src/outcome.rs`, `src/pr_status.rs`, `src/price_defaults.rs`, `src/price_table.rs`, `src/project_config.rs`, `src/project_map.rs`, `src/psych.rs`, `src/ruby_format.rs`, `src/ruby_num.rs`, `src/ruby_text.rs`, `src/sections.rs`, `src/session_commands.rs`, `src/session_log.rs`, `src/session_rows.rs`, `src/transcript_usage.rs`, `src/transcripts.rs`, `src/usage_ledger.rs`, `src/work_item.rs`, `src/work_item_commands.rs`, `src/yaml_scalar.rs`, `src/config_seed.yml`, `src/usage.txt`
**Tests:** `tests/attention.rs`, `tests/attention_commands.rs`, `tests/characterization.rs`, `tests/interop.rs`, `tests/psych_scalars.rs`, `tests/sessions.rs`, `tests/usage.rs`, `tests/work_items.rs`, `tests/common/mod.rs`, the golden files in `tests/fixtures/golden/`, and the unit tests inside the `src` files
**Depends on:** [capture](capture.md), [work-items](work-items.md), [cli](cli.md)

## What it does

`qm` is being ported from Ruby to Rust one area at a time. The Rust binary (`target/debug/qm`,
crate `quartermaster`) serves the commands it has ported and `exec`s the Ruby launcher
`./quartermaster` — arguments and stdin untouched — for every other word, so any command works
from either binary while the port is partial. `QM_RUBY_LAUNCHER` overrides where the fallback
looks; the default is the checkout the binary was built from.

Ported so far: the SessionStart and SessionEnd hooks (the same events, the same injected
context, byte for byte), `sessions`, `inbox`, `dismiss`, feature-use recording for them, the
session log, config.yml's project side, the project map, and the work-item commands `new`,
`note`, `retag`, `state`, `link-branch`, `unlink-branch`, `board`, `move`, `retitle`,
`describe`, `detach` and `list` (bare `qm` without a terminal lists too), and `show-session`,
`session-item`, `help`, `install-hooks`, `ack` and `snooze`. The attention rules themselves
(`Attention`: expiring transcripts, quiet items, merged PRs, with `PrStatus` and its `pr-cache.json`)
are ported as a library; the `qm attention` command stays Ruby because it also lists chats.
So is the usage side of the side panel — `TranscriptUsage`, `UsageLedger` (`usage-cache.json`),
`PriceTable` and `ItemUsage` — which `show` will print. The ledger is a record: Rust reads it, adds
to it and saves it atomically over whatever another process saved meanwhile, and never prunes or
rebuilds it. Like Ruby, a file that does not parse reads as empty and the next save replaces it. `src/usage.txt` is `qm help`'s output as Ruby prints it;
the tests compare it with Ruby's, so a change to `CliFormat::USAGE_SECTIONS` fails until the file
is regenerated (`./quartermaster help > src/usage.txt`). `install-hooks` prints the snippet for
the checkout's Ruby launcher, never for the Rust binary.

Still Ruby, even for these words: `show` (it needs stacks, PR state, the attention fold and usage
tallies — each a stage of its own),
`attach` and `new --session` (they rename the chat's tmux pane), `new --pf-mode`, `state
… resolved` (it offers cleanup and clears the viewed marks), and every argument shape the
port does not parse exactly as Ruby's `OptionParser` does — abbreviated or `=`-joined flags,
`--`, a dash-leading title or note, `retag` positions Ruby's `Integer()` would read as octal or
hex, `~user` paths, arguments that are not UTF-8. Such a command is handed to Ruby before
anything is written, so the choice is invisible except in speed.

**Writing work items.** A new item's front matter is written key by key in Psych's style:
`psych.rs` picks the style Psych picks (plain, single-quoted when the string would read back as
a number, boolean, null or date, double-quoted when it starts with a non-word character or needs
escapes), applies libyaml's rule for whether that style is allowed, and folds long values at
column 80 with a two-space indent. An existing item is edited by replacing or adding only the
lines of the key being changed, under the `work-items/.lock` flock the Ruby side takes, and
saved through a temp file and rename; every other key and the body stay byte for byte. A value
the emitter cannot reproduce with certainty (line breaks, `<<`, timestamp-like strings, a first
character Rust and Onigmo classify differently) makes the write fail before anything is
written, and the command goes to Ruby.

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
two binaries on one data root. `tests/work_items.rs` records command transcripts (exit code, streams, the item file after
every step); `tests/attention.rs` builds one world twice (items, sessions, transcripts, a fake `gh`) and
compares Ruby's and Rust's entries, `pr-cache.json` and `gh` calls; `tests/psych_scalars.rs` dumps about 3,400 generated strings with the real Psych and
compares. `tests/usage.rs` runs Ruby and Rust over the same transcripts pass after pass (appends, rewrites,
a pruned transcript, another process's save) and compares every row and the ledger's bytes; it also
fuzzes costs, labels and `mtime` floats. A command is ported only after the characterization suite
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
- **Numbers match Ruby, not C**: `Array#sum` compensates (Kahan-Babuska) once a Float appears and
  keeps Integers exact before that (`ruby_num.rs`); `Time#to_f` is the nanosecond count as a double
  divided by 1e9; and `format("%.Nf")` rounds a near-tie to even on the last digit generated,
  which Rust's own formatting does not (`ruby_format.rs` ports Ruby's dtoa quick path).
- **Known Ruby race, not fixed here**: Ruby reads an item before taking the lock and saves with a
  plain `File.write`, so concurrent Ruby writers often fail with "malformed work item file". Rust
  writers cannot produce that state; the mixed-writer test allows only that failure, from Ruby.
- **Not ported yet** (still Ruby): `show`, `attach`, the viewer and every other command, `qm gui`, chats, worktrees,
  PRs, diffs, rotation, benchmarks and `statusline/statusline.rb`.
