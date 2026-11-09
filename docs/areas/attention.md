# Chat attention

**Code:** `src/event_log.rs`, `src/chat_attention.rs`, `src/turn_notifier.rs`, `src/transcript_vitals.rs`, `src/background_jobs.rs`, `src/chat_launch_commands.rs`, `gui/js/notify.js`
**Tests:** `tests/attention.rs`, `tests/attention_commands.rs`, `tests/chat_attention.rs`, `tests/chats.rs`
**Depends on:** [capture](capture.md), [chats](chats.md)

## What it does

Says whose move it is in every chat, and tells the user when one needs them.

- `hooks/record-event.sh` (see [capture](capture.md)) appends one slim line per
  `UserPromptSubmit`, `PostToolUse`/`PostToolUseFailure`, `PermissionRequest`, `Stop`/`StopFailure`
  to `events.jsonl`. `EventLog` folds it per session into a turn: state, `since`, tool,
  `prompt_ts`, `stop_ts`.
- `ChatAttention` turns the fold into one entry per item, for in-progress items plus any item
  with a live chat (SessionLog liveness). The item speaks through its most urgent live session.
  Order: 🔴 `blocked` → 🟠 `your_turn` → 🔵 `working` → ◐ `waiting` → ⚪ `none`, longest-waiting
  (`since`) first; a snoozed your_turn ranks between waiting and none.
- `TranscriptVitals` reads a transcript's tail (256 KB, grown ×4 until an assistant usage shows):
  context = the last assistant message's `input + cache_read + cache_creation` tokens (synthetic
  messages skipped); cache warm until that message's ts + 1 h when `usage.cache_creation` shows the
  1 h tier (newest message that created cache), else + 5 min; the newest interrupt entry.
- `qm attention` lists the chats first (state, wait, pending tool, `ctx 182k · cache warm 41m`),
  then the item nudges (degradation, staleness, merged PR — `Attention`, see [work-items](work-items.md)).
- `qm snooze SLUG turn` quiets the current your_turn (`turn_snoozed_at`): it sinks until a newer
  your_turn starts. `qm snooze SLUG clear` lifts it together with the date snooze. GUI: `z` on the row.
- `TurnNotifier` (a watcher thread in `qm gui`) raises notifications; the page shows them as browser
  notifications and keeps the tab title `(n) qm — work items`, n = blocked + unsnoozed your_turn.
- `qm open-chat SLUG` (`ChatOpener`) brings the GUI's tab in Arc to that chat — what a click on a
  macOS notification runs. `--benchmark BRANCH` adds `&benchmark=<branch>` to the `#chat=` hash,
  so the page opens that branch's benchmark modal too ([benchmarks](benchmarks.md)).
- `TurnNotifier#announce` raises a macOS notification straight away for news from outside the
  GUI (a finished benchmark run), on the same channel and click rules as a turn's.

## Rules

**Turn states**
- Prompt or tool use = working; `PermissionRequest` (permissions *and* AskUserQuestion) = blocked;
  `Stop` = your_turn. A prompt always restarts `since`.
- Blocked comes from `PermissionRequest` (fires ~0.1 s after `PreToolUse`), not `Notification`
  `permission_prompt` (lags ~6 s) or `idle_prompt` (unreliable).
- The failure events count as their success events: an approved tool that fails fires
  `PostToolUseFailure`, a turn ended by an API error fires `StopFailure`.
- A sub-agent's tool call (`agent` set) only resolves a block, back to the state before it:
  background sub-agents run on after the main Stop, and that is still the user's turn.
- **Esc fires no hook**: a working/blocked turn whose transcript holds a `[Request interrupted by user…]`
  entry newer than its last Stop and last prompt is your_turn since that entry (`ChatAttention#turn_for`).
  Event stamps are whole seconds, so a prompt in the same second as an interrupt can misread — accepted.
- Esc is read from the transcript, never from keystrokes in the terminal bridge: it also catches an
  Esc typed in a Warp attach, and the bridge stays a dumb pipe.
- A live chat with no events yet (opened, never prompted, or predating the hooks) is `none`.
- your_turn stays loud until the user types in that chat or snoozes it — no auto-dimming.

**Waiting on background work** (`BackgroundJobs`)
- A Stop with background work still out is `waiting`, not your_turn (`waiting · <description>`,
  quiet, ranked below working). Not applied after Esc — that is the user's own stop.
- A launch is a `toolUseResult` with `status: async_launched` (Agent: `agentId` + `description`;
  Workflow: `taskId` + `workflowName`), one carrying `backgroundTaskId` (Bash `run_in_background`,
  or a foreground Bash moved to the background at its timeout — that result has `timedOutAfterMs`),
  or a stopped sub-agent revived, which launches that id again: a SendMessage result carrying
  `resumedAgentId` (`{success, message: "Resuming agent …", resumedAgentId, revivedAgentId, pin}`),
  or the user resuming it from its transcript view, a `<task-notification>` with no `<status>` whose
  summary reads `Agent "<name>" was resumed by the user`. A revived agent is named by the
  description it was first launched with, else that `message` or `<name>`. A message queued to a
  still-running agent has no `resumedAgentId` and changes nothing.
- A shell's description and command come from the Bash `tool_use` its result answers (by
  `tool_use_id`; no description → the command's first line). The fold remembers only Bash calls
  still awaiting a result; only a `tool_result` entry answers (hook attachments name the id too).
- The end is the next note-less `<task-notification>` naming that id (other than a resume), or a
  TaskStop that stopped it. An interim notification, whose `<note>` says `the result below may be
  interim` (the sub-agent stopped with its own background work running; `<status>` is still
  `completed` and older ones' summary still says `finished`, so only the note tells), ends nothing:
  the job stays pending, its `seen_at` becomes that entry's time, and `MAX_AGE` counts from the last
  interim, its backstop if the sub-agent never resumes. One for an id not pending starts nothing.
  TaskStop writes no notification, only its main-chain result, whose `toolUseResult` is
  `{message: "Successfully stopped task: <id> (…)", task_id, task_type, command}` (`shell_id`
  accepted for `task_id`). A failed stop's `toolUseResult` is an error string and ends nothing.
  Hooks can't see either end: the wake-up fires no UserPromptSubmit, and SubagentStop isn't registered.
- **Watchers don't hold the turn**: an Agent or shell whose description has a word starting
  `watch`/`monitor`/`babysit`, or a shell running `gh pr checks … --watch` / `gh run watch`, leaves it your_turn.
- Kept that narrow: a bare `--watch` is a dev loop, an `until gh run view …` poll isn't recognised,
  a Workflow is never a watcher, bare "CI" isn't a watcher word ("Fix CI failure" is work). Monitor is ignored.
- Launches older than 12 h (since launch, or the last interim notification) stop counting (`MAX_AGE`): a restarted session loses its jobs without a
  notification, and a forgotten dev server can't hold `waiting` forever.
- The fold is incremental per transcript, a process-wide cache by byte offset.

**EventLog**
- Read `events.jsonl` only through `EventLog`: it grows forever, and the fold persists with its
  byte offset in `events-fold.json`, so a read parses only appended bytes.
- A partial last line waits for its newline; a replaced (new inode) or shrunk log refolds from 0.
- Sessions quiet for 30 days are dropped from the fold (`FORGET_AFTER`).

**Notifications** (`TurnNotifier`)
- The watcher stats `events.jsonl` every 1.5 s and, when it grew, folds it through its own
  `EventLog` and diffs each session's (state, since). The first check only takes stock.
- It reacts only to hook output, never to a page's absence — not a liveness timer.
- Triggers: entering `blocked` always notifies, with sound; a Stop notifies, silently, only when
  that turn ran ≥ 30 s (`prompt_ts` → `stop_ts`, `LONG_TURN`).
- Never: Esc interrupts, a turn that delegated to background work (`waiting`), a snoozed turn,
  asides. Every other session counts, GUI chat or not, loose chats included; an unlinked one is titled
  by its first prompt.
- The chat a notification names (`TurnNotifier.chat_of`) is the item's `slug`, else `loose`: the loose
  chat's tmux name (`loose--<id>`) for an unlinked session with a loose id. A plain unlinked session has neither.
- Channel: a pulse (`/api/pulse?visible=&focused=&chat=`) younger than 3 s from a visible page means
  the page shows it — a browser `Notification` (a click focuses the window and opens that chat in chat
  mode with its terminal focused: `openChat`, or `openLooseChat` for a loose one), or nothing when
  focused on that very chat.
- A hidden tab's pulse (`visible=0`) hands notifications back to macOS at once.
- macOS goes through `CommandRunner`: `terminal-notifier` when installed (PATH plus
  `/opt/homebrew/bin`, `/usr/local/bin`), else `osascript` with title and body as argv, never
  spliced into the script. A click on an osascript notification opens Finder — hence terminal-notifier first.
- terminal-notifier gets `-group qm-<slug>` (a newer notification replaces the older; an unlinked
  session groups by session id) and, for an item or a loose chat, `-execute` running
  `<this qm binary> open-chat <slug or loose name>` (an absolute path: the click runs with a bare PATH).
- `qm open-chat` drives Arc (`company.thebrowser.Browser`) by AppleScript and never launches it: the
  first tab on `http://127.0.0.1:<port>/` or `http://localhost:<port>/` gets `…/#chat=<slug>`
  (hash-only, no reload), is selected, and Arc comes to the front. URLs go in via `on run argv`.
- No such tab, Arc not running, or the script failing → `open` the URL in the default browser.
- The page opens a `#chat=<slug>` hash (an item's slug or a listed loose chat's name) on boot and on
  `hashchange` (`openChatFromHash`), then clears it with `history.replaceState` so a reload doesn't reopen it.
- The last 20 notifications (id, `page` flag) ride on `/api/state` and `/api/attention`; the page
  shows `page` ones newer than the newest it has seen, taking stock on its first state like the server.
- Browser permission is asked on the first click anywhere (browsers require a gesture).

## Data

- `events.jsonl`: `{v, ts, session_id, event, tool, agent}` per line (`agent` = sub-agent id, empty
  on the main thread). Append-only, never rewritten.
- `events-fold.json`: `{v, inode, offset, sessions: {id: {state, since, tool, prompt_ts, stop_ts, last_ts, before_block}}}`.
- Item frontmatter: `turn_snoozed_at` (turn snooze), `snooze_until` (date snooze).

## Known limits

- Whole-second event stamps: a prompt within the interrupt's second can misread as working.
- A poll loop waiting on CI that isn't named like a watcher holds the chat at `waiting`.
