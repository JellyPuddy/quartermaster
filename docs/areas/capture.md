# Capture

**Code:** `src/hook.rs`, `src/session_log.rs`, `src/project_map.rs`, `src/project_config.rs`, `src/failure_log.rs`, `src/error_log.rs`, `hooks/record-event.sh`, `hooks/record-board-write.sh`, `hooks/snapshot-worktree.sh`
**Tests:** `tests/non_object_lines.rs`, `tests/sessions.rs`, `tests/characterization.rs`, `tests/chat_attention.rs`, `tests/failure_log.rs`, `tests/error_log.rs`
**Depends on:** none

## What it does

Every Claude Code session — every project, and cwds outside any project — is recorded by
hooks registered in user-level `~/.claude/settings.json`, not per repo. Hooks are
harness-guaranteed where memory/CLAUDE.md instructions are best-effort, and SessionStart
stdout is injected into Claude's context, so the tracking protocol announces itself every
session (what is injected: [linking](linking.md)). Global `~/.claude/CLAUDE.md` carries a
fallback protocol for when the injection is missing.

- **SessionStart** → `qm hook-session-start` (`HookHandler#session_started`): derives the
  branch and project from `cwd`, links the session to a work item if one matches
  ([linking](linking.md)), appends a `start` event to `sessions.jsonl` and prints the
  injected context. A linked session working in a `.claude/worktrees/*` checkout on a
  non-mainline branch also records that branch as the item's temp branch
  ([worktrees](worktrees.md)); a failure there is logged and never costs the context.
- **SessionEnd** → `qm hook-session-end`: appends an `end` event with mechanical facts only —
  commits since the start event's `head`, `git diff --shortstat HEAD`, duration, reason. No
  summariser runs at session end; distilling is on demand ([work-items](work-items.md)).
- **Aborted sessions clean themselves up**: when the session's transcript can't be found at
  SessionEnd, the session was opened and closed unused; the end event gets `empty: true`,
  the session is detached from every work item and dismissed from the inbox.
- **Appenders** (plain `sh`, per tool call / per prompt):
  - `record-event.sh` — `PermissionRequest`, `Stop`, `StopFailure`, `UserPromptSubmit`,
    `PostToolUse`, `PostToolUseFailure` (all tools) → one slim line in `events.jsonl`;
    read through `EventLog` ([attention](attention.md)).
  - `record-board-write.sh` — `PostToolUse` matcher `ArtifactData` → the full payload in
    `board-writes.jsonl`, sub-agents' calls included; folded by `BoardMirror`
    ([side-panel](side-panel.md)).
  - `snapshot-worktree.sh` — `UserPromptSubmit`, registered after `record-event.sh` → the
    session's worktree as a git tree in `prompt-snapshots.jsonl`; read by `PromptSnapshots`
    for the since-prompt diff ([diff](diff.md)).
- **`qm install-hooks` prints** the settings.json snippet (absolute paths through the
  launcher's realpath, so it points at this checkout); it never writes settings.json. Its
  SessionStart/SessionEnd entries replace the existing qm ones — kept side by side, every
  session would be captured and injected twice.
- **Sessions** are read through `SessionLog` (memoised per instance; a write invalidates it)
  into `Session` objects — the only reader of the event schema. A session's `tier`:
  `live` (running; never resume, it would fork), `resumable` (transcript exists),
  `expired` (transcript pruned), `uncaptured` (an item lists it, the log never saw it).
- **The inbox** (`SessionLog#inbox`): captured sessions no work item claims, not launched
  for an item (`QM_ITEM`), not an aside, not dismissed. Unlinked sessions (loose chats included)
  sit there silently and age out with their transcripts.
- **Project derivation** (`ProjectMap`): `config.yml` maps project names to repo roots
  (`ProjectConfig`, plain path or `root:` mapping, [overview](../overview.md#configyml));
  a cwd inside a root, or a worktree whose `git rev-parse --git-common-dir` lies inside one,
  gets that project; everything else is `No project`.
- **`qm.log`** (`data_root::log_error` → `failure_log`) is line-oriented. A header line
  starts at column 0: `<iso8601> [<context>] <Class>: <message>` (the message folded onto
  that one line). A **transient** failure — gh can't reach GitHub (`error connecting to
  api.github.com`, `connection reset`, `dial tcp`, `read tcp`, `i/o timeout`, `TLS handshake
  timeout`, `githubstatus.com`, a bare `EOF`), or a browser tab gone mid-response
  (`Errno::EPIPE`, `Errno::ECONNRESET`) — reads `<iso8601> [<context>] transient <Class>:
  <message>`. Only the contexts in `failure_log::SUCCESS_REPORTING` (`pr-inbox`,
  `pr-deployment`, `pr-refresh`, `gui-client`: the ones that call `failure_log::success`)
  write just the first failure of an outage; their next success ends it with `<iso8601>
  [<context>] recovered after <n> failure(s)`. Every other context writes each transient
  failure, since nothing would ever end its outage. A test holds the list equal to the
  `success` call sites in `src/`.
- **Unseen errors** (`ErrorLog`): the header lines of the log's last 256 KB that are neither
  transient nor recovered, newer than the iso8601 time in `errors-seen-at` (absent or
  unreadable: the last 24 h), each with its continuation lines. An unreadable log counts as no
  errors, so no state build fails on it. They feed the GUI's error badge (`errors` in the
  state, Mark seen = the `errors-seen` action, which writes now into `errors-seen-at`;
  [gui-shell](gui-shell.md)) and the status line's `⚠ N qm errors` ([side-panel](side-panel.md)).

## Rules

- **Hooks never block or break a session.** The `hook-*` commands rescue everything, log
  to `qm.log` and exit 0 (`guard_hook` in `src/cli.rs`); the launcher exits 0 without a binary;
  the `sh` hooks wrap their body in `{ … } >/dev/null 2>&1` and always `exit 0`. Pinned by tests.
- **Every `qm.log` line is a header starting at column 0**, and only headers carry
  `[<context>] transient` or `[<context>] recovered`: a multi-line message is folded onto its
  header. Non-transient failures are always written in full. Outage state is per process; a
  fresh process may write one more first failure. A new `failure_log::success` call site takes
  a literal context and joins `SUCCESS_REPORTING` in the same commit.
- **Only SessionStart may print**, and only the injected context. SessionEnd and every error
  path stay silent — stray stdout would leak into Claude's context.
- **Per-tool-call hooks are plain POSIX `sh`, not `qm`**: PostToolUse fires on every tool
  call and a process start there would tax every session. They never print, only append, and
  leave all derivation to qm at read time.
- **`QM_SKIP=1` silences capture**: every hook returns at once. qm's own headless
  `claude -p` runs (distill, ask, build progress) set it so they never log themselves.
- **`QM_ASIDE` asides**: SessionStart logs them with `aside: <slug>` and never attaches them
  (see [asides](asides.md)); `record-event.sh` and `snapshot-worktree.sh` log nothing for them.
- **`QM_LOOSE` loose chats**: SessionStart logs them with `loose: <id>` and never links them, but
  every other hook records them as usual ([loose-chats](loose-chats.md)).
- **Hook payload fields are pulled with first-match `grep -o`**: `record-event.sh` cuts the
  payload at `"tool_input"` first (every field it reads, `agent_id` included, precedes it),
  and keys inside string values are escaped, so a nested or quoted decoy never matches.
- **`snapshot-worktree.sh` is the one hook that runs git**: through a temp copy of the
  index only (`GIT_INDEX_FILE=<tmp> git add -A` + `git write-tree` from the toplevel);
  the real index, refs, stash and working tree are never touched, and a missing index
  starts empty.
- **The snapshot's git work is capped** at `QM_SNAPSHOT_TIMEOUT` seconds (default 5) by a
  watchdog subshell; a killed snapshot writes no line. The watchdog is killed, never waited
  for. Nothing is written outside git.
- **Never trust a hook's `transcript_path` alone** (`Quartermaster.locate_transcript`): it
  is derived from the cwd and can be wrong (`claude --worktree --resume` reports the
  worktree's slug directory while the transcript lives under the original project's). Fall
  back to globbing `~/.claude/projects/*/<session-id>.jsonl` — ids are globally unique.
  Without this such sessions read as expired and the empty-session cleanup would detach
  them.
- **A missing transcript at SessionEnd reliably means "opened and closed unused"**: Claude
  Code never persists a transcript for a zero-message session, and real transcripts are
  written incrementally.
- **Liveness is checked at read time, never trusted from the log**: SessionEnd doesn't fire
  on a crash. The start event records the claude pid, found by walking `ps` ancestry from
  the hook process (up to 6 levels, first command matching `claude`, else the parent);
  `SessionLog` checks it with `kill(0, pid)` (EPERM counts as alive).
- **Path comparisons go through realpath on both sides** (`ProjectMap#normalize`): macOS
  `/var` → `/private/var` and git returning realpaths would otherwise miss matches.
- **`sessions.jsonl` is append-only** under an exclusive `flock`, every event stamped with
  `v`. A dismissal is another appended event, never an edit; a line that isn't a JSON object is skipped.

## Data

- `sessions.jsonl` — `start`: `{v, event, session_id, source, cwd, transcript_path, branch,
  head, pid, project, work_item, ts}` (an aside has `aside` instead of `work_item`, and no
  `head`; a loose chat has `loose`); `end`: `{v, event, session_id, reason, duration_s, commits, diff_stat, ts,
  empty?}`; `dismissed`: `{v, event, session_id, ts}`.
- `events.jsonl` — `{v, ts, session_id, event, tool, agent}`; `agent` is the sub-agent's id,
  empty for the main thread. Grows forever: read it only through `EventLog`.
- `board-writes.jsonl` — `{v, ts, payload}`, the raw hook payload with newlines folded to
  spaces (JSON strings never hold raw newlines). Only ever appended to.
- `prompt-snapshots.jsonl` — `{v, session_id, cwd, toplevel, tree, at}` (`at` UTC, whole
  seconds). The trees are unreferenced objects, so `git gc` prunes them after ~2 weeks.
- `config.yml` — `projects:` (name → path, or a mapping with `root:` and feature keys),
  `default_project:`, `loose_starters:`; seeded on first run with no projects (`CONFIG_SEED`, the
  file [settings](settings.md) writes for none). A broken file reads as no projects.
- Hook stdin: `session_id`, `cwd`, `transcript_path`, `hook_event_name`, plus `source` on
  SessionStart (`startup|resume|clear|compact`) and `reason` on SessionEnd.

## Known limits

- Hook config changes in settings.json apply to already-running sessions (they fire
  SessionEnd), but a session started before the hooks has no start event until it is
  resumed or restarted.
- Headless `claude -p` sessions fire SessionStart/SessionEnd like interactive ones — useful
  for end-to-end checks, and the reason `QM_SKIP` exists.
- The hooks run the launcher, which needs `target/release/qm`: after a `git pull`, `cargo build
  --release`, and check that first when capture goes quiet.
- Claude Code prunes transcripts `cleanupPeriodDays` (default 30) after their last write;
  qm can't stop that, only distill first ([work-items](work-items.md)).
