# Benchmarks

**Code:** `lib/quartermaster/benchmark_run.rb`, `lib/quartermaster/benchmark_pipeline.rb`, `lib/quartermaster/benchmark_report.rb`, `lib/quartermaster/gui_benchmark_actions.rb`, `lib/quartermaster/gui/js/benchmark.js`, `lib/quartermaster/gui/js/benchmark-table.js`, `lib/quartermaster/gui/css/benchmark.css`
**Tests:** `test/benchmark_run_test.rb`, `test/benchmark_report_test.rb`, `test/gui_benchmark_test.rb`
**Depends on:** [diff](diff.md), [stacks](stacks.md), [attention](attention.md), [work-items](work-items.md), [gui-shell](gui-shell.md)

## What it does

A benchmark run measures a branch against main on its project's benchmark database, planned by
an agent following a benchmark skill, and keeps the result in a run folder the GUI's benchmark
modal reads. It assumes a Rails app on Postgres (`bin/rails runner`, `createdb`).

**Settings.** A project turns benchmarks on in config.yml ([overview](../overview.md)):
`benchmark: {database, skill, notes}` (`ProjectSettings::Benchmark`). `database` is the
Postgres database a run reads (a word: letters, digits, `_`), or clones as its template;
`skill` is the folder whose `SKILL.md` and `bin/example_bench.rb` the agent follows; `notes`
(optional) are lines the prompt adds to the script instructions. Without both `database` and
`skill` the project has no benchmarks. Project names match exactly (`BenchmarkRun.enabled?`).

**Starting** (`BenchmarkRun#start(item, branch:, request:, model:)`, model `opus` or `sonnet`),
refused naming the setting when the item's project has none (`BenchmarkRun.settings!`).
The branch resolves as the diff pane's does (`BranchDiff#tip`). The **stages** are `main` (the
first existing `GitRepo::TRUNK_REFS`), then, for a branch in a gh-stack, one stage per layer from
the bottom up to and including the branch (named `#<pr>`, else the branch; ref local first, else
`origin/<branch>`), else the branch alone; each `{name, ref, sha}` at start. The **run id** is the
UTC second, `YYYYmmdd_HHMMSS`, with `_2`, `_3`… on a clash, so it is safe in a database name.
qm writes `benchmarks/<run id>/meta.json` and spawns the pipeline `qm bench-run <run dir>`
detached: its own process group, stdio appended to `pipeline.log`, so it outlives `qm gui`.

**The run folder** `benchmarks/<run id>/`: `meta.json` (`v: 1`, id, slug, project, database, root,
checkout, branch, request, model, prompt, startedAt, finishedAt, state, error, warning, pid, stages, head,
rerunOf), `events.jsonl` (the skill's progress events), `agent.jsonl` (the agent's stream-json),
`bench.rb`, `run.json` (`{cwd, clone}`), `bench.out` (the markdown table), `bench.log` (the
script's stderr), `plans/` (saved EXPLAIN plans), `verdict.md`, `pipeline.log`. meta.json is
always written whole (temp file renamed over it) under the folder's `.lock` flock. The pipeline,
cancel and re-run use meta's `database` (`BenchmarkRun.database`), so a config change never
retargets a started run; a meta without one (written before it was recorded) uses its project's.

**The pipeline** (`BenchmarkPipeline`), one step after another, each state written before its step:
1. `planning`: `env QM_SKIP=1 QM_BENCH_DIR=<dir> QM_BENCH_RUN=<id> claude -p <BenchmarkRun::PROMPT>
   --model <model> --allowedTools Read,Grep,Glob,Write,Edit,Bash --add-dir <dir> --output-format
   stream-json --verbose --strict-mcp-config` in the branch's checkout, stdout streamed to
   `agent.jsonl`. The prompt names the skill's `SKILL.md` and `bin/example_bench.rb` by path (the
   agent has no Skill tool), the branch, the stages, the run folder, the read-only URL, the
   clone rule and name, the `run.json` shape with the branch's checkout as `cwd`, the event
   contract, the user's request or "work out what this branch's changes make slower or faster",
   and the project's `notes`. It tells the agent to keep the example's dry mode and `realtime_ms`,
   and before stopping to run
   `BENCH_DRY=1 DATABASE_URL=<read-only URL> bin/rails runner $QM_BENCH_DIR/bench.rb` in
   `run.json`'s cwd and fix `bench.rb` until it exits 0. The agent writes `bench.rb`, the `plan`
   event and `run.json`, and measures nothing beyond that dry run. A missing `bench.rb`, a missing
   or unparseable `run.json` or a `cwd` that is no directory fails the run.
2. `measuring`: `env QM_SKIP=1 QM_BENCH_DIR=… QM_BENCH_RUN=… DATABASE_URL=<url> bin/rails runner
   <dir>/bench.rb` in `run.json`'s cwd, stdout to `bench.out`, stderr to `bench.log`. The URL is
   read-only (`default_transaction_read_only`), unless `run.json` says `clone: true`: then qm
   checks 20 GB free in the home volume (`df`), runs `createdb -T <database> <database>_<run id>`,
   uses that clone and drops it afterwards, also on failure.
3. `verdict`: `env QM_SKIP=1 claude -p <VERDICT_PROMPT + each case's why + the table> --model sonnet
   --tools "" --strict-mcp-config --no-session-persistence` → `verdict.md`. The prompt says timings
   move 20–40% between runs.

A failed command (agent, rails runner, createdb, verdict) sets `error` to `<step>: <cause> — see
<log>`, at most 300 chars (a long cause loses its front at a path or word boundary, marked `…`). The
cause is the first line of what that call wrote to stderr that looks like an exception (`\w*Error`,
`\w*Exception` or `:in '…': `) and is no `warning:` line, else its last non-empty line; the log is
the file holding that stderr (`bench.log`, else `pipeline.log`, which also keeps the stderr tail of
every failed step besides the agent's), or with empty stderr the step's stdout file. A failed
`dropdb` of the clone (after measuring, only once `createdb` made it, or a cancel's of a run that
was measuring; before that no clone exists) never touches `state` or `error`: it is logged to
`pipeline.log` and appended to meta.json's `warning` unless the warning already says the same (a
cancel and the dying pipeline both drop), `dropdb failed: <cause> — clone <database>_<run id> is
still on disk; drop it with: dropdb <that name> — see pipeline.log`, so a done run stays done
with its results.

Then `done` (or `failed` with `error`, at any step): a macOS notification "Benchmark done ·
<branch>" (or failed) through `TurnNotifier#announce` ([attention](attention.md)), whose click
runs `qm open-chat <slug> --benchmark <branch>` (the page gets `#chat=<slug>&benchmark=<branch>`),
and a `history` note on the item: the verdict on one line (or the error) and the run id.

**Liveness.** One rule, `BenchmarkRun.live?`, used by both `BenchmarkRun` and the payload's fold
(`BenchmarkReport`): a run is live while its state is not final (`done`, `failed`, `cancelled`)
and either its pid is a process whose command line (`ps -o command=`) names the run folder (a word
whose last path part is exactly the run id, so `<id>_2` is another run), or it has no pid yet and
started less than 30 s ago (`STARTING_GRACE`: the pid lands in meta.json just after the spawn, and a
second start must not slip into that window). A non-final run that isn't live shows as `failed`
("pipeline died") in `BenchmarkRun#effective` and in the payload; `#busy` names the live run
(`{id, slug, branch, state}`).

**Payload.** `GET /api/benchmark/<slug>?branch=B[&run=ID]` (`BenchmarkReport`, read-only, off the
action mutex) answers `{ok, enabled, branch, busy, runs, run}`: `enabled` only when the item's
project has benchmark settings; `busy` the live run machine-wide or null; `runs` this item and
branch's runs, newest first; `run` the asked one or the newest, folded from its folder: stages from meta, subjects from `subject`
events, one row per subject × case of the last `plan` event (plus any measured case it didn't
name) with cells keyed by stage from `case` events and their `ids` check; a cell not measured yet
is absent. `activity` is the agent's latest tool call (`TranscriptHistory.tool_line`) while
planning, from the stream's last 64 KB. `currentHead` is the branch's head now, `moved` when it
differs from the recorded head. `canRerun`: a final run that still has `bench.rb` and `run.json`,
whose every stage ref still resolves to its recorded sha. `logs` names the run's log files that
exist, in the order `bench.log`, `pipeline.log`, `bench.out`, `run.json`, `bench.rb`. Unknown fields
and event kinds are ignored; a line that doesn't parse is skipped. `GET
/api/benchmark-plan/<run-id>/<file>` returns one saved plan as text: a plain file name inside that
run's `plans/`, a run id matching the id pattern. `GET /api/benchmark-log/<run-id>/<name>` returns
the last 64 KB of one of those five files as text; any other name, a missing file or a run id that
doesn't match is a 404. Both are served off the action mutex, like the payload.

**Cancel** (`#cancel(id)`): state `cancelled` first, then `TERM` to the pipeline's process group
(agent or rails runner with it) when it is live, then `dropdb --if-exists --force
<database>_<run id>` (none when no database is known for the run). Measured cases stay in
`events.jsonl`. The dying pipeline sees the final state and writes nothing more, notifies nothing.

**Re-run** (`#rerun(id)`): a new run with `rerunOf: <id>` that copies `bench.rb`, `run.json` and
the plan event and starts at `measuring` (no agent), then the verdict.

**GUI actions** (`GuiBenchmarkActions`, POSTed to `/api/action` under the usual Origin rules, none
of them a `LoopbackGuard::LOCAL_ACTIONS`): `benchmark-start {branch, request, model}` (model
`opus` when empty) refuses an item whose project has no benchmark settings, naming the setting
(`BenchmarkRun.settings!`); `benchmark-start` and `benchmark-rerun {run}` answer `{ok, run: <new
id>}`, or, while a run is live, `{ok: false, error, busy: {id, slug, branch, state}}`.
`benchmark-cancel {run}` refuses a final run at once, then cancels on a `GuiJobs` job keyed
`benchmark-<id>` (the dropdb can take a while). All three are `GuiActions::UNLOCKED`: they never
hold the action mutex, since `BenchmarkRun` has its own start lock and meta.json flock. A state
build reads `BenchmarkRun.all` once and derives everything below from that list, never a meta.json
per item. The state payload's `benchmark` is the live run machine-wide (`BenchmarkRun#busy(metas)`)
or `null`; each item's `benchmarkable` says whether its project has benchmarks
(`BenchmarkRun.enabled?`), and its `benchmarked` maps each branch to that item's newest run whose
state is `done`, as `{id, finishedAt}` (`BenchmarkRun.finished_by_branch`) — `{}` for an item that isn't benchmarkable or has
none. `Gui.new(benchmarks:)` (through `GuiState#benchmarks`) is the seam tests use to pass a stub spawner.

**The page** (`gui/js/benchmark.js`, the results table in `gui/js/benchmark-table.js`, `gui/css/benchmark.css`). 🏁 (`benchmarkButton(item, branch)`) sits next to 📊
in the diff bar when the diff has a branch, and on the Workspace rail's selected node next to
Diff › ([stacks](stacks.md)), both only when the item is `benchmarkable`. It pulses while that
branch's run is live and dims while another branch's is (its title names it); otherwise, when
`benchmarked` has the branch, a green dot (`bm-btn-done`) and the title "Benchmarked <n ago> — open
for the results" mark the finished run. `noticeBenchmarkBusy` re-renders the diff bar when the busy
run or the diff branch's `benchmarked` entry changes; the rail is rebuilt by every state render. It opens a modal in branch stats'
look (`bs-body`, `bs-callout`, `bs-error`) on the newest run of that item and branch, or the start
view when there is none. The **start view** has the request textarea (empty: work it out from
the branch's changes), Opus (default) / Sonnet, and Start (⌘⏎); while another run is live it
shows "busy: <branch>", linking to that run's modal, and Start is disabled. The **run view**:
the state, model, duration, head and start; the stages as chips; a banner when the branch has
moved since; the run's `warning` as an amber banner first, in every state; the error of a failed
run; the verdict as a callout; while live, a spinner with
the step (the agent's activity line while planning); a folded "Plan & subjects" (the request,
each subject's about, each case's why); a folded "Logs" (when the run has any), closed unless
the run failed, with one tab per file in `logs` showing its tail in a `<pre>` scrolled to the
end (fetched when a tab opens; the first file on opening); the agent's stream is not among them;
and the results `<table>`, one row per subject × case, columns Subject, Case, one per stage,
Ids and speed. A stage cell holds the time (`∞ (>60 s)` in red on a timeout, a spinner while a
live run hasn't measured it), a Δ% chip against the first stage (green faster, red slower, grey
under 40%, "was ∞" when the base timed out), the query count and a ▸ that shows the saved
EXPLAIN plan in an overlay; Ids holds each stage's id check (✓ same, ✗ differ, – n/a); speed is
one log-scale bar per stage (1 ms to 60 s). Clicking a stage header sorts by its time, slowest
first, then fastest first, then back to plan order; Subject and Case sort A→Z, Z→A, plan order.
A timeout sorts slower than any time, an unmeasured cell last both ways, ties keep plan order,
and ▼/▲ marks the sorted column. The sort is kept per run id for the page's life, so it
survives the polling re-renders and reopening that run; the table scrolls sideways inside the
modal (its scroll position kept across re-renders) and the page never does. Buttons: the run
picker (this branch's runs), Cancel (live; confirms), ↻ Re-run script (final and `canRerun`,
disabled while busy), ✨ New benchmark (back to the start view), Close.
It polls the payload every 2 s while open on a run that isn't final; closing never stops a run.
A finished run's notification click lands as `#chat=<slug>&benchmark=<branch>`, which
`events.js` turns into the chat plus this modal.

## Rules

- **The owner OK'd this agent use** (the planning agent and the verdict call), as overview's "any
  new agent use needs the owner's OK" asks.
- **One run at a time, machine-wide**: a start or re-run while any run is live is refused, naming
  the busy run's branch, slug and id. Liveness comes from meta.json plus the pid's command line;
  there is no lock file to go stale.
- **Read-only unless the plan says clone**: the read-only URL is the default; only `clone: true`
  in `run.json` gets a writable database, and that is a clone, never the configured `database`.
- **Cancel and cleanup drop exactly `<database>_<run id>`**, never another database.
- **A re-run needs unmoved stages**: refused once any stage ref resolves to another sha than the
  original run recorded; a new benchmark is the way on.
- **qm never checks out a branch or creates a worktree for a run**: `run.json`'s `cwd` is the
  branch's own checkout (the run's `checkout`), and `bench.rb` loads main like a stage, evaluating
  origin/main's version of every staged file (the skill's Protocol step 2), never relying on the
  checkout for main's code.
- **A final state is never overwritten**: every pipeline write goes through a transition that
  refuses a final state, so a cancel wins over a pipeline still finishing.
- **Runs are never pruned.**
- Every external command (claude, rails, createdb, dropdb, the notification) goes through
  `CommandRunner`, whose `out:`/`err:` stream a long run to files; tests stub the runner, the
  spawner, the process lookup and the killer, so nothing real starts, measures or dies.
