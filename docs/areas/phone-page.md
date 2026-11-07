# Phone page

**Code:** `skills/work-items/SKILL.md`, `skills/work-items/page.html`
**Tests:** `tests/cli_overview.rs`, `tests/cli_board.rs`
**Depends on:** [work-items](work-items.md), [attention](attention.md), [side-panel](side-panel.md)

## What it does

On their phone the user talks to a qm chat through Claude's Remote Control; qm itself stays on
loopback and nothing new listens. The phone sees the work items through a published
artifact instead, filled by a chat running the `/work-items` skill.

**Snapshot** — `qm overview --json [PATH]` (`Overview`), mechanical, no model involved:
`{v, generatedAt, counts: {states, chats, shown, omitted}, rateLimits, items}`, each item
`{slug, title, state, project, branches, chat: {state, since, snoozed, waitingOn}, paneLive,
lastActivity, openNotes: [{position, stamp, text}], board}`.
- Chat state is `ChatAttention`'s; items without an entry read `none`, with activity from
  their newest session. `paneLive` comes from one `Tmux#sessions` listing.
- `openNotes` are the `open` ones among `WorkItem#injectable_notes`, so the page shows exactly
  the blockers a session gets injected.
- `rateLimits` is `RateLimits#payload` (see [side-panel](side-panel.md)).
- Order: in progress first, then fridge; within a state ChatAttention's rank (blocked, your
  turn, working, waiting, none), then newest activity, then slug. Resolved items are only
  counted.
- With PATH it writes atomically (temp file + rename) and prints a one-line summary; without,
  the JSON goes to stdout.

**The page** — `skills/work-items/page.html`, next to its skill since qm never serves it. It
is published once with `capabilities: {db: {rules: [{path: "", read: "view", write:
"owner"}]}}`, so only the user's own writes land. It reads one document, `overview/current`,
through `db.doc(...).onSnapshot`, re-reads it on focus and visibility, and re-renders
relative times every minute. It says when the snapshot was generated and, past 60 minutes,
"ask for a fresh one". Read-only: no button acts on anything. Under the tally a line
shows the usage limits like the GUI chip (`5h 42% · 2h15m │ wk 61% · 3d4h`, 50/80% colours,
greyed with "seen 8 h ago" past 6 h).

**Config** — `overview_artifact:` in `config.yml` holds the published page's URL;
`qm overview --url` prints it (exit 1 with a pointer while unset); `Overview.artifact_url`
reads it.

**Republishing** — `qm overview --page` prints the page file's path when its SHA-256 differs
from the one `qm overview --page-published` recorded in `overview-page.sha256`, else nothing.
The skill then reads the file and the artifact, republishes to the same URL with
`capabilities` omitted (so the db rule carries over), and records it.

**The `/work-items` skill** (`skills/work-items/SKILL.md`, model-invocable; the user links it
into `~/.claude/skills/`) writes the snapshot to a scratchpad file and `ArtifactData` `set`s it
by `file_path`, pinned to the document's version (read with `out_dir`). Its reply is the URL
plus the summary line. It also drives chats through the running GUI: `qm pane-start`,
`qm pane-resume`, `qm rotate SLUG [--close]` — then refreshes the page.

## Rules

- qm stays loopback-only: the phone reaches items through the artifact and chats through Remote Control, never through a new listener.
- The snapshot JSON never enters the chat's context: it travels by file path (`set` by `file_path`, `get` with `out_dir`).
- The snapshot fits one artifact db document (256 KiB cap): titles (160), note texts (280) and `waitingOn` (3 entries × 120) are clipped, at most 60 items, and the quietest fridge items are dropped until the JSON is under 200 KiB; `omitted` says how many.
- Write the snapshot atomically: the skill may hand the file over while a second run writes.
- The artifact never follows `page.html` by itself; the skill republishes when `qm overview --page` names it, before writing data.
- Republish with `capabilities` omitted so the owner-only write rule stays.
- The page is read-only; acting on items goes through `qm pane-start` / `pane-resume` / `rotate`, which need the running GUI. Rotating the skill's own chat is `/rotate`, which only the user starts.

## Data

- `overview/current` in the artifact's db — the latest snapshot (`v: 1`).
- `overview-page.sha256` — the page file as last published.
- `overview_artifact:` in `config.yml` — the page's URL.
