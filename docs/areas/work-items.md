# Work items

**Code:** `src/work_item.rs`, `src/atomic_file.rs`, `src/item_deletion.rs`, `src/note.rs`, `src/attention.rs`, `src/front_edit.rs`, `src/psych.rs`, `src/yaml_scalar.rs`, `src/sections.rs`, `src/distill.rs`
**Tests:** `tests/work_items.rs`, `tests/work_item_storage.rs`, `tests/item_deletion.rs`, `tests/psych_scalars.rs`, `tests/interop.rs`, `tests/show.rs`
**Depends on:** [capture](capture.md)

## What it does

A work item is the curated layer over the session log: one markdown file per piece of work,
`work-items/<slug>.md`, with a state (`in_progress` / `fridge` / `resolved`), a Description,
running Notes and distilled Snapshots. Human-editable by design — fixing a project is
editing one frontmatter line. Sessions attach to items ([linking](linking.md)).

- **Created** by `qm new "Title" [--project P] [--session ID] [--description …]` (slug from
  the title, state `in_progress`, `created` today, empty sections), or from a captured
  session (`WorkItem.from_session`: project and branch from its start event, a mainline
  branch `main|master|develop` left off, the session claimed). `qm retitle` never changes
  the slug; `qm describe SLUG TEXT` (or stdin) replaces the Description; `qm move` changes
  the project.
- **Deleted** by `qm delete SLUG [--force]` or the detail sheet's **Delete item…**
  (`item_deletion`, action `delete`), meant for an item made by accident: without force it is
  refused unless the item holds nothing beyond what `qm new` gives it — no notes, no linked
  branches, at most one session, no board, a Description empty or `_TODO_`. The refusal names
  what it holds ("3 notes, 2 branches, board set"); the GUI replies `needs_force` with `held`
  and offers **Delete anyway**. Deleting removes `work-items/<slug>.md` and kills `<slug>` and
  `<slug>--aside` on the qm socket through the runner (one not running is no error); its
  sessions simply become unlinked. Worktrees and branches are `qm cleanup`'s, run first;
  issue drafts of a deleted item are `qm sweep`'s.
- **Branches are the only stored git link** (`branches:`, a list — one item can span a
  gh-stack; `qm link-branch` appends, `qm unlink-branch` removes, a rename is unlink + link;
  legacy singular `branch:` still reads). The issue number is derived from the first
  `issue/<n>` branch; PR states are derived live per branch ([prs](prs.md)). No-project
  items usually have no branches. Linking a temp branch promotes it out of `temp_branches`.
- **Description** is the item's durable current truth. The injected protocol tells Claude
  to fold governing decisions into it, because notes age out of the injection and the
  Description doesn't.
- **Notes** (`qm note SLUG [--kind K] TEXT`) are one line each, `- YYYY-MM-DD [kind]: text`,
  appended in file order. Kinds (`NOTE_KINDS`):
  - `open` — unresolved and user-facing: a decision the user owes, a blocked dependency, a gap.
  - `decision` — a choice made or a finding about how the system is. The default.
  - `history` — how it got done: commits, rebases, push status, specs green.
  `qm retag SLUG POSITION KIND` (and the GUI's chip select) changes a kind afterwards;
  POSITION is the note's 1-based place in the file, shown as `#n` by `qm show` and the
  injected digest.
- **The injected digest** (`HookHandler#item_digest`, every session start on a linked item or
  aside): the frontmatter minus the session-id list (just a count), the full Description,
  `WorkItem#injectable_notes` oldest-first with their `#n`, a "(N of M …)" pointer to
  `qm show` when notes were left out, and Snapshots by count only.
- **`injectable_notes`**: drop `history`, then the newest `INJECTED_OPEN_NOTES` (3) `open`
  notes regardless of age, plus the newest `INJECTED_NOTES` (5) non-history notes.
  Because the window is a note count, filtering trades relevance, not size.
- **`headline_note`** (the one note a surface shows when it can show one): newest `open`,
  else newest non-history, else newest.
- **Snapshots** are distilled transcript summaries, one per session, under `## Snapshots` as
  `### <date> — session <id>` blocks — the rehydration source once a transcript is gone.
- **Distill** (`qm distill SLUG [--session ID] [--force]`, the viewer's ^T, the GUI action;
  `src/distill.rs`): headless `claude -p --model haiku`
  with `QM_SKIP=1` over the transcript, prompt asking for goal, what was done and decided,
  state left in, next steps in under 300 words. Bare distill covers every session carrying
  a degradation warning — one action clears an item's expiry warnings — else the newest
  resumable session. Not run automatically at session end (cost). In the GUI it
  runs on a server thread ([gui-shell](gui-shell.md)).
- **Resumability tiers** per session (`Session#tier`, [capture](capture.md)): live,
  resumable (`claude --resume` works from the recorded cwd), expired (only notes and any
  snapshot remain; resume = rehydrate, [linking](linking.md)).
- **Attention nudges** (`Attention`, shown by `qm attention` after the chats, in `qm show`,
  the viewer and as GUI badges), for unresolved items:
  - **degrade** — an attached session not live, not acked, not snapshotted, whose
    transcript expires (mtime + `cleanupPeriodDays` from `~/.claude/settings.json`,
    default 30) within 7 days.
  - **stale** — an `in_progress` item quiet 10+ days (`activity_at`: newest of the file's
    mtime and its sessions' last events — also the board's sort key), unless snoozed.
  - **pr_merged** — every linked branch's PR merged → "resolve?". State change stays manual.
- **Two dismissal verbs**: `qm ack SLUG [SESSION]` is permanent per transcript
  (`ack_degrade` on that session; a newer session warns independently); `qm snooze SLUG
  Nd|turn|clear` is per item — `Nd` mutes staleness until a date, `turn` quiets the chat's
  current your-turn ([attention](attention.md)), `clear` lifts both.

## Rules

- **Every mutation runs under one global exclusive flock** (`work-items/.lock`,
  `WorkItem.with_lock` / `#locked`) spanning the whole read-modify-write, re-reading the file
  before applying; reentrant per thread so compound moves (`claim_session`) nest. Without it
  a bulk distill's stale copy clobbered a concurrent note. A caller's own `find` before the
  mutation is only a handle: the mutator never writes from that copy, and an item deleted
  meanwhile raises "no work item" instead of being written back.
- **A save replaces the file whole** (`atomic_file::write`: temp file beside it, renamed over
  it, keeping the file's mode), so readers that take no lock — the GUI, the viewer, `qm list`,
  every mutator's first `find` — see the old or the new item, never a truncated one. A plain
  write let concurrent `qm note`s fail with "malformed work item file".
- **The stored note format is parsed and written only by `Note`** (`NOTE_LINE`). The kind
  marker is omitted for the default, so pre-kind notes and ordinary notes read identically —
  no migration was needed.
- **An untagged or unrecognised marker means `decision`**, never a dropped note: the parse
  runs inside the hook, and a decision vanishing from injection costs more than mechanics
  aging out.
- **`open` notes ignore recency**: an item's blockers must not age out of the injection.
- **Nothing un-tags a resolved `open` note**: `qm retag` is the manual fix and the protocol
  tells Claude to use it; `INJECTED_OPEN_NOTES` bounds the damage when it's forgotten.
- **Notes are append-only and addressed by position**: rotations record carried notes by
  position ([rotation](rotation.md)), so never reorder or delete note lines.
- **The digest is a per-session token budget**: a long item's full note history once cost
  ~3,700 tokens every session start. Keep the session-id list, history notes and snapshot
  text out of it.
- **`qm note` strips a leading `YYYY-MM-DD:`** from the text — qm stamps the date itself.
- **One snapshot per session**, enforced in storage (`add_snapshot` replaces that session's
  block). A second distill raises `AlreadyDistilledError` unless forced; the GUI turns it
  into a confirm and retries with force, the viewer just shows the error.
- **Distill input is the transcript's tail**: 400 kB, halved on "Prompt is too long" (reported
  on stdout, exit 1) down to a 50 kB floor — dense JSONL can overflow haiku.
- **The merged-PR nudge waits for the whole stack**: one merged bottom PR means nothing. A
  PR-less branch gone locally and on origin is ignored (a forgotten unlink after a rename
  would block the nudge forever); a merged PR's deleted branch still counts.
- **Resolving clears the item's diff viewed marks** ([diff](diff.md)).
- **Deleting rewrites no log**: `sessions.jsonl`, `events.jsonl` and `board-writes.jsonl` keep
  every line that names the slug, and the guard check and the file removal run under the
  work-item lock, so a note landing meanwhile is seen.
- **`pf_mode` needs a dev server**: only an item whose project has `dev_server:` in config.yml
  takes one, and only one of that server's `modes`; anything else is refused naming the setting.

## Data

`work-items/<slug>.md`: YAML frontmatter, then `## Description`, `## Notes`, `## Snapshots`.

| Field | Meaning |
|---|---|
| `v` | schema version (1); readers tolerate unknown fields |
| `title`, `state`, `project`, `created` | basics; `project` baseline from cwd, correctable |
| `branches` | linked branches, stack bottom → top |
| `temp_branches` | scratch branches cleanup may delete; never PR/stack/pf targets ([worktrees](worktrees.md)) |
| `sessions` | `[{id, ack_degrade?}]` |
| `board`, `board_answers_dir` | the item's status board and its blocked-answer dir ([side-panel](side-panel.md)) |
| `pf_mode` | dev-server projects only; absent = the server's `default_mode` |
| `rotations` | `[{at, from, via, carried, decisions, open}]`, oldest first ([rotation](rotation.md)) |
| `snooze_until`, `turn_snoozed_at` | staleness mute date; your-turn quiet time |

## Known limits

- Transcripts degrade by design; distill preserves what matters and is never automatic.
- A note's kind is whatever its writer chose; a stale `open` stays injected until retagged.
