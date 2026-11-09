# GUI shell

**Code:** `src/gui_server.rs`, `src/gui_action.rs`, `src/gui_actions.rs`, `src/gui_jobs.rs`, `src/gui_state.rs`, `src/command_runner.rs`, `src/pf.rs`, `src/transcript_search.rs`, `src/ask_command.rs`, `gui/page.html`, `gui/js/core.js`, `gui/js/server.js`, `gui/js/events.js`, `gui/js/board.js`, `gui/js/detail.js`, `gui/js/session-sheet.js`, `gui/js/search.js`, `gui/js/transcript-search.js`, `gui/js/popovers.js`, `gui/js/modals.js`, `gui/js/focus.js`, `gui/js/long-actions.js`, `gui/js/errors.js`, `gui/css/base.css`, `gui/css/board.css`, `gui/css/header.css`, `gui/css/overlays.css`, `gui/css/responsive.css`, `src/grep_command.rs`
**Tests:** `tests/command_timeout.rs`, `tests/gui.rs`, `tests/error_log.rs`, `tests/grep.rs`, `tests/ask.rs`
**Depends on:** [work-items](work-items.md), [attention](attention.md), [chats](chats.md), [worktrees](worktrees.md), [side-panel](side-panel.md)

## What it does

`qm gui` is a loopback web UI over the work items: a kanban board, a chat view (`v`), a PRs
view (`p`), an Issues view (`I`) and the Settings view (`,` or the header's ⚙ button, not a mode
tab; [settings](settings.md)). It is a stdlib `TCPServer`, no web framework.

**Server lifecycle** (`Gui#run`). Binds `127.0.0.1` on the fixed port 49737 (`QM_GUI_PORT`
overrides) so the URL is stable and the browser keeps one tab. If the port is taken, it
assumes another `qm gui`, opens that tab and returns. It opens the page with `open` unless
`QM_GUI_NO_OPEN` is set, serves each connection on its own thread, and runs until Ctrl-C.
Two server threads start with it: the turn watcher (`TurnNotifier`, reacts to
`events.jsonl` growing, every 1.5 s) and the auto-caffeinate watcher (every 15 s).

**Router** (`Gui#respond`, pure request → response, unit-tested; sockets in
`#handle_client`). Host check → 403, foreign Origin → 403, Origin-less POST outside
`LOCAL_ACTIONS` → 403, unknown route → 404. A `websocket` upgrade goes to `TerminalBridge`;
a body over `Drops::MAX_BYTES` is refused unread with 413. Routes: `GET /`, `/assets/…`,
`/api/state`, `/api/pulse`, `/api/root`, `/api/attention`, `/api/session/<id>`, `/api/asides/<slug>`,
`/api/history/<slug>`, `/api/workspace/<slug>`, `/api/diff/<slug>`, `/api/diff-file/<slug>`,
`/api/prs`, `/api/pr-threads`, `/api/issues[/<slug>]`; `POST /api/action`, `/api/drop`,
`/api/ask`, `/api/grep`, `/api/cleanup-plan`. `GET /api/settings` and `POST
/api/settings/check|save` are [settings](settings.md)' (`gui_settings`, tried before the 501). `/api/root`
answers `{root}`, `data_root::root_id`: a SHA256 of the realpath'd data root, never the path, which the CLI's
hand-off checks before it POSTs ([cli](cli.md)).

**Actions** (`GuiActions#dispatch`, `POST /api/action {cmd, slug, args}`). Each web action
maps to the WorkItem / Launcher / SessionLog / Workspace / Tmux / Rotation operation the CLI
uses too, never to a CLI `cmd_*` (those `abort` and read stdin). `SystemExit` is rescued into
a JSON error; `AlreadyDistilledError` returns `needs_confirmation` and a refused `delete`
returns `needs_force`, which the page turns into a confirm (no failure toast) and retries with `force: true`. The page refetches `/api/state` after every action.

**Long actions** (`GuiJobs`). work-on, pf-switch, ide, terminal, pf-stop, cleanup, rotation,
review posting, issue start, the PRs view's pf/IDE buttons and build-progress run on
server threads via `GuiJobs#background(key, label, pf:)`: one job per key (the slug, `sweep`,
`pf`, `progress:<slug>`), at most one pf job at a time. `jobs` in the state drives each
item's badge (`#relabel` updates it, e.g. `cleaning up n/total…`); `finished` hands each
outcome over once (a toast, plus the bin/update offer after a pf switch). Distill plans under
the action mutex (its guards answer at once), then distills per session on a thread; the state
reports `distilling` slugs and one-shot `distilled` results. The page polls state every
1.5 s while jobs, distills or PR refreshes are pending.

**Cleanup checklist** (UI over [worktrees](worktrees.md)). `POST /api/cleanup-plan
{scope: SLUG|"sweep"}` is read-only and renders the plan: ok entries start ticked, ⚠ entries
are unticked with their reasons and need **Force…** plus a second confirm, ⛔ entries can't be
ticked; ticking a worktree ticks the branch that `requires` it. The `cleanup` action re-plans
and runs the chosen ids on a job. Resolving through the State menu opens the same checklist
from the plan its reply carries ("Resolved. Clean up N worktrees?"). The header's ⋯ menu has
**Sweep orphan worktrees…**.

**State** (`GuiState#build`, `/api/state`): `items`, `inbox`, `projects`, `attention` (the
chat view's list, already in attention order), `pulse`, `refreshing`, `distilling`,
`distilled`, `pf`, `jobs`, `finished`, `buildActive`, `buildProgress`, `panes`,
`terminalToken`, `asideModels`, `caffeinate`, `notifications`, `rateLimits`, `benchmark`, `errors` (the header's ⚠ badge: the unseen qm.log errors' count and newest 20 entries, from `ErrorLog` in [capture](capture.md); clicking it lists them, and **Mark seen** posts the `errors-seen` action, which takes the normal Origin rule: it is not a local action). Per item: slug,
title, state, project, branches, issue, sessions (`sessionList` with id, tier, when, prompt),
`updated`, `live`, `badges` (stale / degrading / merged, from `Attention`), headline `note`,
`injected` positions, `worktrees`, `chains`, `prStates`, `served`/`servedBranch`, `pane`,
`aside`, `asideCount`, `boardRows`, `rotations`, `usage`, `drafts`, `issues`, `benchmarkable`, `benchmarked`. One
`git worktree list` per project root per build; PR states come from cache, expired ones are
refetched on threads and `refreshing` tells the page to poll until they land.

**Pulse** (`/api/pulse`, ~1 s poll on the chat view): a string of the sizes of
`events.jsonl`, `sessions.jsonl` and the last build's mid-turn transcripts, plus the
caffeinate held flag, the drafts and issue-drafts signatures and the notifier's sequence.
The page fetches full state only when it changes. Off the chat view the page watches the
cheaper events pulse and `/api/attention` (attention, notifications, draft counts) for the
tab title's count. The pulse also tells `TurnNotifier` whether the page is visible/focused.

**The page.** `gui/page.html` holds the markup plus two server-injected constants
(`TAXONOMIES`, substituted from the Rust taxonomies so JS and server can't drift, and
`terminalToken`); styles and scripts are `gui/css/*.css` and `gui/js/*.js` by area, served
from `/assets/` and read at serve time like the page (so edits need no restart); after a JS
edit, `node --check gui/js/<file>.js` checks its syntax (nodejs is pinned
in `.tool-versions` for that alone; no test needs node). xterm.js,
highlight.js and marked load from jsDelivr with SRI hashes. `docs/gui-mockup.html` is the
design reference: SF for chrome, SF Mono for data (slugs, ids, states, stamps, kbd chips),
an indigo accent reserved for focus/links/primary, semantic colours apart from it (amber
stale, red degrading, green merged), light and dark.

**Board.** Columns In progress / Fridge / Resolved (All adds Active); never automation items,
which `/api/state` still carries for their chat view; filters All / Open / per state; an inbox
rail of unlinked sessions. Card actions on one line: Resume · Start · State ▾ · ⋯ (note and
the rest live in ⋯). A card click (or Enter) opens the item's chat in the chat view; the
**detail sheet** opens from ⋯ "Open detail", the chat view's `i` or the side panel's "Full
detail": description, branches with worktree
chips, the board link, a notes timeline with kind filter chips (all / open / decision /
history, when more than one kind exists), sessions with tier badge, resume and Unlink
(detach), snapshots, and **Delete item…** at the foot: an in-page confirm, and when the
server's guard refuses (`needs_force`, [work-items](work-items.md)) the dialog lists what the
item holds and offers **Delete anyway**; the next refresh no longer finds the item and closes the sheet.
Every section header collapses; filter and fold state survive refreshes and reset when
another item opens. A session row (or an inbox row) opens the **session sheet** above it:
the transcript's turns parsed on demand (`GET /api/session/<id>`, clipped server-side) —
prompt, a derived tool digest (tallies + touched file basenames) and the reply's opening,
since Claude Code never persists its own per-turn summaries. Expired sessions degrade to
capture metadata plus snapshots; inbox sessions resume via `resume-session` (the session's
own cwd, no `QM_ITEM`). Esc closes the top sheet first.

**Keyboard map** (board): `j`/`k` move, `h`/`l` column, `/` search, `c` new item, Enter
chat, `r` resume, `n` new session, `o` PR, `s` state, `a` note, `.` more, Esc close;
`v` / `p` / `I` / `,` switch mode. The chat view has its own map (see [chats](chats.md)).

**Search** (client-side over the state payload). Every space-separated term must match. Free
terms fuzzy-match slug/title (fzf-style subsequence, from 4 chars, tight or word-start only)
and word-start-substring match branches, project, description, notes and snapshots; a title
hit outranks a note hit, columns sort by score, a body match shows its snippet. Field terms:
`p:` project, `b:` branch, `#issue` / `project#issue`, `is:live|stale|degrading|merged`,
leading `-` excludes. Matches hidden by the state filter show as "+N in other states".
A menu under the box offers the two explicit searches:

- **Ask** (Enter; `qm ask`): `AskSearch` hands headless `claude -p --model sonnet` a capped
  index of every item (description ≤ 800 chars, newest notes first ≤ 2,000) and gets up to 8
  ranked `{slug, why}` via `--json-schema`; the board shows them across all states with the
  reason on each card, Esc clears. On `#1234` alone Enter starts work on that issue instead.
- **Transcript search** (⇧⏎; `qm grep`): `TranscriptSearch` runs `rg --files-with-matches
  --fixed-strings --ignore-case --max-depth 2` through `CommandRunner` over the transcripts
  dir (the phrase JSON-escaped first, as it sits on disk), newest first, then parses each
  candidate and counts only user prompts and assistant text. Stops after 60 matching
  sessions and counts the rest as `more`. Results open in a modal grouped by work item
  (unlinked last), each with date, hit count, a marked snippet and Resume.

**Dev server** (`Pf`, the `dev_server:` of a project in config.yml; one shared server, its status
read through the first project that configures one): status from its `status_url` (0.5 s timeout,
JSON `{mode, root, switching}`), else its `state_file` ("<mode> <root>", what ran last) plus
`<command> status`'s exit code; no configured server → no status and nothing runs. `#serves?(path)`
is the cleanup guard; switch/stop run `<command> switch PATH MODE` / `<command> stop`. The state's
`pf` carries `command` (nil hides the header badge); the header shows "<command>: <mode> @
<worktree>" with **Stop**; items whose checkout it serves get 🖥 on card and chat row. It is the
user's one real dev server whatever `QM_ROOT` says, so a GUI off the live data root
(`Quartermaster.live_root?`: `QM_ROOT` is not `~/.claude/quartermaster`) fences its runner
(`PfFence`): every configured dev-server command but `status` is refused before it runs, and
`pf.off` in the state disables Stop, Switch, Work on this and the PRs view's dev-server button. A safe
smoke-test GUI is therefore just `QM_ROOT=<tmpdir> QM_GUI_PORT=<free port> qm gui`. The IDE
opens via the configured `ide_command:` argv ([config](../overview.md#configyml)).
The Workspace buttons that drive both are in [side-panel](side-panel.md).

## Rules

- Bind `127.0.0.1` only; a request whose Host isn't `127.0.0.1:<port>` / `localhost:<port>` gets 403 — cheap DNS-rebinding defence, no auth needed (`LoopbackGuard`).
- A POST whose `Origin` isn't ours is refused: a cross-site no-cors POST arrives with our own Host, and actions remove worktrees and run bin/update.
- A POST without `Origin` passes only for `LoopbackGuard::LOCAL_ACTIONS` (caffeinate, pane-start, pane-resume, rotate, issue-start, loose-start, automation-chat, page-annotations); a new local caller adds its action there.
- Page-like test posts send our Origin (the `host` / `ok_host` helpers); page seams are tested through `served_page(gui, host)`, the page plus its assets.
- The terminal WebSocket and `/api/drop` need the per-start `terminalToken` as well as our Origin — they type into a live chat (details in [chats](chats.md)).
- No self-shutdown, ever: the server runs until Ctrl-C. A heartbeat/bye scheme closed the server under backgrounded tabs and let a stale tab kill a newer server; don't reintroduce a liveness timer.
- The ~1 s pulse is the page asking for news; nothing on the server reacts to it stopping (a stale pulse only makes `TurnNotifier` notify via macOS). Server threads react only to files.
- Mutating actions run under one action mutex; anything that takes seconds hands off to `GuiJobs` and never holds it — distill used to queue every other action behind it.
- Read-only routes (ask, grep, diff, history, workspace, cleanup-plan, PRs, issues, threads) and `GuiActions::UNLOCKED` (issue-preview, pr-thread-resolve, review-preview, and the benchmark-* actions, which have BenchmarkRun's own locks) skip the mutex.
- Only one pf job at a time: pf is one shared server. A second job on a busy key is refused with the running job's label.
- Actions call the model layer, never CLI `cmd_*`; the CLI and GUI share operations so they can't drift. `SystemExit` must become a JSON error, never a dead server.
- A state build never blocks on gh or on spawning git per item; PR states refresh on threads.
- `pf` status is cached 2 s (the fallback spawns `pf status`, the chat view builds state every second); a pf action forgets the cache.
- Every external tool that changes state goes through `CommandRunner`, which also finds tools in `~/bin` when PATH lacks it and can bound a command (`call_bounded`: its process group is killed after N seconds, the result failing with "timed out after N s"). `Gui` takes `runner:`, `tmux:`, `caffeinate:`, `pf_live:` (default `live_root?`, so a test GUI is pf-fenced unless it passes `pf_live: true`); every test GUI gets `quiet_runner` and tmux on `QM_TMUX_SOCKET`.
- Scripts are classic `<script>` tags in load order, not ES modules: shared globals and inline `onclick=` need it. A file calls another at load time only if that one loads earlier; `events.js` (boot) loads last.
- A pane's render keeps its scroll via `keepScroll` (core.js), so every caller (poll, job end, click) does; it resets only when the subject changes (another item, issue or detail sheet), and nothing outside the render saves or restores it.
- A new asset needs its tag in page.html; `/assets/` serves only `css/NAME.css` and `js/NAME.js` (an allowlist pattern, so no traversal).
- `.pop` needs `z-index: 150` (above the detail sheet's 90 scrim and the modal overlay's 100), and click-outside is a `mousedown` listener per popover installed on open — a global one dismissed the menu on the click that opened it.
- The session sheet's scrim is `z-index: 95`, between the item sheet (90) and modals (100).
- Keyboard-first is a hard requirement: every board action has a key. A new GUI shortcut goes in the document handler, which skips `.term-host` targets.
- Ask uses sonnet, not haiku: under `claude -p` Haiku runs extended thinking by default and took 17–27 s; sonnet answers in ~4 s and ranks better. `--tools ""` and `--strict-mcp-config` keep it from reading files.
- Transcript search counts only prompts and assistant text (tool output would drown every hit), skips sidechains, sub-agent transcripts (depth 2) and asides, and finds `rg` on PATH, `/opt/homebrew/bin` or `/usr/local/bin`.
- Search runs entirely client-side over `/api/state`; it never adds a server round-trip.

## Known limits

- pf's status endpoint answers only while rails is up; mid-boot the file fallback reports what ran last.
- Ask is a headless model call (~4–6 s) per Enter; its index is capped, so very old notes may not be seen.
