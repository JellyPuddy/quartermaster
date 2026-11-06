# Local automations

**Code:** `lib/quartermaster/local_cron.rb`, `lib/quartermaster/run_log.rb`, `lib/quartermaster/automation_flows.rb`, `lib/quartermaster/chat_flow.rb`, `lib/quartermaster/pr_review_flow.rb`, `lib/quartermaster/automation_tick.rb`, `lib/quartermaster/automation_guard.rb`, `lib/quartermaster/run_lifecycle.rb`, `lib/quartermaster/tick_installer.rb`, `lib/quartermaster/local_automations.rb`, `lib/quartermaster/cli_local_automation.rb`, `lib/quartermaster/gui_local_automations.rb`, `lib/quartermaster/run_chats.rb`
**Tests:** `test/local_cron_test.rb`, `test/run_log_test.rb`, `test/automation_store_test.rb`, `test/automation_flows_test.rb`, `test/automation_tick_test.rb`, `test/automation_run_lifecycle_test.rb`, `test/tick_installer_test.rb`, `test/local_automation_cli_test.rb`, `test/gui_automations_test.rb`
**Depends on:** [automations](automations.md) (the store, the item, the GUI tab; `LocalSchedule`'s DST rule), [attention](attention.md) (a run's session state), [chats](chats.md) (tmux, the chat env), [prs](prs.md) (`PrReviewStart`), [gui-shell](gui-shell.md) (`CommandRunner`)

## What it does

A local automation is a scheduled Claude Code run on this machine, managed by qm. It shares the
cloud automations' store (`AutomationStore`), its `kind: automation` work item and its GUI tab;
its yml says `runner: local` instead of `cloud`. This page owns what only local ones have.

**Fields** — a `runner: local` yml holds `v`, `runner`, `name`, `cron` (5-field, Amsterdam local
time), `enabled`, `when` (the guard: a shell command), `flow` (default `chat`), `cwd` (default the
project's root), `model`, `allowed_tools` (a list), `permission_mode`, `timeout_minutes` (30) and
`notify` (`attention` or `quiet`, default `attention`); no `routine` or `remote_*`.
`AutomationStore.local_settings(record)` fills unset defaults without writing them;
`AutomationStore#write` checks a local record with `validate_local` and writes nothing when it
fails: an ArgumentError naming every bad field (`bypassPermissions`, an unknown `notify`, an
empty `flow`, a `timeout_minutes` not a positive whole number, `allowed_tools` not a list of
strings). Cloud records are never held to it.

**Schedule** — `LocalCron` reads a local automation's 5-field `cron` as wall-clock time in
Europe/Amsterdam, not UTC as cloud crons are. Fields take `*`, numbers, lists, ranges and steps
(`*/n`, `a-b/n`, `a/n` = from a to the field's end); weekday 0-7, 7 = Sunday. When day-of-month
and weekday both start with something other than `*`, a day matches either; else both must match.
- `due?(cron, since:, now:)` — a scheduled minute lies in `(since, now]`, any number counting as
  one; `last_due` gives the latest (UTC). A `since` over 8 days back counts from 8 days back.
- `next_after(cron, t)` — the first scheduled minute after `t`; nil when none in nine years.
- DST: a minute in the spring-forward gap never happens; one in the fall-back hour happens at two
  UTC instants, so checks an hour apart both find it due.
- `label` — "Mon, Thu 08:00" / "every day 08:00" for a simple `M H * * <weekdays>` cron (its
  `days` and `time` feed the picker; `to_cron(days:, time:)` writes back unshifted), else the cron
  plus "Amsterdam time". `error(cron)` — nil, or what is wrong with it.

**Flows** — every run goes through the flow its yml's `flow:` names, from `AutomationFlows`
(`chat` when unset): a `name`, the item fields it `needs` and `start(automation, item, prompt,
run_id:, session_id:)`, answering `{item_slug:, tmux:}` once a chat runs or `{waiting: reason}`
to stay queued. `AutomationFlows#problem(flow, item)` says why a flow can't take an item (unknown
flow, a `needs` field missing or blank; a cron run's nil item lacks every field); `#start` raises
it, and for a yml the store would refuse. Both pass claude `--session-id` (qm's uuid), then
`--model`, `--permission-mode` and `--allowedTools` (one comma-joined value, so the variadic flag
can't swallow the prompt) when set, before the prompt.
- `chat` (`ChatFlow`): tmux `<slug>--run-<run id>` on qm's socket running `Launcher#chat_command`
  (`QM_CHAT_COMMAND` swaps it) with `QM_ITEM=<automation slug>`, `CLAUDE*` unset by Tmux; cwd the
  yml's `cwd`, else the project root, else home. The prompt is `<slug>.prompt.md`, plus for an
  item a final `## Item`: JSON pretty-printed, or a guard's plain line as the line.
- `pr-review` (`PrReviewFlow`, needs `url`): the PR from the inbox cache, else `gh pr view URL
  --json …` (a failure raises). While its Review chat is live (`PrReviewStart#live?`) it answers
  `waiting: "Review chat for <repo>#<n> is open"`; else `PrReviewStart#start` opens the Review
  item's own chat with the flags before the kickoff and the automation's prompt appended.

**New and its brief** — `qm automation new TITLE --project P --runner local` (the GUI's `new` with
`runner: local`) makes the item and a yml with `runner: local`, `enabled: false`: nothing runs until
the user enables it. Its chat's brief (`AutomationChat.local_brief`) names both files (cron in local
time, the local fields) and the loop: edit → `qm automation tick --dry-run SLUG` (the guard's items,
nothing written) → `qm automation run SLUG` → read the run (`qm automation runs SLUG`, `qm
show-session`, the transcript) → refine; nothing to push. Its end is the cloud brief's
(`brief_tail`): decisions, house rules verbatim (with "Local automations"), description, notes.

**Run log** — `RunLog.new(slug)` is `automations/<slug>.runs.jsonl`, one `{v: 1, at, event, …}`
line per event, appended under a flock; a writer that decides from the fold (`enqueue_item`,
`enqueue_cron`, `retry`, `waiting`) re-reads it and appends under that one flock, so a tick and a
CLI or GUI write never both queue a key. Events:
- `queued` (`run_id`, `key`, `item`, `flow`, `trigger`: `cron` | `guard` | `manual` | `retry`);
  `started` (`run_id`, `session_id`, `tmux`, `item_slug`); `waiting` (`run_id`, `reason`, only
  when it changed); `finished`, `timed_out`, `closed` (`run_id`); `failed` (`run_id`, `error`);
  `retried` (`run_id`, `new_run_id`)
- `guard_error` (`error`, `item` when one item was refused); `guard_ran` (`items`, a clean run);
  `seen` (`keys` recorded without queuing: "mark existing as seen"); `checked` (the tick handled
  a due cron minute — only then, and the next tick's window starts at its `at`)

A run id is 8 lowercase alphanumerics (safe in a tmux name). The fold, re-read after each write:
`queue` (queued, not yet started or ended, oldest first, same second in log order); `live`
(started, not `finished`, `timed_out`, `closed` or `failed`); `recent(limit: 20)` (every run
that left the queue, newest start first, with `status` `live`, `finished`, `timed_out`, `closed`
or `failed`); `run(id)`, `seen_keys` (every `queued` and `seen` key), `cron_queued?`,
`last_guard_error` (the latest `guard_error`, cleared by a later `guard_ran`), `last_cron_check`.
Writers: `enqueue` (no dedupe), `enqueue_item` (nil for a seen key), `enqueue_cron(due:)` (nil
while a cron run is queued; key `cron:<due minute, UTC ISO>`, no item), `retry(run_id)` (an ended
run's key, item and flow as a new `retry` run, past dedupe; refuses unknown, queued or live runs),
and one per event.

**Tick** — `AutomationTick#call(now:)` is one scheduler pass. It takes `automations/tick.lock`
with a non-blocking flock (held: answers `{"locked" => true}` and does nothing), then:
1. Unless `automations.local_paused`, for each local automation not `enabled: false` with a
   valid `cron`: a scheduled minute in (its last `checked`, or the previous tick, or 300 s ago;
   now] runs its guard, or without one queues a cron run (`enqueue_cron`, coalesced); then
   `checked`. An empty `cron` is manual-only. A bad cron or yml goes in tick.json's `problems`.
2. The guard (`AutomationGuard`): `sh -c <when>` through the runner in the automation's cwd
   (`ChatFlow#cwd`) with `timeout: 60` (`CommandRunner` kills the process group). Each non-empty
   stdout line is an item: a JSON object with a string `key` as is, any non-JSON line
   `{key: line, line: line}`; a JSON object without one is a `guard_error` for that line. A
   non-zero exit or timeout is one `guard_error` ("guard failed: <stderr tail>"), nothing queued;
   a clean run writes `guard_ran`. An item the flow can't take (`AutomationFlows#problem`) is a
   `guard_error`; the rest go through `enqueue_item` (seen keys skipped), trigger `guard`.
3. Usage hold: `RateLimits#payload` with five-hour used ≥ `automations.local_hold_five_hour`
   (default 80) or weekly ≥ `automations.local_hold_seven_day` (90) holds every start ("5h at
   84%"). A snapshot whose five-hour window has reset, or none, holds nothing. Guards still run.
4. Lifecycle (`RunLifecycle`), paused, held or disabled alike, for every started run. A run is
   busy while its session (`SessionLog`, by qm's `session_id`) is live and `ChatAttention#turn_for`
   says working, waiting or none (no prompt yet); before its SessionStart hook ran, while its tmux
   lives. A run is typed into once its session had a second prompt (`EventLog`'s `prompts`).
   - A live run whose turn says `your_turn` (Stop, no background work) gets `finished`; one whose
     chat is gone gets `failed` (nothing killed), even if typed into: its session ended mid-turn
     ("session ended before the run finished"), or no session and no live tmux five minutes
     (`START_GRACE`) after `started` ("its chat ended before the session started").
   - A finished `--run-` chat not typed into, sat in `your_turn` for an hour (`CLOSE_AFTER`, from
     the turn's `since`), is killed and gets `closed`; a pr-review run stays `finished`.
   - A live, busy run not typed into, `timeout_minutes` (default 30) after `started`: `timed_out`,
     its `--run-` tmux killed (a Review chat stays open), a history note on the automation's item
     ("run <id> timed out after 30 min", plus "(its Review chat stays open)") and
     `TurnNotifier#announce` (a pr-review one's click opens that chat). A blocked run never times out.
5. Cap: `automations.local_max_running` (default 2) minus the live runs that are busy, counted
   after the lifecycle, so a run timed out frees its slot in the same tick.
6. Unless paused or held, queued runs of enabled automations start oldest-first across
   automations while slots are free: `AutomationFlows#start` with a fresh `SecureRandom.uuid`,
   then `started`. A flow answering `waiting:` leaves the run queued with that reason and uses no
   slot; one that raises marks the run `failed` with the message.
7. Writes `automations/tick.json` atomically: `{v: 1, last_tick_at, paused, held, running,
   max_running, problems}` (`AutomationTick.state` reads it, `{}` when missing).

`call` answers `{queued, started, failed, finished, closed, timed_out, problems, paused, held,
running, max_running}` (run lists as `[slug, run id]` pairs), or nil after an error (logged to
`qm.log` as `automation-tick`). `dry_run(slug)` runs the guard and answers `items` (new, the flow
takes them), `seen` (also a key repeated in the output) and `problems`, writing nothing; it raises
for an automation without a guard and on a failing guard. `queue_guard(slug, trigger: "manual")`
runs the guard now and queues its new items, returning their run ids.

**Tick installer** — `TickInstaller` owns the LaunchAgent `com.quartermaster.automation-tick` at
`~/Library/LaunchAgents/<label>.plist` (directory injectable). Its hand-written plist (values
XML-escaped): `ProgramArguments` = the `quartermaster` launcher's realpath, `automation`, `tick`;
`StartInterval` 300; `RunAtLoad` false; stdout and stderr appended to `<root>/automations/tick.log`;
`EnvironmentVariables` = the installing process's `PATH` (launchd's has no asdf shims, Homebrew,
tmux or claude) plus `QM_ROOT` when set. `install` writes the plist atomically, runs `launchctl
bootout gui/<uid>/<label>` (failure ignored, so a reinstall picks up a changed plist), then
`launchctl bootstrap gui/<uid> <plist>`; a failed bootstrap removes the plist and raises launchctl's
message. `uninstall` boots out and removes the plist. `installed?` = the plist exists.

**Service and CLI** — `Automations` hands every `runner: local` slug to `LocalAutomations` (no
network), drops local rows from `overview`, and `push`/`pull`/`adopt` refuse them: "<slug> runs
locally — nothing on claude.ai". `run` with a guard runs it now (`queue_guard`, trigger `manual`),
else queues one item-less run keyed `manual:<UTC ISO>`; `pause`/`resume` move the item to
`fridge`/`active` with a history note, `resume(skip_existing:)` first `mark_seen`s the guard's
current keys; `retry` is `RunLog#retry`; `delete` refuses while a run is live ("stop or finish its
runs first"), else removes files and run log and resolves the item. `CliLocalAutomation`: `list`,
`show` and `runs SLUG` read run logs (`list` skips the routines call when automations are off and no
row is cloud); `run` and `retry SLUG RUN_ID` then tick once and say why a run didn't start; `tick
[--dry-run [SLUG]]` (silent when idle off a terminal, uncounted by `FeatureUse`; the dry run writes
nothing); `install-tick [--print]` and `uninstall-tick` drive `TickInstaller`.

**GUI** — `GuiLocalAutomations` is the Automations tab's local part ([automations](automations.md)
owns the tab), never the network. A row: the schedule from `LocalCron` (`days`/`time` for the
picker, else `raw`), next run, queued and live counts, last run. The list's `local` header:
`installed` (the plist), `lastTickAt` and `held` from tick.json, `stale` when an enabled local
automation has gone 15 minutes without a tick, `paused` (config). The detail adds guard, flow, cwd,
notify, timeout, flags, the last guard error, the queue (subject, trigger, waiting reason) and
recent runs (subject, status, error; `chat` = its live `--run-` tmux or a pr-review run's Review
item; `resumable`, `retryable`). Verbs: `apply` saves only (weekdays + time become an unshifted
local cron; a raw cron must pass `LocalCron.error`); `pause`, `delete` answer at once; `resume`
(`skipExisting` = mark existing as seen), `run` and `retry` are `automation-<slug>` jobs, the last
two ticking once after queuing; `resume-run` is `ChatFlow#resume` (`--resume <session id>` under the
run's own tmux name); `install-tick`/`uninstall-tick` the `automation-tick` job; `local-pause`
writes `automations.local_paused` through `ConfigFile`. The claude.ai verbs refuse a local slug.
`RunChats` hands live run chats out with the loose chats (a `run` field, `quiet` for a `notify:
quiet` automation, left out of the title count; [loose-chats](loose-chats.md)), so "open chat"
and a run notification's `qm open-chat` reach the chat pane.

## Rules

- Stdlib only and no `ENV["TZ"]` switching: the offset comes from `LocalSchedule.offset_minutes`.
- Cron search is bounded: 8 days back (`due?`), nine years ahead (`next_after`), by local days.
- The run log is append-only; readers skip non-JSON lines and unknown events and fields.
- Never skip, dedupe at queue time: a key is consumed when queued; only `retry` queues it again,
  never automatically. Cron runs coalesce to one queued per automation; guard items queue FIFO.
- `bypassPermissions` is refused for local automations at the store and again when a flow starts.
- Only a `chat` run gets a `--run-` tmux session; a `pr-review` run lives in its Review item's chat.
- One tick at a time (the flock); a tick starts runs and never waits for them, and never raises
  out: one automation's error is recorded in `problems` and the others go on.
- qm only ever kills a `--run-` tmux session (closing or timing out), never an item's own chat,
  and never a run the user typed into; a typed-into run is theirs until its session ends.
- Lifecycle checks run every tick, paused or not: pausing stops new work, not the clean-up.
- `notify: quiet` keeps an automation's run sessions out of `ChatAttention` and `TurnNotifier`
  (`RunLog.quiet_session_ids`, see [attention](attention.md)); its runs still list in the tab and
  a timeout still notifies.
- Guards, `launchctl` and tmux go through the injected runner and `Tmux`; tests pass a
  `FakeRunner`, a `FakeTmux` and a temp LaunchAgents dir, never a real guard, claude, tmux or launchctl.
- The LaunchAgent changes only on the user's command or button; `installed?` reads only the plist.
- The tab's local part never calls the routines client; guards, ticks and launchctl run on
  `GuiJobs` threads, and a run chat starts only on a click (Run now, Retry, Resume).

## Data

- `automations/<slug>.runs.jsonl` — a local automation's run log, `v: 1` per line, append-only.
- `automations/tick.json` — the last tick (`v: 1`), replaced each tick; `automations/tick.lock` —
  its flock.
- `automations/tick.log` — the tick's stdout and stderr, appended by launchd.
- `~/Library/LaunchAgents/com.quartermaster.automation-tick.plist` — outside the data root.
- config.yml `automations.local_paused`, `local_max_running`, `local_hold_five_hour`,
  `local_hold_seven_day` (`ConfigSchema`, read through `ProjectConfig#local_automations`, a struct of `paused`, `max_running`, `hold_five_hour`, `hold_seven_day`).
