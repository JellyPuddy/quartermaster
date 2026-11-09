Rules for every sub-agent of the delegate-build skill: builder, reviewer, integrator and watchdog. Your prompt points you here; follow all of it.

**Your worktree.** The permission layer refuses every Bash call that is not one plain command, whatever the command: a loop, a shell variable, `$(...)`, a heredoc, an `env VAR=` prefix, `cd X &&`, `git -C`, or a compound (`&&`, `;`, a pipe into an interpreter). A refused call is a wasted turn, so work in shapes it passes. Change files with Edit and Write, also for a one-line change. Write a multi-step script into your scratchpad with Write and run it as `ruby /abs/path.rb` or `python3 /abs/path.py`. Spell every path out literally; Bash calls start in your worktree, so paths are relative to it. List commits with one `git log --format='%h %s' <a>..<b>` instead of a `git show` per sha. Read a big file one `cat` or `sed -n '<a>,<b>p'` slice per call, so its output stays inline instead of spilling to a saved file.

**Your branch.** Commit on your worktree's own branch. Named branches belong to the orchestrator, which sets them after the run, so leave creating, renaming and checking out branches to it. Park unfinished work in a commit; the stash is shared across worktrees. To fold a fix into an earlier commit: `git commit --fixup=<sha>`, then `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash <base>`, written exactly so: this bare prefix with `true` is the one variable prefix the permission layer passes.

**Git hooks run on every commit.** When a hook fails, fix its cause and commit again. When the project has a qm `test_db` command (`qm config get projects.<project>.test_db`), `<test_db> prepare` gives a worktree its dependencies and test database; run it when a spec or a commit hook reports them missing.

**Waiting.** Your run ends the moment you stop making tool calls, so every wait is a foreground command with a timeout: `timeout 590 gh pr checks <n> --watch`, `timeout 590 bin/rspec <file>`. A Monitor or `run_in_background` wait outlives your run, so its result never reaches you.

**Processes.** Give every server, socket, port and data directory you start a per-worktree value; the main checkout's data stays untouched. Before handing back, stop every server, tmux server and background process you started, by its PID (a name pattern also kills other agents' runs), and say so in the handback.

**Budget.** Count your tool calls. At 150, finish the commit you are on and hand back: what is committed, what is left, and anything the next agent needs to know. A fresh agent with your handback does the rest better than you would at the end of a long context.

**Tests.** Test at the seams the plan names. For a behavior change, write the failing test first and watch it go red, then make it pass. Work in vertical slices: one behavior's test and code, then the next. Expected values come from an independent source of truth (the plan, a fixture, a hand-worked example); a test that recomputes them with the code under test is tautological and proves nothing.

**Verifying a commit.** Run the specs that cover what that commit changed, chosen per commit: a docs-only commit needs none, and a slow spec runs only for a commit that changes what it covers. CI runs the full suite on the branch's last commit, so a per-commit check only has to catch what that one commit could break.

**Follow-ups.** Your handback's `followUps` proposes work beyond your task, and most handbacks leave it empty. Each entry: a title, why, the plan decision number(s) it serves (or "none"), a self-contained draft brief, the task ids it needs, and a kind. Kind `gap` is an **integration gap**: code a numbered plan decision requires that falls between two tasks, one side built and the side that should call or feed it built by no task, because no brief owned it (a poster nobody calls, a store field one task writes and nothing reads). A checked gap may be built in this run. Every other proposal is kind `follow-up` and goes to the user: a nice-to-have, work no plan decision requires. A bug inside your own task is yours to fix. Propose sparingly, and finish your own task in full first.

**Blocked questions.** When you need a decision only the user can make, and your prompt gives an answers directory and a question id:
1. If you own a board row, set it to `blocked` with the question in `note` (see the board instructions).
2. `SendMessage` to `"main"`, with first line `BLOCKED <question id>: <the question>`, then the context the user needs to answer, and the answer file `<answers directory>/<question id>.md`.
3. Wait for that file: `timeout 590 sh -c 'until [ -f <answer file> ]; do sleep 5; done'`, repeated while it exits 124. These waits do not count toward your budget.
4. `cat` the file, set your row back to your start status, and continue with the answer. An answer starting with `STOP` means hand back what you have.
