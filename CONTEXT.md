# Domain glossary

Living document: when a concept gets a name in code, it gets an entry here —
architecture reviews use these names for modules and seams.

- **Work item** — a curated unit of work (markdown file, `work-items/<slug>.md`):
  frontmatter state/project/branches/sessions, Description, Notes, Snapshots.
- **Session** — one captured Claude Code session (JSONL events keyed by session id).
- **Claim** — attaching a session to a work item is a *move*: the item claims the
  session and it is vacated everywhere else (`WorkItem#claim_session`). A session
  belongs to exactly one item; resumes re-link to the first item listing it.
- **Mainline branch** — `main`/`master`/`develop`: nobody's feature branch, so it
  never links a session to an item (`WorkItem::MAINLINE_BRANCHES`).
- **Note kind** — `open` (user-facing, always re-injected), `decision` (default),
  `history` (never injected). Decides what the SessionStart digest carries.
- **Headline note** — the one note a surface shows when it can show only one:
  newest open blocker, else newest non-history note (`WorkItem#headline_note`;
  the GUI card and the `qm show` header — hence the fzf preview — share it).
- **Attention** — the nudge system: degradation warnings (transcript nearing
  pruning), staleness, merged-PR resolve hints. Acknowledging is per-session
  (`ack`), silencing is per-item (`snooze`, grammar `Nd`/`turn`/`clear`).
- **Chat attention** — whose move it is in an item's live chat (`ChatAttention`):
  `blocked` (permission/question pending) → `your_turn` (Stop or Esc; loud until
  the user types or snoozes with `snooze turn`) → `working` → `none` (no live chat).
  Derived from the hook event fold (`EventLog`, `events.jsonl`) plus transcript
  vitals (`TranscriptVitals`: context size, cache warmth, Esc interrupts).
- **Turn** — one session's folded hook state: state, `since` (when it entered it),
  pending tool, last Stop/prompt timestamps.
- **Inbox** — captured sessions linked to no item and not dismissed; triage feeds
  claiming (`attach-session`) or item creation (`item-from-session`).
- **Tier** — what a session can still do: `live` (running), `resumable`
  (transcript exists), `expired` (pruned; rehydrate from notes), `uncaptured`.
