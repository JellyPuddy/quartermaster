# Rotation

**Code:** `src/rotation.rs`, `skills/rotate/SKILL.md`
**Tests:** `tests/gui.rs`
**Depends on:** [chats](chats.md), [work-items](work-items.md), [attention](attention.md)

## What it does

Hands an item's chat over to a fresh session that starts from the work item's notes instead of a
bloated or cold context.

- **Context meter** (`ContextMeter`): amber from 150k tokens, red from 250k (`ctxLevel` on each
  attention row). The offer (`rotate`) is `threshold` from 150k, or `cold` when the context is over 50k
  and the last assistant message is more than 1 h old (the next turn would re-send it all uncached).
- The list row shows **rotate?** at the threshold; the chat header shows a meter bar plus **rotate?**
  whenever there is an offer, and on a `cold` offer a banner ("The cache is cold… Rotate?" /
  **Not now**, which holds until the chat answers again) — so reopening a cold item offers it.
- `Rotation#plan` checks and refuses at once; `Rotation#run` then runs as the item's background job
  (`GuiJobs`). Four modes:
- **Live chat in its pane** (`wrap_up`): types `Rotation::WRAP_UP_PROMPT` ("Wrap up for a context
  rotation: record any decisions and open items not yet in the work item with qm note / qm retag, then
  reply DONE."), waits up to 20 min for a `UserPromptSubmit` at/after the send followed by a `Stop`
  (a permission prompt for `qm note` is answered in the pane), then the hand-off: `remain-on-exit` on,
  `/exit`, wait for the pane to die (60 s), record the rotation, `respawn-pane` a fresh `QM_ITEM`
  session (`Launcher#fresh_chat_plan`) in the same window, `remain-on-exit` off. Attached panes stay attached.
- **Dead chat** (`distill`): the newest captured session gets the Haiku distill when its transcript
  survives and has no snapshot yet; the rotation is recorded and a fresh chat opens in a new tmux session.
- **Wrap up & close** (`rotate` with `close: true`, live chat in its pane only): the same
  wrap-up, `/exit` and recorded rotation, no fresh start — the kept window is killed so a later **Start**
  works and gets the notes the usual way. For saving decisions while the cache is hot without starting
  the next chat. Offered in the chat header next to **rotate?**, in the cold banner and in the ⋯ menu.
- **Finish** (`rotate` with `finish: true`, which implies `close`): Wrap up & close with
  `Rotation::FINISH_PROMPT` ("This work item is done: record any remaining decisions with qm note, retag
  open notes that are handled with qm retag, then reply DONE.") instead, then the item is set `resolved`
  (`WorkItem#update_state`) — only after the hand-off succeeded. One click, no confirm, no worktree or
  branch cleanup (the cleanup sweep owns that). Offered beside Wrap up & close in the chat header and the
  ⋯ menu, not in the cold banner; GUI only, no CLI flag.
- **Self-rotation** (`rotate` with `self: true`, optional `session`; mode `:self`): the chat
  asks for its own hand-off after writing its notes, via `qm rotate --self [--close]` run by the `/rotate`
  skill. No prompt is typed. It stamps `requested_at`; `run` waits up to 20 min for the session's
  `your_turn` with a `Stop` at/after the request and after its latest prompt, then the same hand-off
  with `via: "self"` (or the kill, with close).
- The CLI resolves the self-rotating caller: the live session whose claude pid is an ancestor of the
  `qm` process (`Session#pid`, `CLI#caller_pids`), its item `WorkItem.for_session`, else `QM_ITEM`. It
  prints "rotating after this turn ends" and returns at once.
- The job message reports what was carried: "rotated — carried N decisions, M open"; Finish's reports
  what is left: "resolved — N open notes remain" (every open note, re-read after the wrap-up; no tail at 0).

## Rules

- **Never automatic**: rotation types into the user's chat and ends the session, so only their click (the
  `rotate` action, or `qm rotate SLUG` from the CLI) starts it. No poll, state build or meter starts one.
- Dead chats get the existing Haiku distill; no new agent use without the user's OK.
- `plan` refuses: a live pane mid-turn (`working`/`blocked`); a chat `waiting` on background work (the
  message names the `waiting_on` descriptions); a live session running outside the GUI ("end it there
  first"); a pane without a captured session; close without a live pane; no session to rotate from.
- Only a Stop *after* qm's own prompt counts (prompt stamp ≥ send time, Stop ≥ that prompt); an earlier
  Stop never does. Stamps are whole seconds, hence ≥.
- The wrap-up prompt and its Enter go separately with a 0.5 s pause (`TYPE_SETTLE`): an Enter inside the
  typed burst would land in claude's paste.
- A Stop timeout (20 min, `STOP_TIMEOUT`) or exit timeout (60 s) leaves the chat as it was;
  `remain-on-exit` is switched back off on an exit timeout. Finish then resolves nothing: the resolve runs
  after the hand-off returns, never before. Open notes left over don't block it.
- A failed fresh start kills the kept window: a window with a dead pane would block Start as "already live".
- The fresh session starts in the same tmux window (`remain-on-exit` + `respawn-pane`) so attached panes
  don't close.
- **Self-rotation is the one mode allowed mid-turn** (the chat is `working`, or `blocked` on the
  `qm rotate` permission, when it asks). It is started only by the user-invoked `/rotate` skill
  (`disable-model-invocation: true`) — keep it that way, or a chat could rotate itself unasked.
- Self-rotation needs the item's chat live in its GUI pane; a named session must be among the item's live
  ones; and the session must be the one the pane runs — its claude pid is the pane's `pane_pid` or a
  descendant (`Rotation#in_pane?`; an unknown pid passes), so a second live chat of the item in a Warp tab
  never sends `/exit` into the pane. Without a named session it takes the pane's own.
- An aside (`QM_ASIDE`) and a process that is no item's chat are refused before anything is sent.
- **Background work before `/exit`** (`Rotation#await_background`): claude answers `/exit` with
  a confirmation about running background agents/shells, which swallows the typed `/exit`. A click
  refuses up front; after the Stop it waited for, both live modes poll `ChatAttention#turn_for`.
- While the chat is `waiting` (non-watcher `BackgroundJobs` pending) nothing is typed and the job badge
  becomes "rotating: waiting for background work…" (`GuiJobs#relabel`).
- It proceeds once the state is `your_turn`/`none` and, if it was ever seen waiting, a turn ended after
  that — a newer `Stop` than the one seen while waiting, or an Esc (`since`) — because the notification
  wakes the chat for one more turn without a `UserPromptSubmit`.
- Bound: `BACKGROUND_TIMEOUT` (60 min from that Stop; sub-agents outlast the 20 min stop wait). On timeout,
  or when the chat's window disappears (the user exited by hand), it gives up untyped.
- A rotation is recorded just before the fresh session starts, so `carried` is exactly what its
  SessionStart injects (`injectable_notes`, read under the lock, so notes the wrap-up wrote count).
- `carried` records note *positions*: it relies on notes being append-only.
- A session a rotation was recorded from reports no context (`WorkItem#rotated_from?`): a closed chat's row
  shows no size and offers no second rotate.
- Nothing rewrites a running chat's earlier context (it would break the prompt cache); a mid-session
  context update, should one be added, goes in append-only (hook `additionalContext`). None exists today.

## Data

- Item frontmatter `rotations:`, oldest first: `{at, from, via: wrap-up|distill|self, carried: [note positions],
  decisions, open}` (`WorkItem#record_rotation`). The counts are frozen at rotation time; note texts are
  resolved by position when rendered.
- **Rotation dividers** in the chat history ([chats](chats.md)) sort between sessions by time and read
  "── rotated 14:02 · carried: 6 decisions, 2 open ──", expanding (collapsed by default) to the carried notes.
