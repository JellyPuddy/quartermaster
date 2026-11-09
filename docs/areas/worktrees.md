# Worktrees

**Code:** `src/cleanup.rs`, `src/git_repo.rs`, `gui/js/cleanup.js`, `src/cleanup_run.rs`
**Tests:** `tests/cleanup.rs`, `tests/cleanup_unread_drafts.rs`, `tests/issue_drafts.rs`
**Depends on:** [stacks](stacks.md), [gui-shell](gui-shell.md), [work-items](work-items.md)

## What it does

### Target worktree (`TargetWorktree`)

Which checkout "work on this item" means — shared by pf, the IDE, Terminal and Work on this, so the dev server and the IDE land in the same place. `resolve` says where and whether it must be created (creates nothing, but auto-links the item's stack branches); `materialize` also creates it.

- Precedence: an explicit `worktree:` wins outright (must exist); else a selected `branch:` (the GUI's one selected branch per item — `branch` on `/api/workspace/SLUG?branch=` and on the work-on / pf-switch / ide / terminal actions) → that branch's worktree, or a new one; else the default pick.
- Default pick: the item's stack top (`GhStack#stack_for`) in whatever worktree has it; no stack → the last linked branch that has a worktree (the others offered as `alternatives`); no linked branch with a worktree → a new worktree for the last non-mainline linked branch; no such branch → the main checkout.
- A target branch without a worktree gets one at `<repo>/.claude/worktrees/<branch-slug>` (`slug_for`: slashes and other characters → `-`, one flat segment, as `claude --worktree` makes) via `git worktree add`: the local branch when it exists; else, with `base:`, a new branch from `base` with `--no-track` (issue branches); else a new branch tracking `origin/<branch>`, fetched first when this clone has never seen it. A project with a `test_db:` command then gets `<test_db> prepare` run in the new worktree.
- When the stack top has no worktree but a sibling stack branch does, the target carries a warning saying a new worktree is made for the top instead of checking it out there.
- `materialize_branch(project, branch, base:)` does the same for a bare branch (a PR's head, an issue branch): its existing worktree, else a new one.

### Temp branches

`temp_branches` frontmatter, separate from `branches` so it never feeds stacks, PR status or the pf/IDE target. The SessionStart hook adds the branch of a linked session whose cwd is under `/.claude/worktrees/` (`HookHandler#record_temp_branch`: one path test plus one item write, failures logged and swallowed); `qm link-branch SLUG BRANCH --temp` does it by hand. A plain `link-branch` of a temp branch promotes it.

### Cleanup and sweep (`Cleanup`, `GitRepo`)

**Plan** (`Cleanup#plan_item` / `#plan_sweep`) is checklist data (`Plan#to_h`: `scope, summary, notes, entries`). Each entry: `id`, `kind` (worktree | branch | issue-draft), `repo`, `path`/`branch`, `item`, `title`, `db_names` + `db_status` (ok | unknown | n/a), `status` (ok | warn | blocked), `reasons`, `notes`, `ticked` (only ok entries start ticked), `requires` (a branch waits on the worktree it is checked out in).

- **Item scope**: worktrees by the item's branches, temp branches or session cwds (never the main checkout); local branches whose PR merged (PR state from the cache only); temp branches; the item's issue drafts (listed even without a repo root). A worktree or branch another open item also claims gets a warning "also used by / linked to open item '<slug>'".
- **Sweep scope**: every `<root>/.claude/worktrees/*` worktree and every `worktree-*` branch of every configured repo (each root once), plus every `issues/<slug>/` set. Anything an unresolved item claims is listed but never pre-ticked ("belongs to unresolved item").
- **Issue drafts**: one `issue-draft` entry per file in `issues/<slug>/`, id `issue:<slug>/<file>`, `title` the issue's (the file name for one that doesn't parse), `path` the file. With `number` → ok, ticked, note `#n`; without, or unparseable → warn ("never created on GitHub" / "doesn't parse: …", plus "N unsent comments" when issue-comment drafts point at it), unticked, forceable. Never blocked. Deleting goes through `IssueDrafts#delete` (the file, its `.prev` snapshot and its issue-comment drafts; the directory with its last file).
- **Checks**: blocked = git-locked (live `claude --worktree` agents lock theirs), pf serves it (`Pf#status`), a live session's cwd is inside, or a branch checked out in a worktree that stays. warn = uncommitted changes, untracked files, or commits found nowhere else (`GitRepo#unpreserved_commits`, up to a few listed by sha + subject; "couldn't check its commits" when git fails). An already-gone directory notes `git worktree prune`.
- **Bases** the commit check compares against: item worktrees against the item's other branches, `origin/<own branch>` and trunk; merged-PR branches against their `origin/` ref, the item's other branches and trunk; temp branches against the item's branches (+ their `origin/`) and trunk; sweep against trunk + every local branch that is not itself a `worktree-*` candidate (+ the worktree's own `origin/` branch). Trunk is whichever of `origin/main`, `main`, `origin/master`, `master` exist.
- **Preserved** = contained in a base, or a `git cherry` patch-equivalent among the commits the bases hold and the head doesn't, or — a squash merge — the head's whole change already merges cleanly into trunk or the head's own `origin/` upstream. Patch equivalence is answered once for all bases: one `rev-list` of the bases' commits, compared by touched paths, and only same-path pairs get `git patch-id --stable` (empty commits match each other, as in cherry). Paths and patch-ids are cached per sha on the `GitRepo`, so a head costs a fixed number of git calls however many bases there are.
- **Test DBs**: names from `<test_db> drop <path> --dry-run` (projects with a `test_db:` only); a missing or failing tool reads as `unknown` with a note, never an error.
- **Execute** (`Cleanup#execute(plan, selected:, force:, on_start:, on_outcome:)`): ticked ids plus an explicit force list for warn entries (force implies selected). Worktrees first: test DBs (`<test_db> drop <path>`; on failure the worktree is kept so a retry finds it), then `git worktree remove` (`--force` only when forced; `git worktree prune` when the directory is already gone). Then branches: `git branch -D` only once nothing has it checked out — a branch whose `requires` worktree wasn't removed is skipped. A deleted temp branch leaves every item's `temp_branches`. Then issue drafts. Each entry's outcome is removed / skipped (with why) / failed. `on_start`/`on_outcome` get `(entry|outcome, i, total)`, i 1-based over the entries acted on, and change nothing about what runs.
- **CLI**: `qm cleanup SLUG` / `qm sweep` print the plan; `--yes` runs the ticked entries; `--force PATH|BRANCH|SLUG/FILE` (repeatable; an issue draft also by its path) adds a warn entry. The outcome lines print once the run is over, on a terminal or not; there is no progress bar, and `--yes` never hands the run to anything else. A drafts file or issue file qm can't read as an issue never stops a plan or a run: it is a warn entry with the parse error (a tag, anchor, date, float or leading-zero number in the front matter reads that way: quote the value).
- **Resolve offers cleanup**: `qm state SLUG resolved` prints a one-line plan summary with the `qm cleanup` command; the GUI's state action replies with `cleanup` (the plan's `to_h`; a failing plan just isn't offered) and the page opens the checklist headed "Resolved. Clean up N worktrees?" (or "its branches?" / "its issue drafts?").
- **GUI** (`cleanup.js`): **Clean up worktrees…** in the side panel and **Sweep orphan worktrees…** in the toolbar's ⋯ menu open the checklist. `POST /api/cleanup-plan {scope: SLUG|"sweep"}` (read-only, off the action mutex) renders it: ok entries start ticked, ⚠ ones are unticked with their reasons and need **Force…** plus a second confirm ("Force remove"), ⛔ ones can't be ticked. Ticking a worktree ticks the ok branch that `requires` it; unticking drops it. Details show notes, test DB names, "goes only once its worktree does", and in a sweep the item. **Remove n** (danger-styled with forced entries) posts `cleanup {scope, selected, force}`, which re-plans and executes on a `GuiJobs` thread keyed by the scope, relabelling its badge `cleaning up i/total…`; the outcome arrives as a toast.
- `cleanup.js` also holds the chats list's `selectChat`/`moveChat` and terminal-focus-on-selection (see [chats](chats.md)).

## Rules

- qm never checks out a branch in an existing worktree — it may hold uncommitted work, often an agent's. A target branch without a worktree gets a new one under `<repo>/.claude/worktrees/`.
- A selected branch must be one the item links (`TargetWorktree.require_linked`); the actions refuse it before starting a job.
- A new issue branch starts from `base` with `--no-track`: its upstream is its own once pushed, never base.
- When `<test_db> prepare` fails after `git worktree add`, the error says the worktree exists and still needs it: a retry finds the worktree and skips that step.
- Every state-changing tool (`git worktree add`/`remove`/`prune`, `git fetch`, `git branch -D`, the `test_db` command) runs through `CommandRunner`; `GitRepo` only asks read-only questions. Tests use a stub runner and never add a real worktree.
- Cleanup never removes what it can't prove safe: a worktree goes only when clean and every commit of its HEAD is contained in, or has a `git cherry` equivalent in, a base; anything else needs an explicit per-entry force.
- pf-served, live-session and git-locked worktrees, and branches checked out in a worktree that stays, are blocked and can't be forced at all.
- `git branch -D` only after the commit check and once nothing has the branch checked out (re-checked at execute time). Remote branches are never touched.
- Sweep leaves the other `worktree-*` candidates out of the bases, so two orphans can't vouch for each other and both vanish.
- The squash check tries only trunk and the head's own upstream, not every keeper: GitHub squashes into trunk, and squash-checking each keeper cost two git calls per keeper per head.
- `unpreserved_commits` returning nil means git couldn't answer — never read that as "nothing to lose". With no base at all, nothing counts as preserved.
- Revisions go to git through stdin, so a branch named like a path (`docs`) is never mistaken for one.
- Execution trusts the plan's checks, so every caller that showed a plan to a human re-plans right before executing (the GUI's `cleanup` action does, on its thread): a worktree that turned dirty or got served since is skipped, not removed.
- A failing cleanup plan never fails the resolve; it just isn't offered.
- An unresolved item's issue drafts are listed in a sweep but never pre-ticked; issue-draft entries are never blocked.

## Data

- Work item frontmatter `temp_branches: [...]` — scratch branches cleanup may delete; never PR, stack or pf targets.
- `<repo>/.claude/worktrees/<branch-slug>` — where qm (and `claude --worktree`) puts new worktrees.

## Known limits

- Test DB names come from the `test_db` command's own naming rule; when the tool is missing they are `unknown` and nothing is dropped.
