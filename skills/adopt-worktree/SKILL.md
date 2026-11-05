---
name: adopt-worktree
description: Move finished worktree work into the main checkout - remove the worktree but keep its branch and check that branch out in the main repository. Optionally takes an issue number - then also rename the branch to issue/<number>-... and make sure every commit on it references "Resolves #<number>". Use when the user asks to "remove the worktree and check out the branch", "adopt the worktree branch", "move this to the main worktree", or wants worktree work continued in the main checkout.
---

# Adopt a worktree branch into the main checkout

Goal: the worktree directory is deleted, its branch survives, and the main
repository checkout ends up on that branch. Nothing is pushed.

The arguments may name the worktree (a path, as the qm GUI's Adopt button
passes it) and/or an issue number.

qm's settings live in `~/.claude/quartermaster/config.yml` (or
`$QM_ROOT/config.yml`): the project whose `root:` is this repository may set a
`test_db:` command, and the top level (or that project, overriding it) may set
an `ide_command:` (an argv list with a literal `PATH` placeholder). Steps 3, 5
and 6 use them when present.

## Critical gotcha

**Never use `ExitWorktree` with `action: "remove"` for this** — it deletes the
branch together with the worktree, losing the commits. Always exit with
`action: "keep"`, then remove the worktree directory manually.

## Steps

1. **Identify the worktree and branch.** If the session is inside an
   EnterWorktree worktree, you already know both. Otherwise find them with
   `git worktree list` (worktrees created by EnterWorktree live under
   `.claude/worktrees/`).

2. **Verify the work is committed.** `git -C <worktree-path> status --short`
   must show nothing except ignored/build artifacts (untracked `node_modules`
   etc. are fine — they're ignored). If real changes are uncommitted, commit
   them first (or ask the user).

3. **Check whether the IDE has the worktree open** (only when `ide_command` is
   set). JetBrains IDEs record their open projects in `recentProjects.xml`,
   rewritten within a minute of a project opening or closing, so the most
   recently written one belongs to the IDE in use:

   ```sh
   f=$(ls -t ~/Library/Application\ Support/JetBrains/*/options/recentProjects.xml | head -1)
   awk -v home="$HOME" '/<entry key="/{k=$0; sub(/.*<entry key="/,"",k); sub(/".*/,"",k)} /opened="true"/{gsub(/\$USER_HOME\$/,home,k); print k}' "$f"
   ```

   If the worktree path is among the printed paths, remember to move the IDE
   in step 5 — otherwise it is left on a directory that no longer exists. For
   another IDE, ask the user whether it has the worktree open.

   **If this session's own working directory is inside the worktree** (it was
   started there, not via EnterWorktree), removing it kills this session's
   shell. Do the issue rename/stamp below *first*, inside the worktree, then
   run steps 5-7 as one chained command that starts with `cd <main-repo>`,
   and finally tell the user to restart the chat (its cwd is gone).

4. **Exit the worktree session** (only if the session is currently in it):
   `ExitWorktree` with `action: "keep"`. This returns the session to the main
   repository and leaves the worktree + branch on disk.

5. **Move the IDE to the main checkout** (only if step 3 found the worktree
   open), *before* removing the worktree: run `ide_command` with `PATH`
   replaced by the main repository path. If the IDE asks whether to open it in
   this or a new window, tell the user to pick *This Window* so the worktree
   project closes.

6. **Remove the worktree directory** from the main repo. If the project sets
   `test_db:`, first drop the worktree's test databases:
   `<test_db> drop <worktree-path>`. Then
   `git worktree remove <worktree-path>`. If git refuses because of leftover
   ignored artifacts (e.g. installed `node_modules`), first confirm with
   `git -C <worktree-path> status --short` that nothing real would be lost,
   then use `git worktree remove --force <worktree-path>`.

7. **Check out the branch in the main repo:** `git checkout <branch>`. If this
   fails because of conflicting local changes in the main checkout, stop and
   report — don't stash or discard on the user's behalf.

8. **Verify and report:** `git worktree list` no longer shows the worktree, and
   `git log --oneline -3` shows the branch's commits. Do not push. If the IDE
   still had the worktree open, it may have recreated the directory with only
   its project folder (e.g. `.idea/`) in it — check, and if that's all there
   is, delete it.

9. **If the user gave an issue number:** rename the branch and stamp the
   commits — see below. Without an issue number, don't rename; at most mention
   that `worktree-<name>` doesn't match the `issue/<number>-<slug>` convention.

## Issue number given: rename + stamp `Resolves #<number>`

Do this after step 7 (or before step 5 when this session runs inside the
worktree — see step 3), on the adopted branch. The goal is
that every commit on the branch ends with `Resolves #<number>`, added by the
repo's own `prepare-commit-msg` hook when it has one that derives the number
from an `issue/<number>-...` branch name (it must be idempotent). Don't
reimplement the hook's logic by editing messages yourself.

1. **Rename the branch** so the hook can derive the number:
   `git branch -m issue/<number>-<slug>` (keep the descriptive part of the old
   name as the slug, e.g. `worktree-deep-links` → `issue/123-deep-links`).

2. **Check whether any commit is missing the footer:**

   ```sh
   base=$(git merge-base main HEAD)
   git log "$base"..HEAD --grep "Resolves #<number>" --invert-grep --format=%h
   ```

   No output → all commits already reference the issue; skip the rewrite and
   report that. (Skipping keeps the existing SHAs untouched.)

3. **Safety checks before rewriting:** this rewrites history, so the branch
   must not be pushed — `git rev-parse @{u}` must fail (no upstream). If it
   has an upstream, stop and ask. Also confirm the hook is installed
   (`.git/hooks/prepare-commit-msg` exists); if not, run the repo's hook setup
   (e.g. `lefthook install`) first. If the repo has no such hook, stop after
   the rename and say the commits were not stamped.

4. **Replay the commits through the commit hook.** `git cherry-pick` runs
   `prepare-commit-msg` on every commit it creates, and the branch is now
   named `issue/<number>-...`, so the hook appends the footer wherever it's
   missing:

   ```sh
   tip=$(git rev-parse HEAD)   # recovery point
   git reset --hard "$base"
   git cherry-pick "$base..$tip"
   ```

   If a pick fails, recover with
   `git cherry-pick --abort && git reset --hard "$tip"` and report.

5. **Verify:** the step-2 `--invert-grep` log now prints nothing, and
   `git log --format='%h %s' "$base"..HEAD` shows the same subjects as before.
   Do not push.

6. **Update the qm work item.** Renaming the branch breaks qm's branch link.
   If a `qm` work item references the old branch name (check `qm list`), swap
   it for the new one:
   `qm unlink-branch <slug> <old-branch> && qm link-branch <slug> issue/<number>-<slug>`.
   (Work items can link multiple branches — a stack — so only remove the one
   that was renamed.)
