# Side panel and header

**Code:** `lib/quartermaster/workspace.rb`, `lib/quartermaster/ide.rb`, `lib/quartermaster/board_mirror.rb`, `lib/quartermaster/usage_ledger.rb`, `lib/quartermaster/transcript_usage.rb`, `lib/quartermaster/item_usage.rb`, `lib/quartermaster/price_table.rb`, `lib/quartermaster/rate_limits.rb`, `lib/quartermaster/caffeinate.rb`, `lib/quartermaster/build_progress.rb`, `lib/quartermaster/gui/js/chat-side.js`, `lib/quartermaster/gui/js/limits.js`, `lib/quartermaster/gui/css/side-panel.css`, `statusline/statusline.rb`, `skills/adopt-worktree/SKILL.md`, `skills/delegate-build/SKILL.md`, `skills/delegate-build/helpers/status-board.html`
**Tests:** `test/usage_test.rb`, `test/rate_limits_test.rb`, `test/statusline_test.rb`, `test/caffeinate_test.rb`, `test/build_progress_test.rb`, `test/board_mirror_test.rb`, `test/pf_test.rb`, `test/gui_test.rb`
**Depends on:** [gui-shell](gui-shell.md), [worktrees](worktrees.md), [stacks](stacks.md), [capture](capture.md)

## What it does

The chat view's right panel, top to bottom: an Item head with the item's link chips (`linkChips`,
not for an epic, whose chips are in its block) and **Full detail** (`i`, the detail
sheet), the Epic block for an item in an epic or "This epic" for the epic itself (title, link chips,
the "✓ all done — resolve epic?" suggestion, the epic's description for a child, its open children
with their attention state to switch to, its GitHub sub-issues no item holds yet with a Start each
([issues](issues.md)), open todos on the item and on the epic ticked through
`todo-done`, and "+ todo" adding one on the epic through `todo-add`; built by `chatEpicSection` in
`chat-epic.js` from `epics.js`'s shared helpers, owned by [chats](chats.md)), Workspace, Description, Board (only with a board link), Carried notes (the injected
ones, "n of m", plus **+ Add note**), and Usage pinned at the bottom. The header carries the pf badge, the usage-limits
chip, the ☕ toggle and a ⋯ menu (see [gui-shell](gui-shell.md) for pf and sweep).

**Workspace** — where "work on this" lands. `GET /api/workspace/SLUG?branch=` resolves
`TargetWorktree` for the item's selected branch (target, whether it gets created, a warning)
plus `chatBranch` and `defaultBranch`; it is fetched per item and selection, not per state
build, because it asks tmux and git where the chat runs, and it creates nothing. **One
selected branch per item** drives both this target and the diff pane: picked on a rail node
or in the diff bar, remembered per slug for the tab (`qm-branch-picks` in sessionStorage);
without a pick, the chat's branch when a chain holds it, else the top of the first chain
(`Gui#default_selection`). The diff pane asks for no branch while the default is the chat's
own, so the default costs no reload. Rails under the heading show the item's chains (one rail
per stack or loose branch; node facts, folding and ⟳ restack are in [stacks](stacks.md)); a
click only selects, and the selected node gets 📊, 🏁 and **Diff ›**. A branch without a checkout reads
"@ new worktree · created on first use"; the buttons then create it and Adopt is hidden.
When pf serves a lower layer of the stack the chat runs on, a warning reads "pf serves ③
while the chat is on ⑤". Items without linked branches keep a plain target line.

Buttons, each sending the selected branch as `branch` and running as a GUI job:
- Items whose project has a `dev_server:` (workspace payload `devServer`: `{command, modes, mode}`):
  **Work on this** (primary: dev-server switch + the IDE; only with an IDE, else Switch is
  primary), **Switch <command>**, **Open in <label>**, and an editable mode chip (`pf_mode`);
  switch labels name the mode whenever it isn't what the server runs. Other items: Open in <label>
  only. The IDE buttons need an `ide_command:` (payload `ide`: `{label, command}`, the title
  showing the command with the target for `PATH`); without one they are hidden
  ([config](../overview.md#configyml)). Every item: **Terminal** (a Warp tab in the target,
  `WarpTab`, no command).
- After a successful switch: **Run bin/update**, in a tmux session of its own
  (`bin-update-<dir>`, on the qm socket), shown in a terminal dialog; it waits for Enter when
  done so the output stays. Migrations stay manual.
- **Adopt worktree…** (a target worktree that exists and isn't the main checkout) types
  `/adopt-worktree <path>` into the item's chat — the skill owns the flow, including moving
  the IDE (`ide_command`) off the worktree. Refused mid-turn; with no chat, a fresh one starts with it as
  first prompt in the main checkout, so the session doesn't sit in the directory it deletes;
  a chat running outside the GUI refuses.
- **Clean up worktrees…** opens the cleanup checklist.

`Workspace` is the shared layer for CLI and GUI (`work_on`, `switch_pf`, `open_ide`,
`open_terminal`, the PRs view's `switch_pf_to_branch` / `open_ide_on_branch`, `stop_pf`):
each returns a report of steps; a failure raises `ArgumentError` with the tool's own message
and keeps the steps that already ran. The dev server runs only for projects that configure one,
the IDE (`Ide#argv`) only with an `ide_command:` — `open_ide` refuses before creating anything,
`work_on` skips the missing half and refuses only when both are missing.

**Board** — the item's status-board rows (`boardRows`: status, title, note, dependsOn),
produced by the bundled `delegate-build` skill (a test keeps its seeding step and
`status-board.html` naming every `BoardMirror::ROW_FIELDS` field), grouped like the artifact:
one foldable group per batch, newest first, open and marked with an accent dot, earlier ones folded unless they hold a blocked row; plan order within a batch. A
batch header counts its rows by status in glyphs (`2✓ 1▶ 1○`), the words in its tooltip. A blocked row gets an answer
box when the item has a `board_answers_dir`. **Check build progress** heads the section.

The board is mirrored because claude.ai refuses to be iframed (`frame-ancestors 'self'`) and
headless `claude -p` has no `ArtifactData`; the artifact itself keeps working for the phone.
`BoardMirror` folds `board-writes.jsonl` (every `ArtifactData` call, appended by the
PostToolUse hook, sub-agents included) into rows per board, mirroring the database: set
replaces, update deep-merges (`{"__delete__": true}` drops a field), str_replace edits one
string field (only when `old_str` occurs exactly once, or at least once with `replace_all`),
delete removes, batch applies each entry in order; last write wins. Reads and refused writes
(error-flagged or "nothing written" responses) leave no trace. A line is the raw hook payload
(optionally with `ts`) or a `{ts, payload}` wrapper; a write's data may come from its
`file_path`, read best-effort. Boards are keyed by artifact id, so `/artifact/` and
`/code/artifact/` spellings agree. One shared mirror per file per process.

**Build progress check** (`BuildProgress`, on the user's click only). Active agents: every
Workflow run of every session attached to the item, under
`<proj>/<sid>/subagents/workflows/<runId>/`. A run is running while
`<proj>/<sid>/workflows/<runId>.json` is absent (Claude Code writes it when the run ends) or
carries no terminal status, *and* its session is live. Within a run, `journal.jsonl` decides:
a `started` {key, agentId, label, phase} with no `result`/`failed` for its key; without a
journal, an agent whose transcript ends in a `StructuredOutput` hand-back is done. Lines are
per task in the user's terms: `build:x` → "x · building", `review:x` → "x · reviewing",
`integrate` → "integrating"; internal helpers (`queue#n`, checkers) are neither shown nor
estimated. Per agent (~4–6 KB): label, run, phase, minutes working, the brief (last plain
user message before its first answer, harness framing stripped, ≤ 2,000 chars) and its last
20 activities from a 200 KB transcript tail (what it said, each tool call's most telling
input, clipped; no thinking, no tool output). One `claude -p --model haiku` call with
`QM_SKIP=1`, no tools, no session persistence and a JSON schema (`{agents: [{label, percent,
doing}]}`). Rendered one line per active agent in qm's order ("≈60% · x · building · …"); a
skipped label shows "no estimate", an invented one is dropped, a non-schema answer shows raw.
Nothing running → "nothing running", no model call. The `build-progress` action is a job keyed
`progress:<slug>`; the result (failures included) replaces the previous one in
`GuiJobs#progress`, served as `buildProgress` with the time it was taken. Every state build
lists items with an active task (`buildActive`, file reads only) — only they show the button —
and drops lines of tasks no longer active, and the whole estimate once none is left.

**Usage and cost** (`usage` per item in the state; `qm show` prints the total plus one line per
session). Tokens and an **API-equivalent** cost estimate across the item's sessions, their
sub-agent transcripts and its asides. Shown as "2.3M tok · ~$12"; hover or tap for the
per-session breakdown (asides marked, sub-agent count, tokens, cost; per-model tokens in the
row tooltip).
- `TranscriptUsage` tallies one transcript into buckets — model id (date suffix and `[1m]`
  dropped) plus `:fast` (`speed: fast`) and `:long` (prompt — input + cache reads + writes —
  over 100k) — of `input`, `cache_write_5m`, `cache_write_1h` (split from
  `usage.cache_creation`; an unsplit write counts as 5m), `cache_read`, `output`. Each message
  id counts once, with its last entry's usage; `<synthetic>` entries are skipped. Incremental
  from the byte offset of the last complete line.
- `UsageLedger` (`usage-cache.json`) keeps those states per session for the transcript and
  `<transcript dir>/<session id>/subagents/**/*.jsonl`, checked by path + size + mtime; an
  unchanged main transcript costs one stat. A save is atomic and merges over what is on disk
  under a flock (`.usage-cache.json.lock`), so concurrent savers keep each other's sessions. A
  file there that doesn't parse as a ledger reads as empty, but a save never overwrites it: it
  moves it to `usage-cache.json.corrupt-<UTC time>` and logs a `[usage-ledger]` error first.
- `PriceTable`: defaults from the official pricing page (cited in the class), overridable per
  model and field under `prices:` in `config.yml` (`PriceTable.load` takes `ProjectConfig.current.prices`;
  a broken config reads as no overrides). A bucket falls back `x:fast:long` → `x:fast`
  → `x`. Unknown models still count tokens; the cost is marked **partial** and names them.
- `ItemUsage` sums the sessions plus every aside session (`aside_for` the slug). A session
  that expired before any tally makes the figure a lower bound ("≥"); none ever tallied reads
  "usage unknown · sessions expired". The GUI keeps one ledger in memory and saves it after a
  state build.

**Rate limits chip** (`gui/js/limits.js`, beside the pf badge): `5h 42% · 2h15m │ wk 61% ·
3d4h`, each percentage coloured at 50/80% like the status line, countdowns from `resetsAt`
("reset" once passed), re-rendered every minute; greyed with its age ("8h old") once
`capturedAt` is over 6 h old; hidden without a snapshot. `RateLimits#payload` turns
`rate-limits.json` into `{fiveHour: {usedPercentage, resetsAt}, sevenDay: {…}, capturedAt}`
(ISO times; a missing window is nil), or nil without a usable snapshot (no file, bad JSON, no
`captured_at`, no window). It is `rateLimits` in `/api/state` and in `qm overview --json`.

**Status line** (`statusline/statusline.rb`, symlinked as `~/.claude/statusline.rb`). Claude
Code hands rate limits only to the status line command (stdin
`rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`, epoch seconds), so it is where
qm gets them. Its second line is the linked item's title via `qm session-item`. Inside a qm chat
(`$TMUX`'s socket path names `qm`, or `QM_TMUX_SOCKET`) it drops the 5h/wk segments and the
`◆ item` line (and the `qm session-item` call); context % stays. Elsewhere output is unchanged.
Outside a qm chat, unseen qm.log errors (the [capture](capture.md) `ErrorLog` rule, parsed again
here) add a red `⚠ N qm errors` after the model; a log not modified since `errors-seen-at` (or
the last day) is not read at all.

**Caffeinate** (header ☕). `Caffeinate` owns one child: on spawns
`/usr/bin/caffeinate -i -w <gui pid>` (idle sleep only; the display may still sleep and lock)
and keeps its pid in memory; off sends TERM and reaps it; a second on keeps the running child;
a child that died on its own reads as off. **Auto** holds the child only while some session is
busy — any live session, linked or not, whose `ChatAttention#turn_for` state is `working` or
`waiting` (background work out). The `watch_for_caffeinate` thread calls `Caffeinate#sync` every
15 s with `GuiActions#sessions_busy?`; switching to auto applies the verdict at once. The click
cycles off → auto → on; auto shows an "A" and a dashed ring, coloured while held
(`aria-pressed="mixed"`, `.held`). State: `caffeinate: {on, pid, mode}`; the held flag is part
of the pulse so a server-side flip repaints. `qm caffeinate on|off|auto|status` POSTs the
`caffeinate` action to the running GUI.

## Rules

- A state poll never re-renders the panel while one of its inputs, textareas or selects has focus, so a half-typed board answer survives.
- The workspace payload is fetched per item and selection, never in the state build: it lists worktrees and asks tmux and git.
- A selected branch must be one the item links (`TargetWorktree.require_linked`); actions refuse it before starting a job. qm never checks out a branch in an existing worktree.
- Adopt is delegated to the `/adopt-worktree` skill through the chat, never reimplemented.
- Only a currently blocked row can be answered: a file left for a running task would be read as the answer to its next question.
- An answer is written to `<board_answers_dir>/<doc_id>.md` via temp + rename, so the agent's `[ -f ]` wait never sees half a file; the doc id must be one plain path segment.
- `board-writes.jsonl` is only appended to; `BoardMirror` folds new complete lines from its offset and refolds only when the file shrinks.
- Build progress runs only on a click: no periodic runs, no always-on numbers; tool-call counts are never shown or fed in as a measure.
- A crashed session's unterminated run never counts as running: liveness of the session is required.
- `usage-cache.json` is a record, not a cache: once a transcript is pruned its tally is the only trace. Never prune or rebuild it, and never save over a file that isn't a ledger: set it aside first. qm never deletes a `.corrupt-*` copy, and only a save moves one aside, never a read.
- Costs are API-equivalent estimates, never a bill; the cited defaults carry their date in `PriceTable`, `prices:` overrides.
- A usage failure must never cost the whole state build (`usage` is nil then, or for an item without sessions).
- `rateLimits` is not part of the pulse: the status line rewrites the file on every render, so the chip follows the next state build.
- `statusline.rb` runs under `/usr/bin/ruby` 2.6, standalone: no `filter_map`, numbered params, pattern matching or endless methods, never loads `lib/`; `test/statusline_test.rb` runs it there (skipped where missing).
- The status line replaces `<QM_ROOT>/rate-limits.json` atomically (tmp + rename, last writer wins — limits are per account) with `{v: 1, five_hour: {used_percentage, resets_at}, seven_day: {…}, captured_at}`, only when the qm root exists, and swallows every failure.
- The status line's error count reads only qm.log's last 256 KB and any failure counts as no errors: it runs on every render and must never break.
- The ☕ child belongs to the GUI process (`-w <gui pid>`, pid in memory only, no pid file), so it dies with the GUI and a restarted GUI starts off with nothing to adopt.
- Auto mode never touches the server's life — it only switches the child — and acts only in auto, so manual on/off always win. `blocked` doesn't count as busy: it waits on the user.
- Tests pass `Gui` a `caffeinate:` with stubbed spawn/alive/kill; a test GUI without one never spawns unless an `on` action reaches it.

## Data

- `board-writes.jsonl` — append-only, one line per `ArtifactData` call.
- `usage-cache.json` — `{v, sessions: {id → per-file TranscriptUsage states}}`, permanent;
  `.usage-cache.json.lock` serialises saves; `usage-cache.json.corrupt-<YYYYMMDDTHHMMSSZ>` is an
  unparseable ledger a save set aside, kept for the user to recover by hand.
- `rate-limits.json` — the status line's last snapshot.
- Caffeinate mode, build-progress estimates and the in-memory ledger live in the GUI process only; a restart forgets them (caffeinate starts off).

## Known limits

- An item whose sessions expired before the ledger existed shows a lower bound or "usage unknown".
- The limits chip is only as fresh as the last status-line render anywhere on the account.
