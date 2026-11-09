# Chats

**Code:** `src/tmux.rs`, `src/terminal_bridge.rs`, `src/drops.rs`, `src/chat_history.rs`, `src/transcripts.rs`, `src/pane_follows_session.rs`, `gui/js/chat.js`, `gui/js/chat-main.js`, `gui/js/terminal.js`, `gui/js/history.js`, `gui/css/chat.css`
**Tests:** `tests/chats.rs`, `tests/gui.rs`, `tests/pane_follow.rs`
**Depends on:** [gui-shell](gui-shell.md), [attention](attention.md), [linking](linking.md)

## What it does

The GUI's chat view: a second mode beside the kanban (toolbar Board/Chats switch or `v`, remembered
per browser). Opening an item from the board (click or ⏎) lands in its chat. The Chats toggle counts
blocked + unsnoozed your_turn chats.

- **Left**: the `ChatAttention` list as the server sorted it (`/api/state` → `attention`: slug, session,
  state, since, tool, snoozed, contextTokens, cacheWarmUntil) — state dots, time waiting, context size
  (amber from 150k, red from 250k), a snooze (`z`) on an unsnoozed your_turn. An item opened from the
  board that isn't listed shows under "opened from the board"; live loose chats follow under "Loose"
  ([loose-chats](loose-chats.md)). `‹` shrinks the list to a strip of dots
  with initials (`qm-chats-min`, localStorage).
- **Centre**: the item's chat pane — a live terminal on its tmux chat — with the read-only history of
  earlier sessions above it and its sessions collapsed underneath (open when there is no live pane).
- **Right**: the digest (description, branches, the notes a new session is told about — `injected`
  positions from `WorkItem#injectable_notes`), `i` for the full detail sheet; see [side-panel](side-panel.md).
- **Chat pane**: `Tmux` runs each chat on the `qm` socket; `TerminalBridge` bridges `/ws/terminal` to a
  PTY running a fresh `tmux attach` per connection (`GET /ws/terminal?session=&token=&cols=&rows=`;
  xterm.js + fit, unicode11 and web-links addons).
  `Launcher#chat_plan`: **Start** = `QM_ITEM=<slug> claude` at `start_cwd`; **Resume** = `resume_plan`
  (`claude --resume <id>` in its cwd, else the same fresh start). A first prompt rides as claude's
  last argument (issue kickoff, an automation's brief via `automation_chat`), never typed; a live pane
  is only shown again ([automations](automations.md)).
- Actions `pane-start`, `pane-resume` (optional `session`), `pane-warp` (a Warp tab running
  `tmux -L qm attach -t =slug`); `/api/state` carries `panes` (live tmux session names), each item's
  `pane` flag and `terminalToken`. The chat view's Resume/Start, `r`/`n` and session rows' Resume go to
  the pane; the kanban card and detail sheet keep their Warp actions. `QM_CHAT_COMMAND` swaps the program
  (`claude --model haiku` for an end-to-end check).
- **History above the chat**: every item session that isn't live, oldest first (`ChatHistory#timeline`),
  dark like the terminal under an **EARLIER** bar (Hide/Show, `qm-history-collapsed` in localStorage).
  Per session (`TranscriptHistory`): the user's prompts and Claude's text in full (one message's text
  blocks joined by message id), each `tool_use` as one line ("Bash  bin/rspec …", the input named by
  `TOOL_SUBJECT_KEYS`, clipped to 160), an interrupt as an event. Rotation dividers sit between
  sessions by time ([rotation](rotation.md)).
- History leaves out thinking, tool results, sidechains, meta/hook entries and compaction summaries.
  A pruned transcript falls back to the session's distilled snapshot, else a line saying nothing survived.
- History loads lazily: `GET /api/history/SLUG` is the timeline, `GET /api/history/SLUG/SESSION?before=N`
  one page (60 entries) ending before N, newest first; older pages and segments prepend as the scroll
  nears the top. Parsed transcripts are cached keyed by path+size+mtime. The page reloads history only
  when the earlier sessions or the item's `rotations` count change.
- **Dropping files** (screenshots) onto a terminal: the page POSTs the bytes to
  `/api/drop?token=…&name=…`; `Drops` saves `drops/<stamp>-<rand>-<quote-free name>` and the page
  `paste`s the path (as Warp does), so claude attaches it.
- **Driving the pane from the CLI** (the phone, via a Remote Control chat): `qm pane-start SLUG`,
  `qm pane-resume SLUG [--session ID]` and `qm rotate SLUG [--close]` POST the GUI's existing actions
  to `QM_GUI_PORT` without an Origin (`CLI#gui_action`, shared with `qm caffeinate`). Same refusals;
  no GUI → says so, exits 1; a refusal exits 1 with the action's error; a live pane answers "already running".

## Rules

**tmux**
- Chats live in tmux on a dedicated socket (`tmux -L qm`; `QM_TMUX_SOCKET` overrides, tests use
  `qm-test-*` and kill that server), so they survive GUI restarts. Never touch `tmux -L qm` in tests.
- One tmux *session* per chat holding one window, both named by slug — never one shared session with a
  window per item: an `attach -t =slug` client can then never be moved onto another item's window when
  the chat ends; the session ends with claude, the client exits, the pane closes.
- Server options are re-applied on every open: status off, mouse on (the wheel scrolls tmux history via
  copy-mode), `escape-time 10` (Esc reaches claude at once), `prefix None` (Ctrl-b stays claude's),
  `history-limit 50000`, `window-size latest`, and OSC 8 hyperlinks for `xterm*` clients.
- The program runs under `sh -c` that unsets every `CLAUDE*` variable first: the GUI may itself run in
  a claude session and the tmux server keeps the env it started with; an inherited nested-session
  marker turns transcript saving off.
- Typed text goes in with `send-keys -l`, Enter separately (`send_enter`): claude reads a typed burst as
  a paste and an Enter inside it lands in the paste. Multi-line text goes as one bracketed paste
  (`load-buffer` + `paste-buffer -p -d`).
- **One live chat per item**: a live tmux session is just shown again (`attached`); a live session of
  the item running elsewhere (a Warp tab) refuses both Start and Resume — it shows in the list with
  hook-driven status and no pane, and once it has ended Resume takes it over in the pane.
- No Resume on a live session, anywhere (it would fork): under a live pane the session rows offer no
  Resume, and Start says the item already has its chat.
- **The name follows the session** (`PaneFollowsSession`): when a session moves to another
  item (`qm attach`, `qm new --session`, `qm attach-session`, `item-from-session`, the GUI's attach /
  item-from-session), the vacated item's tmux session and window are renamed to the new slug —
  only when the pane's pid is the moved session's recorded claude pid (the launcher `exec`s);
  a slug alone never proves which chat runs there.
- A new slug that already has a live tmux session renames nothing and is reported (a `qm:` line on
  stderr, the GUI reply's `warning`, toasted). Asides (`<slug>--aside`) never move; failures go to qm.log.

**Terminal bridge**
- Each WebSocket spawns its own `tmux attach` PTY: a reload or second tab is another client and tmux
  redraws; closing the socket kills only that client. Binary frames are keystrokes, text frames
  `{cols, rows}` resizes (the PTY winsize, clamped to 1–500 × 1–200, plus a SIGWINCH to that client).
- The 60 s read timeout (`QM_GUI_REQUEST_TIMEOUT_MS` shortens it, for tests) covers reading a request only: a
  WebSocket clears it before `serve`, since an idle terminal sends nothing (no ping) and would be dropped.
- `window-size latest` sizes the window to the client that attached, resized or typed last, so a
  second tab or Warp attach on the same chat takes it and a pane shows only its top rows. An unchanged
  winsize sends no SIGWINCH, so the bridge signals one itself, and a page re-sends its terminals' sizes
  (`claimSize`) on window focus, becoming visible and focus inside a terminal: that pane wins the window back.
- An upgrade needs our Host, an `Origin` equal to our own (required, unlike POSTs — browsers always send
  one here), the per-start token, and a live tmux session by that name; otherwise 403
  (`TerminalBridge#refusal`). Any site can open a WebSocket to 127.0.0.1, and this one types into a chat.
- The token is embedded in the page and also in `/api/state` (same-origin only), so a tab from before a
  GUI restart reattaches without a reload. It is compared in constant time.
- The WebSocket server is a hand-rolled RFC 6455 (`WebSocket`) — stdlib only.
- xterm.js and its addons load from cdn.jsdelivr.net at pinned versions with `integrity` hashes: that
  script runs in our origin next to the terminal token; a version bump needs new hashes.
- The terminal lives in a persistent element the state re-renders never touch. A dropped connection
  reattaches from the pulse tick, at most every 2 s (the aside terminal too: an aside moves no pulse).

**Keys** (`gui/js/terminal.js`)
- Every key typed into a terminal is claude's, Esc included: the page's document shortcut handler skips
  `.term-host` targets. A new GUI shortcut goes in the document handler.
- The only exceptions are ⌘⇧⏎ (`isMaxChord`) and ⌘⇧Esc (`isLeaveChord`), exactly ⌘ and ⇧, swallowed in
  xterm.js's `attachCustomKeyEventHandler` on every `TermView` (every event type, so claude never sees them).
- **Maximize** (⤢ in the term bar or ⌘⇧⏎): a `pane-max` class on `body` hides toolbar, legend, list,
  side panel, chat header, history and sessions (CSS only, no Fullscreen API); the terminals refit.
  The aside drawer stays inside the chat pane and overlays it. Without terminal focus the document
  handler catches ⌘⇧⏎. Esc never restores. State in `sessionStorage` (`qm-pane-max`): per tab, and only
  while the chat view shows a live terminal.
- **Leaving the terminal** (⌘⇧Esc): blurs xterm.js so focus falls to the page body and the
  document shortcuts (`v`, `j`/`k`, `d`, …) work again. Nothing refocuses the terminal behind it.
- **Mac editing chords** (`MAC_CHORDS`): ⌘← → `^A`, ⌘→ → `^E`, ⌘⌫ → `^U`, ⇧⏎ → `ESC CR` (claude's
  newline; xterm sends a bare Enter). Only with exactly that one modifier; ⌥ chords already work.
- **Selecting a chat focuses its terminal**: a click on a list row, opening a chat from the board
  (click, ⏎) or the PRs view (Chat/Review, the item link) focuses that chat's terminal.
- `j`/`k`/arrows only move the list selection and keep focus on the row (focusing the terminal would
  hand every following key to claude); ⏎ on a highlighted row moves focus into its live terminal.
- The intent (`selectChat(slug, { focusTerm: true })`) is honoured only by the render that selection
  triggers, one animation frame later, and only if that chat is still selected, its pane is live and
  focus is still on the list or nowhere (no input, modal, sheet or popover took it). Polls never move focus.

**Fit and widths**
- `.term-host` is `box-sizing: content-box`: the fit addon sizes from its computed height/width, which
  under the page's border-box include padding — the terminal came out a row and a column too big.
- xterm's viewport scrollbar is hidden (tmux owns scrolling, scrollback 0); it covered the last columns.
- The Unicode 11 addon makes xterm count symbol/emoji widths like tmux and claude; with Unicode 6 every
  disagreement shifted the rest of the line and the cursor.
- The socket sends the size again on open: a refit while still connecting was dropped, tmux kept the
  URL's stale size (a row more than xterm showed) and the screen scrolled under a cursor one line low.
- Plain-text URLs are links even when split across rows (tmux never marks a row wrapped: a row running
  to the right edge joins the next, minus its indent). OSC 8 links go through `linkHandler` (xterm's
  default asks `confirm()`). Both open a new tab.

**Drops**
- `/api/drop` needs the terminal token (its result is typed into a chat); bodies over `Drops::MAX_BYTES`
  (32 MB) are refused unread. Drops older than a week are pruned on the next drop.

**Pulse** (page side, see [gui-shell](gui-shell.md))
- The page polls `/api/pulse` about once a second: the sizes of `events.jsonl`, `sessions.jsonl` and the
  transcripts of chats that were working or blocked at the last state build (Esc shows only there),
  plus the notifier's count.
- While the chat view is visible it refetches `/api/state` only when the pulse moved; elsewhere, or in
  a hidden tab (throttled to ~1/min), it refetches only `/api/attention` when the pulse's events part
  moved — the tab title stays current without redrawing the board under the user's typing.
- The state's own pulse is taken before the build reads anything, so a write landing mid-build is never
  lost. A page-side poll, not a server liveness timer: the server never notices it stopping.

## Data

- `drops/<stamp>-<rand>-<name>` under the qm root, pruned after 7 days.
- tmux sessions on the `qm` socket: `<slug>` (the chat), `<slug>--aside` ([asides](asides.md)) and
  `loose--<id>` ([loose-chats](loose-chats.md)).
