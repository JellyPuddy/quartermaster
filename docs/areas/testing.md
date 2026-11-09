# Testing

**Code:** `Cargo.toml`, `tests/common/mod.rs`, `tests/docs_shape.rs`, `tests/size_ratchet.rs`, `tests/size_limits.json`
**Tests:** `tests/docs_shape.rs`, `tests/size_ratchet.rs`, `tests/launcher.rs`

## What it does

`cargo test` runs the unit tests inside `src/` and the black-box tests in `tests/`, which run the built
`qm` (or serve the GUI from it) against a temporary data root.

- **Goldens.** Most CLI tests are transcripts: each step prints the command, its exit code, stdout, stderr
  and the item file it touched, scrubbed of dates, pids and the temp root, and `golden(name, text)` compares
  it with `tests/fixtures/golden/<name>`. `QM_UPDATE_GOLDEN=1` rewrites the file; read the diff before
  committing it.
- **Fakes.** External tools are stand-ins on `PATH` that log their argv and stdin (`gh`, `claude`, `fzf`,
  `open`, `osascript`, the dev server, the IDE, `tmux` runs on a `qm-test-…` socket), and a GUI the
  commands talk to is a canned TCP server in the test. Nothing touches the user's real data, sessions or
  machine.
- **The Ruby oracle.** Until commit 6c25480 qm was written in Ruby and the port was verified by running
  both side by side. Those differential tests (`tests/gui.rs`, `chat_attention`, `cleanup`, `interop`,
  `issue_drafts`, `usage`, `psych_scalars`, …) are still here and skip unless `QM_RUBY_ORACLE` names a
  checkout of that commit: `git worktree add ../qm-ruby 6c25480 && QM_RUBY_ORACLE=$PWD/../qm-ruby cargo
  test`. They need Ruby 3.3 and compare byte for byte; where the Rust behaviour was deliberately changed
  after the port (option errors, titles with no ASCII letter, YAML a Psych-exact writer would spell
  differently) the tests that pinned the old behaviour are gone.
- **Regenerating a golden from the oracle.** `QM_UPDATE_GOLDEN=1 QM_BIN=$ORACLE/quartermaster cargo test
  --test NAME` writes what Ruby printed; only do it for a behaviour you mean to keep.
- **Docs and size.** `tests/docs_shape.rs` checks the shape of `docs/`; `tests/size_ratchet.rs` keeps big
  files from growing (below).

## Rules

- Tests set `QM_ROOT` and `QM_TMUX_SOCKET=qm-test-…`; they never touch `~/.claude/quartermaster` or the
  `qm` tmux server.
- Throwaway git repos need `-c commit.gpgsign=false` and one commit (an unborn branch has no name).
- A Ruby-vs-Rust test starts with `if common::skip() { return; }`.
- **Size ratchet.** A file over its threshold (src 400 lines, tests 800, GUI assets 400) is pinned at its
  size in `tests/size_limits.json`; it may shrink, and a pinned file at 90 % of its limit or less must be
  lowered. `CLAUDE.md` is pinned in bytes. To raise a limit, edit the JSON and say so in the commit
  message; to lower them all, `QM_LOWER_LIMITS=1 cargo test --test size_ratchet`.
- `docs/` pages: each area page has `**Code:**`, `**Tests:**`, `## What it does` and `## Rules`; every
  `src/*.rs`, `gui/js/*.js` and `hooks/*.sh` is named by exactly one page's Code line; README links every
  page; no dates or plan-decision numbers in area pages; line caps (README 80, overview 150, rejected 120,
  area pages 200).
