# Rust port

**Code:** `Cargo.toml`, `src/attention.rs`, `src/attention_command.rs`, `src/background_jobs.rs`, `src/chat_attention.rs`, `src/cleanup.rs`, `src/cleanup_command.rs`, `src/cli.rs`, `src/cli_format.rs`, `src/clock.rs`, `src/command_runner.rs`, `src/data_root.rs`, `src/delegate.rs`, `src/draft_command.rs`, `src/drafts.rs`, `src/error.rs`, `src/event_log.rs`, `src/feature_use.rs`, `src/front_edit.rs`, `src/gh_stack.rs`, `src/git.rs`, `src/git_repo.rs`, `src/hook.rs`, `src/issue_drafts.rs`, `src/item_usage.rs`, `src/lib.rs`, `src/main.rs`, `src/note.rs`, `src/outcome.rs`, `src/pane_follows_session.rs`, `src/pf.rs`, `src/pr_status.rs`, `src/price_defaults.rs`, `src/price_table.rs`, `src/project_config.rs`, `src/project_map.rs`, `src/psych.rs`, `src/ruby_format.rs`, `src/ruby_num.rs`, `src/ruby_text.rs`, `src/sections.rs`, `src/session_commands.rs`, `src/session_log.rs`, `src/session_rows.rs`, `src/show_command.rs`, `src/tmux.rs`, `src/transcript_usage.rs`, `src/transcript_vitals.rs`, `src/transcripts.rs`, `src/usage_ledger.rs`, `src/work_item.rs`, `src/work_item_commands.rs`, `src/yaml_scalar.rs`, `src/config_seed.yml`, `src/usage.txt`
**Tests:** `tests/attention.rs`, `tests/attention_commands.rs`, `tests/characterization.rs`, `tests/chat_attention.rs`, `tests/cleanup.rs`, `tests/interop.rs`, `tests/issue_drafts.rs`, `tests/pane_follow.rs`, `tests/psych_scalars.rs`, `tests/sessions.rs`, `tests/show.rs`, `tests/usage.rs`, `tests/work_items.rs`, `tests/common/mod.rs`, the golden files in `tests/fixtures/golden/`, and the unit tests inside the `src` files
**Depends on:** [capture](capture.md), [work-items](work-items.md), [cli](cli.md)

## What it does

`qm` is being ported from Ruby to Rust one area at a time. The Rust binary (`target/debug/qm`,
crate `quartermaster`) serves the commands it has ported and `exec`s the Ruby launcher
`./quartermaster` — arguments and stdin untouched — for every other word, so any command works
from either binary while the port is partial. `QM_RUBY_LAUNCHER` overrides where the fallback
looks; the default is the checkout the binary was built from.

Ported so far: the SessionStart and SessionEnd hooks (the same events, the same injected
context, byte for byte), `sessions`, `inbox`, `dismiss`, feature-use recording for them, the
session log, config.yml's project side, the project map, and the work-item commands `new` (with `--pf-mode`, checked against the project's dev-server modes under the lock),
`note`, `retag`, `state`, `link-branch`, `unlink-branch`, `board`, `move`, `retitle`,
`describe`, `detach` and `list` (bare `qm` without a terminal lists too), and `show-session`,
`session-item`, `help`, `install-hooks`, `ack`, `snooze`, `show`, `attach`, `new --session`, `cleanup SLUG`, `state … resolved`, `issues-dir` and `draft list`. `attach` and `new --session` move the session between items under the work-item lock (reentrant per thread, as Ruby's, so a
compound move nests) and then rename the chat's tmux session to follow it, unless it is an aside, its
pane runs another process, or the new name already has a chat (then a warning). `Tmux` is ported only
as far as listing, liveness, pane pid and rename; starting a chat, typing into it, respawn and kill
stay Ruby, since nothing types into the user's chat without their click. `show` keeps the Ruby command's
side effects, in its order: it auto-links the item's gh-stack branches (`GhStack`, read from the
repo's common git dir; refs read from loose files and `packed-refs`, or git for a reftable repo),
refreshes `pr-cache.json` through `gh`, and saves the usage ledger. `GhStack` has no in-process
caches — they only help a long-lived GUI — and its `chains` (stacks and loose branches with ahead
counts and restack flags) are ported whole for the GUI port to use. The attention rules themselves
(`Attention`: expiring transcripts, quiet items, merged PRs, with `PrStatus` and its `pr-cache.json`)
are ported as a library, and so are the chat rules under `qm attention`, which is ported too:
`EventLog` folds `events.jsonl` into `events-fold.json` (rewritten by a read that finds new bytes,
and only when a live session needs a turn), `TranscriptVitals` reads a transcript's tail,
`BackgroundJobs` finds pending background work, and `ChatAttention` ranks the chats from them.
So is the usage side of the side panel — `TranscriptUsage`, `UsageLedger` (`usage-cache.json`),
`PriceTable` and `ItemUsage` — which `show` will print. The ledger is a record: Rust reads it, adds
to it and saves it atomically over whatever another process saved meanwhile, and never prunes or
rebuilds it. Like Ruby, a file that does not parse reads as empty and the next save replaces it. `src/usage.txt` is `qm help`'s output as Ruby prints it;
the tests compare it with Ruby's, so a change to `CliFormat::USAGE_SECTIONS` fails until the file
is regenerated (`./quartermaster help > src/usage.txt`). `install-hooks` prints the snippet for
the checkout's Ruby launcher, never for the Rust binary.

**Cleanup is planned in Rust, never carried out.** `state … resolved` (which also drops the item's
viewed marks) and `qm cleanup SLUG` build the item's plan with `GitRepo` (worktrees, dirt, and the
commits a head would lose: not in any base, no patch-equivalent among what the bases hold, not a
squash merge into trunk or the head's upstream; a git failure reads as "couldn't check", never as
nothing to lose) and `Cleanup`, and print it. The dev server's status and the project's test-DB
dry run go through `command_runner` — read-only probes. The plan lists the item's issue drafts too
(`IssueDrafts`: each file's front matter, its unsent comments from `drafts/<slug>.json`), and reading
them keeps Ruby's `.prev` revision snapshots — what a file held when last seen and before that — and
prunes those whose file is gone. Removing anything (`--yes`, `--force`, the sweep) stays Ruby, so no
Rust code path deletes a worktree, a branch or an issue draft.

**Issue drafts are read in two steps.** `issue_drafts::load` only reads: it parses every `*.md`
file's front matter with the rules of `IssueDrafts#parse` (the error texts included) and says "not
mine" for anything Psych's `safe_load` would read differently from the YAML parser here — a YAML
error, an anchor, alias, tag or merge key, a date, a float, `1_000`, `010`, `0x1F`, a plain `yes`,
a file that is not UTF-8 or not a regular file. A command that gets "not mine" goes to Ruby before
anything is written (`state … resolved` checks first, since it changes the item); `Loaded::record`
is the step that writes snapshots, and repeating it changes nothing. `qm draft list` prints the
drafts file's entries (`--json` in the json 2.7 gem's layout, where an empty array is `[` blank line
`]`); `qm draft add` stays Ruby (it resolves a PR through `gh` and writes the drafts file).

Still Ruby, even for these words: `draft add`, `state … resolved` and `cleanup SLUG`
for an item whose issue drafts `load` declines, and every argument shape the
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
every step); `tests/chat_attention.rs` builds about 35 chats (every transition, interrupt, background-job and
snooze case) twice, runs Ruby's `qm attention` on one copy and the Rust binary on the other, and
compares the output and the fold file's bytes, then a second run after appends, a truncated log and
no log; it also fuzzes the two transcript parsers and the watcher patterns against Ruby (it names
both binaries itself, so `QM_BIN` does not matter there). `tests/attention.rs` builds one world twice (items, sessions, transcripts, a fake `gh`) and
compares Ruby's and Rust's entries, `pr-cache.json` and `gh` calls; `tests/psych_scalars.rs` dumps about 3,400 generated strings with the real Psych and
compares. `tests/cleanup.rs` builds a git repo with worktrees in every state cleanup cares about (fixed commit dates, so shas agree), runs Ruby's plan and `state … resolved` on one copy and Rust's on the other and compares every printed line and trace, down to how often the dev server was asked. `tests/issue_drafts.rs` does the same for issue drafts (every error text, revisions moving between reads, the cases that go to Ruby, `issues-dir`, and `draft list` over every kind of draft); its Rust runs point `QM_RUBY_LAUNCHER` at nothing, so a command that quietly fell back to Ruby fails. `tests/pane_follow.rs` runs a real tmux server on a throwaway socket (killed afterwards, never the
`qm` socket) with chat-like panes whose pids are written into `sessions.jsonl`. `tests/show.rs` builds a git repo with gh-stack stacks (packed and loose refs, an origin-only branch,
a restack), a fake `gh`, transcripts and sessions, runs `show` over every item and compares the output
and every trace it leaves with Ruby's; mutation checks of the port need `QM_BIN` set to the Rust binary,
or the CLI-level tests only exercise Ruby. `tests/usage.rs` runs Ruby and Rust over the same transcripts pass after pass (appends, rewrites,
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
- **Stdlib-light**: crates are `serde_json` (order preserved), `serde_yaml`, `chrono`, `libc`, `regex`.
  Ruby's `\w` and `\s` are ASCII-only while its `\b` is Unicode, so patterns spell the classes out.
- **Numbers match Ruby, not C**: `Array#sum` compensates (Kahan-Babuska) once a Float appears and
  keeps Integers exact before that (`ruby_num.rs`); `Time#to_f` is the nanosecond count as a double
  divided by 1e9; and `format("%.Nf")` rounds a near-tie to even on the last digit generated,
  which Rust's own formatting does not (`ruby_format.rs` ports Ruby's dtoa quick path).
- **Known Ruby race, not fixed here**: Ruby reads an item before taking the lock and saves with a
  plain `File.write`, so concurrent Ruby writers often fail with "malformed work item file". Rust
  writers cannot produce that state; the mixed-writer test allows only that failure, from Ruby.
- **Not ported yet** (still Ruby): the viewer and every other command, `qm gui`, chats, worktrees,
  PRs, diffs, rotation, benchmarks and `statusline/statusline.rb`.
