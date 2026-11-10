# CLAUDE.md

**Quartermaster** (command `qm`) tracks every Claude Code session automatically
(hooks → JSONL log) and curates them into work items (markdown files with
state/notes) that the user manages from a terminal viewer, the `qm gui` web UI and a
phone page. A Rust crate (`src/`, binary `qm`) behind the `sh` launcher `./quartermaster`,
symlinked from `~/bin/quartermaster` and `~/bin/qm` — the symlinks and hook registrations
point at it, so never rename or move it; it runs `target/release/qm` (`cargo build --release`).

## Where things live

- **Docs:** `docs/README.md` indexes `overview.md`, `rejected.md` and one page per area
  (`docs/areas/*.md`): `**Code:**` names the files it owns, `## Rules` the constraints.
  Read it before touching that code and update it in the same commit — rewrite, don't append;
  why goes in the commit message.
- **Data:** `~/.claude/quartermaster/`, overridden by `QM_ROOT` (tests always do). Every file
  in it and its owning page → `docs/overview.md`.
- **GUI page scripts are classic `<script>` tags in load order, not ES modules**: shared
  globals, inline `onclick=`; load-time calls only into earlier files, `events.js` last, a new
  asset needs its tag in page.html → `docs/areas/gui-shell.md`.
- Hooks live in user-level `~/.claude/settings.json` → `docs/areas/capture.md`.

## Hard constraints

**Across every area**
- **Few dependencies** (`serde_json`, `serde_yaml`, `regex`, `chrono`, `libc`): a hook is one
  static binary, so a new crate needs a reason → `docs/overview.md`.
- **`qm statusline` must never break the status line**: no recording, no data dir creation, no
  panic on odd input → `docs/areas/side-panel.md`.
- **Hooks never block or break a session**: rescue everything, log to `qm.log`, exit 0. Only
  SessionStart prints (its stdout is Claude's context).
- **Per-tool-call hooks are plain POSIX `sh`**: never print, always exit 0, honor `QM_SKIP`,
  only append → `docs/areas/capture.md`.
- **External tools that change state go through `command_runner`**; tests put stand-ins on
  `PATH` (or fence a throwaway GUI root): no real server, IDE, worktree or notification.
- **Tests never touch the user's live state**: `QM_ROOT`, `QM_TMUX_SOCKET=qm-test-…` (kill that
  server after), never `tmux -L qm`.
- **Data formats carry `v:`** (JSONL events, work-item frontmatter): bump on a breaking change,
  readers tolerate unknown fields.
- **Behavior is pinned by `tests/`**: goldens for the CLI, a stand-in GUI for the commands,
  and (with `QM_RUBY_ORACLE`) comparisons against the last Ruby commit 6c25480 →
  `docs/areas/testing.md`. Change a golden only for a behavior you mean to change.
- **Edit user files minimally**: the changed key's lines only, flocked, atomic; YAML qm
  can't spell exactly like Psych is double-quoted → `docs/areas/work-items.md`. Exception:
  `config.yml` is rewritten whole, comments dropped, old copy kept as `.bak` →
  `docs/areas/settings.md`.
- **`QM_ASIDE` beats every linking rule**: an aside is never attached, logged as attention or
  distilled; any new per-session surface honors it → `docs/areas/asides.md`.

**The user's data, sessions and machine**
- **`qm install-hooks` prints, never writes** `~/.claude/settings.json` — that file is the user's.
- **Append-only files stay append-only**: `sessions.jsonl`, `events.jsonl` (read only through
  `event_log`), `board-writes.jsonl` (through `board_mirror`); folds never see a rewritten line
  → `docs/areas/capture.md`, `docs/areas/attention.md`, `docs/areas/side-panel.md`.
- **Work-item notes are append-only, addressed by position** (`#n`, rotation's `carried`) →
  `docs/areas/work-items.md`.
- **`usage-cache.json` is a record, not a cache**: never prune or rebuild it → `docs/areas/side-panel.md`.
- **Nothing types into the user's chat or ends it without their click**: no automatic rotation or
  restack, never from a state build, poll or notifier; `/rotate` stays
  `disable-model-invocation: true` → `docs/areas/rotation.md`, `docs/areas/stacks.md`.
- **No new agent use without the user's OK** → `docs/overview.md`.
- **qm never checks out a branch in an existing worktree**, and cleanup never removes what it
  can't prove safe; remote branches are never touched → `docs/areas/worktrees.md`.
- **`qm gui` has no self-shutdown**: never reintroduce a liveness timer or heartbeat → `docs/areas/gui-shell.md`.
- **GUI POSTs with a foreign `Origin` are refused**; Origin-less only for
  `LOCAL_ACTIONS` (`gui_server.rs`); the terminal WebSocket and `/api/drop` also need the
  per-start token → `docs/areas/gui-shell.md`.
- **Chats: one tmux session per item on the `qm` socket, named by slug; the program runs with
  every `CLAUDE*` var unset** (else transcripts aren't saved) → `docs/areas/chats.md`.
- **GUI long actions run on `gui_jobs` threads, never under the action mutex** → `docs/areas/gui-shell.md`.

## Conventions

- **Build through `/delegate-build`** if a change needs a new test, a full-suite run or >3
  files; small features take its light path.
- Name by intent, not implementation; rationale goes in commit messages.
- One module per concern under `src/`, intent-named (`session_log`, `work_item`, …); the GUI
  page is real assets under `gui/`.
- Tests: `cargo test`; mutation-check a change by breaking the code and watching a test fail.
  Test capture changes before real sessions. Throwaway test repos need `-c
  commit.gpgsign=false` and one commit (unborn branches have no branch name); commits to this
  repo are always signed.
- Big files and this file may only shrink (`tests/size_ratchet.rs`): split along a real seam,
  or raise `tests/size_limits.json` deliberately, said in the commit message.
