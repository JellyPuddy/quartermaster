# Linking

**Code:** `src/launcher.rs`
**Tests:** `tests/run_session_resume.rs`, `tests/sessions.rs`, `tests/cli_workspace.rs`, `tests/pane_follow.rs`
**Depends on:** [capture](capture.md), [work-items](work-items.md)

## What it does

Attaches each session to the work item it serves, and opens sessions for items. The
SessionStart hook (`hook::linked_work_item`) picks the item, in order:

1. **Already attached** — an item whose `sessions:` lists this id wins first, even over
   `QM_ITEM`: a resume must recognise its own history, and the launch env var outlives a
   mid-session move.
2. **`QM_ITEM=<slug>`** — the launcher contract: a session started with it links to that
   item unconditionally, over branch match. An unknown slug falls through to the next rule.
3. **Branch auto-match** — an item in the same project whose `branches` include the cwd's
   exact branch; a non-resolved item wins ties. No fuzzy matching: ambiguity is Claude's.

A matched session is attached and gets the **linked injection**: the item's digest
([work-items](work-items.md)) plus the work-item protocol — note at milestones with a kind
(the kind taxonomy, one kind per note, omit `--kind` for `decision`, don't repeat the date);
retag a handled `open` note by its `#n`; fold governing decisions into the Description;
update the state; reuse a status board already shown; refine a stale title; and re-link the
moment the work moves to another item. A project with a `dev_server:` adds the dev-server
commands (`qm work-on`, `qm pf-mode`); one with `pr_prerequisites: true` adds `qm pr-requires` ([prs](prs.md)).

An unmatched session gets the **unlinked injection**: the project baseline from cwd, a
shortlist of open items (`slug — title (project, branches, state)`), and the linking
protocol — continues an item → `qm attach <slug> --session ID`; substantial new work →
`qm new "Title" --project P --session ID --description …`, after sanity-checking the
project against the topic (ask the user on a suspected mismatch, e.g. a work-repo cwd on a
personal-tooling topic); trivial or throwaway → do nothing and don't mention tracking. Such
sessions sit in the inbox and age out.

An aside (`QM_ASIDE`) gets the digest with a note that it is deliberately unlinked and
must run no qm commands ([asides](asides.md)). A loose chat (`QM_LOOSE`) gets a loose
injection instead: no item unless the user asks, promote before changing code ([loose-chats](loose-chats.md)).

**Undoing a wrong auto-link**: the branch match is a guess (a session opened on a checked-out
branch to ask something unrelated). The linked protocol offers the same three-way exit:
continues another item → `qm attach <other>`; new work → `qm new --session`; trivial →
`qm detach SLUG --session ID` and stop mentioning tracking.

**Launching** (`launcher`):
- `qm start SLUG` / the viewer's ^N / GUI Start: a fresh `claude` with `QM_ITEM=<slug>` in
  `start_cwd` — the worktree checked out on the item's branch (newest branch first), else the
  project root, else the last session's cwd, else home.
- `qm resume SLUG` (`resume_plan`): the newest attached session that is resumable *and* has a
  cwd to resume from → `claude --resume ID`; else, if one is live, refuse; else **rehydrate**:
  a fresh `QM_ITEM` session at `start_cwd`, seeded by the injected digest — the path back
  after a transcript expires. `--session ID` narrows it to one session. The GUI's
  `resume-session` action resumes an inbox session in its own cwd (`session_resume_plan`).
- `--here` execs in the current terminal; otherwise a new Warp tab (`WarpTab`).
- The GUI's chat pane uses `chat_plan` (refuses while any of the item's chat sessions is
  live — one live chat per item), `fresh_chat_plan` (optionally with a first prompt as claude's
  argument), `aside_plan` / `aside_resume_plan` (`QM_ASIDE` set, `QM_ITEM` blanked), `loose_plan`
  (`QM_LOOSE` set, `QM_ITEM` blanked, the project's main checkout) and
  `attach_in_warp` ([chats](chats.md)). `QM_CHAT_COMMAND` swaps the program a pane runs.

**Issue-less lifecycle**: an item is born title-only, a branch gets linked when code starts,
the issue lands, `/adopt-worktree` renames the branch to `issue/<n>-…` and updates the
item's branch link (`qm link-branch`), and issue and PR then light up derived. Nothing else
is manual.

## Rules

- **A session belongs to one item.** Every attach (CLI `attach`, `new --session`, GUI attach,
  item-from-session) detaches it everywhere else (`work_item::detach_session_elsewhere`): a
  resume links to the *first* item listing the id, so a stale attachment is wrong.
- **`QM_ITEM` with an unknown slug falls through, never unlinks**: the var leaks from a
  launched session's env into everything it spawns — which is also why the tests unset it
  in `run_hook`.
- **`QM_ASIDE` beats every linking rule, `QM_ITEM` included**: an aside is never attached,
  not even by branch. `QM_LOOSE` likewise skips `QM_ITEM` and the branch match, unless the
  loose chat was promoted (its session, or an earlier one of the same id, is on an item).
- **A local automation's runs are never its chat** (`chat_session_ids`, through
  `run_log::session_ids_for`): they attach to the item through `QM_ITEM`, but `resume_plan` and
  `chat_plan` neither live-check nor pick them, so every caller — `qm resume` and the viewer,
  the GUI pane, Edit with Claude, adopt/restack/issue/PR-review starts — skips them. Only a
  session picked by id (`--session`, a session row) is resumed even when it is a run.
- **Never resume a live session** — it would fork. Resume refuses and says to switch to its
  tab; the chat pane reports `:live` and waits for it to end.
- **Resume from where the transcript is filed** (`resume_cwd`): `claude --resume` looks the
  transcript up by the cwd's project directory (path with every non-alphanumeric → `-`), and
  a worktree session's transcript lands under the main checkout's directory, while the
  worktree itself may be gone. Use the nearest existing ancestor of the recorded cwd that
  maps to the transcript's directory, else the recorded cwd if it exists.
- **Warp tabs open through tab configs, not launch configurations**: a launch configuration
  always opens a new window. qm writes `~/.warp/tab_configs/qm-launch.toml` (name, one pane
  with `directory` and `commands`) and opens `warp://tab_config/qm-launch` — by file stem,
  case-insensitive; an absolute path is accepted by `open` but silently does nothing.
  `QM_WARP_TAB_CONFIGS` moves the directory (tests).
- **The dev-server and pr-requires protocol lines are opt-in per project** (`pf_protocol_line`
  from `dev_server:`, `pr_requires_protocol_line` from `pr_prerequisites:`): every other project's
  sessions pay nothing for them; a broken config.yml turns them off, never the hook.
- **The protocol text is a per-session cost** (the kind taxonomy alone is ~440 tokens). If it
  must grow, trim it before trimming the item's own content: instructions repeat every
  session, notes don't.
- **Project is a cwd baseline, not truth**: Claude sanity-checks it against the topic and
  asks when it looks wrong; `qm move` fixes it later.

## Known limits

- A detached trivial session *resumed* on the same branch re-matches and re-attaches: branch
  matching keeps no per-session tombstone.
- Rehydration carries only what the digest carries (Description, the injectable notes,
  snapshot count); the rest is a `qm show` away.
