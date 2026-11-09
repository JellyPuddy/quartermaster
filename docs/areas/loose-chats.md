# Loose chats

**Code:** `gui/js/loose.js`
**Tests:** `tests/gui.rs`
**Depends on:** [chats](chats.md), [linking](linking.md), [attention](attention.md), [asides](asides.md)

## What it does

A chat that belongs to no work item, by intent: a question about a project, asked in the GUI's chat
pane without making an item first.

- **Start**: the **+** in the chats list's header opens "New loose chat" (`newLooseModal`): a project
  (`projects` from the state), a "Start with" preset, an optional first prompt, and a model (claude's
  default or `Aside::MODELS`; the last choice is remembered per browser, `qm-loose-model` in localStorage).
  `loose-start {project, model?, prompt?, starter?}` → `LooseChat#start` → `Launcher#loose_plan`: the chat command
  (`QM_CHAT_COMMAND`) plus `--model <m>` and the prompt as claude's argument, in the project's main
  checkout (`ProjectMap#root_for`; home without one), with `QM_LOOSE=<id>` and `QM_ITEM` blanked. The
  id is 8 random hex digits; the tmux session is `loose--<id>` on the `qm` socket.
- **Starters** (`config.yml` `loose_starters:`, key → `label` + `prompt`; none by default): the
  state's `looseStarters` (`[{key, label}]`) fill the dialog's "Start with" (hidden when there are
  none). `LooseChat.kickoff` makes the first prompt the starter's `prompt`, then ` ask me what I want
  to know about them.` — or, with a typed first prompt, ` answer my question about them:` and the
  question. So a starter's prompt loads something and ends mid-sentence ("…give a one-line count of
  them and"). An unknown starter is refused, naming the configured ones.
- **From the CLI**: `qm loose [--project P] [--model M] [--starter NAME] ["first prompt"]` POSTs `loose-start` to the
  running GUI (no Origin, so `loose-start` is in `LoopbackGuard::LOCAL_ACTIONS`); without a GUI it
  prints the `cd <root> && QM_LOOSE=<id> QM_ITEM= claude …` line instead. The project defaults to the cwd's.
- **Listed** while its tmux session lives: `/api/state` and `/api/attention` carry `loose`
  (`LooseChat#chats` over the live tmux names: name, id, the newest session — the live one after a
  `/clear` — its project and cwd, and `ChatAttention#turn_for` state/since/tool). The chats list shows
  them under a **Loose** group with its count, after the item chats; rows are titled by the session's
  first prompt (the notifier's unlinked-title rule, `TurnNotifier.unlinked_title`), "New loose chat"
  until a transcript has one. A row opens in the normal chat pane (`chatSlug` = the tmux name,
  `renderLooseMain`): a header and the terminal, no item side panel, diff or history.
- **✕** (row and header, one click): `loose-close {id}` on a GuiJobs job keyed by the tmux name —
  types `/exit`, waits up to 5 s for claude to go, kills the tmux session, then dismisses every session
  of that id from the inbox (`SessionLog#dismiss`).
- **→ Work item** (row and header): a title dialog, prefilled with the row's title, with a **Tell the
  chat** checkbox (default on), then `loose-promote {id, title, tell}` → `LooseChat#promote`:
  `WorkItem.from_session` on the chat's newest session (project from its start; the main checkout's
  mainline branch is dropped), then `Tmux#rename("loose--<id>", slug)`, so the pane is the item's chat
  from then on. With `tell` the renamed pane is typed `LooseChat.told_line` ("This chat is now work
  item <slug>; run qm show <slug> and follow its work item protocol from here."), `send_enter` after
  `Rotation::TYPE_SETTLE`, and the reply carries `told`. A slug whose chat already runs keeps the
  loose name, the reply carries a `warning`, and nothing is typed.

## Rules

- A starter's kickoff is claude's argument, never typed into the pane, and qm makes no (issue-tracker
  or other) calls for it: the chat's own MCP tools do the loading.
- **Never linked**: with `QM_LOOSE` set `HookHandler#session_started` skips `QM_ITEM` and the branch
  match and logs the start with `loose: <id>` and no `work_item`; the injection says it is a loose chat
  by intent, must not create or attach an item unless the user asks, and must ask for → Work item before
  changing code. `QM_ASIDE` still wins over `QM_LOOSE`.
- **After promotion** the claude process keeps `QM_LOOSE`: a `/clear` or compaction restart whose own
  session, or an earlier session of the same loose id, is attached to an item is linked to that item
  as usual (linked injection), never logged loose again.
- **Counted for attention**, unlike an aside: `hooks/record-event.sh` and `hooks/snapshot-worktree.sh`
  run as for any session, `TurnNotifier` notifies it like an unlinked session but carries its tmux
  name (`loose`), so a click — browser or terminal-notifier's `qm open-chat loose--<id>` — opens that
  chat (`openLooseChat`: chat mode, terminal focused), and the tab title count includes loose rows
  that are blocked or your turn.
- **Never distilled**: it belongs to no item, so nothing distills it; once promoted it is an item
  session like any other. `qm grep` searches it like any session.
- **No state file**: the GUI lists a loose chat only while `loose--<id>` lives. While it does, its
  sessions are kept out of the `inbox` payload; once it dies they are ordinary inbox entries (Resume,
  New item, Dismiss).
- The tmux name has a double dash, which `WorkItem.slugify` never produces, so it cannot be an item's chat name.
- Every `CLAUDE*` variable is unset in the pane (`Tmux#open`'s scrub), as for item chats.
- ✕ types `/exit` only on the user's click; nothing ends a loose chat from a poll or state build.
- Promote types its line only when the user's click carries `tell: true`, and never after a failed
  promote, a kept loose name, or into a dead pane.

## Data

- `sessions.jsonl` start events carry `loose: <id>` (no `work_item`); `Session#loose_id` reads it,
  and listings show `loose:<id>` in the work-item column.
- tmux sessions `loose--<id>` on the `qm` socket.
