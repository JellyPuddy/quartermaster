# Asides

**Code:** `src/aside.rs`, `gui/js/aside.js`
**Tests:** `tests/gui.rs`
**Depends on:** [chats](chats.md), [linking](linking.md), [capture](capture.md)

## What it does

A one-off question beside an item's chat, without it becoming part of the item.

- **Aside drawer**: a drawer over the lower part of the chat view (header button **Aside**, or
  `Aside · n` with earlier asides; key `q`). It runs in a tmux session of its own, `<slug>--aside`
  (`aside`'s session naming), started by `aside::start`: the chat command plus `--model <m>`
  (picker: sonnet — the default — opus, haiku; `aside::MODELS`) at `start_cwd`, with
  `QM_ASIDE=<slug>` set and `QM_ITEM` blanked.
- The SessionStart injection is the item's digest under a header saying this is an aside, not the
  item's chat, and that it must not run qm commands; the user promotes answers themselves.
- **Close ✕** kills its tmux session (`aside-close`, idempotent). **Open in Warp** works as for the
  chat (`pane-warp` with the aside's session name). The page shows the drawer whenever the aside's
  tmux session is in `panes`; the drawer's terminal reattaches from the pulse tick like the chat's.
- **Promote** (`aside-promote`, `aside::promote`): the running aside's transcript's last assistant
  message that has text (its blocks rejoined by message id) becomes a `decision` note prefixed `aside:`,
  folded onto one line because a stored note is one line.
- **Earlier asides**: under the drawer's model picker, newest first, a card each with the question
  (`first_prompt`), the last answer (clamped, click to expand), when, the model as the picker's word,
  and ✓ promoted when a note equals its folded answer. Loaded on demand from `GET /api/asides/<slug>`
  (`aside::history`) because it reads every transcript; the state carries only `asideCount` (a tally of
  logged aside starts), which labels the header button.
- Per card: **Transcript** (the read-only session sheet, without Resume), **Reopen**, and **Promote**
  (`aside-promote {session}`: that aside's answer instead of the running one's).
- **Reopen** (`aside-reopen {session}`, `aside::reopen` → `launcher::session_resume_plan`):
  `claude --model <m> --resume <id>` in `<slug>--aside` under `QM_ASIDE`. `<m>` is the model of the
  transcript's last real assistant message (`aside::model_in`), because `--resume` alone falls
  back to the default model — no stored state, so old asides work too.
- Actions: `aside-open {model}` (an open aside is shown again: `attached`), `aside-close`,
  `aside-promote {session?}`, `aside-reopen {session}`; the state carries `asideModels` and each item's
  `aside` flag and `asideCount`.

## Rules

- **`QM_ASIDE` beats every linking rule**, `QM_ITEM` included: `hook::session_started` checks it
  before an already-attached session or a branch match. The start event is logged with `aside: <slug>`
  and no `work_item`, and nothing is attached. An unknown slug injects nothing.
- `hooks/record-event.sh` exits early under `QM_ASIDE`: an aside never reaches `events.jsonl`, gets no
  attention and raises no notification.
- `session_log::inbox` skips sessions whose start carries `aside` (`session_log::aside_for`).
- Never attached, an aside is not in the item's sessions or history and is never distilled. Any new
  per-session surface must honour the marker too.
- **Only Promote** carries an aside's answer to the item, as a note.
- Promote without a session takes the *live* aside only, and refuses when there is none yet: a click
  right after reopening, before the new SessionStart is logged, must not promote the closed aside's answer.
- One aside at a time per item: Reopen is refused while an aside runs, and needs a surviving transcript.
- Past asides show only in the drawer (loaded on demand) and resume only back into it, under the marker —
  never as a plain session (the Transcript sheet offers no Resume).
- Asides never move with `PaneFollowsSession`: the `<slug>--aside` tmux session keeps its name.
- `qm rotate --self` refuses inside an aside — only the item's own chat can rotate.
- Item usage/cost does count aside sessions (`ItemUsage`, see [side-panel](side-panel.md)).

## Data

- `sessions.jsonl` start events carry `aside: <slug>` (no `work_item`); that is the only record — no
  aside state in the work item.
- Promoted answers are ordinary `decision` notes starting `aside: `.
