# Local automations

**Code:** `src/run_chats.rs`, `src/local_cron.rs`, `src/automation_flows.rs`, `src/chat_flow.rs`, `src/pr_review_flow.rs`, `src/automation_tick.rs`, `src/automation_guard.rs`, `src/run_lifecycle.rs`, `src/tick_installer.rs`, `src/run_log.rs`, `src/run_fold.rs`, `src/random_id.rs`
**Tests:** `tests/tick_installer.rs`, `tests/run_chats.rs`, `tests/quiet_runs.rs`, `tests/automation_config.rs`, `tests/automation_flows.rs`, `tests/automation_guard.rs`, `tests/automation_tick.rs`, `tests/automation_run_lifecycle.rs`, `tests/local_cron.rs`, `tests/run_log.rs`, `tests/automation_store.rs`
**Depends on:** [automations](automations.md) (the store, the item; `local_schedule`'s DST rule), [work-items](work-items.md)

## What it does

A local automation is a scheduled Claude Code run on this machine, managed by qm. It shares the cloud
automations' store (`AutomationStore`) and its `kind: automation` work item; its yml says `runner: local`
instead of `cloud`. This page owns what only local ones have.

**Fields** — a `runner: local` yml holds `v`, `runner`, `name`, `cron` (5-field, Amsterdam local time),
`enabled`, `when` (the guard: a shell command), `flow` (default `chat`), `cwd` (default the project's root),
`model`, `allowed_tools` (a list), `permission_mode`, `timeout_minutes` (30), `notify` (`attention` or
`quiet`, default `attention`) and `repos` (`owner/name` list, pr-review); no `routine` or `remote_*`.
`local_settings(record)` fills unset defaults without writing them; `AutomationStore::write` checks a local
record with `validate_local` and writes nothing when it fails: an error naming every bad field
(`bypassPermissions`, an unknown `notify`, an empty `flow`, a `timeout_minutes` not a positive whole number,
`allowed_tools` not a list of strings, `repos` not a list of `owner/name` strings). Cloud records are never
held to it.

**New and its brief** — `automation_chat::create(…, "local")` makes the item and a yml with `runner: local`,
`enabled: false`: no cron or guard until the user enables it, but a manual run works. Its brief
(`local_brief`) names both files and the loop: edit → `qm automation tick --dry-run SLUG` (guard items,
nothing written) → `qm automation run SLUG` → read the run (`runs SLUG`, `qm show-session`) → refine. Its end
is the cloud brief's `brief_tail` (decisions, house rules with "Local automations", notes).

**Run chats** — `run_chats::chats(panes, dir, attention)` shapes the live `<slug>--run-<id>` tmux session
names as the chats list's loose rows with a `run` field (`quiet` for a `notify: quiet` automation, so the
page leaves them out of its whose-move count), titled "<automation name> · <subject>" with the session's
state; `by_session(dir)` maps a session id to its run chat (tmux, automation, run, title, quiet) for
attention and notifications. A pr-review run has no `--run-` chat: it shows as its Review item.

**Schedule** — `local_cron` reads a local automation's 5-field `cron` as wall-clock time in
Europe/Amsterdam, not UTC as cloud crons are. Fields take `*`, numbers, lists, ranges and steps (`*/n`,
`a-b/n`, `a/n` = from a to the field's end); weekday 0-7, 7 = Sunday. When day-of-month and weekday both
start with something other than `*`, a day matches either; else both must match.
- `due(cron, since, now)` — a scheduled minute lies in `(since, now]` (any number count as one; `since` at
  most 8 days back); `last_due` gives the latest (UTC). `next_after(cron, t)` — the first scheduled minute
  after `t`; none in nine years.
- DST: a spring-forward-gap minute never happens; a fall-back-hour one is due at both UTC instants.
- `label` — "Mon, Thu 08:00" / "every day 08:00" for a simple `M H * * <weekdays>` cron (`days` and `time`
  feed the picker; `to_cron(days, time)` writes back unshifted), else the cron plus "Amsterdam time".
  `error(cron)` — none, or what is wrong with it.

**Flows** — every run goes through the flow its yml's `flow:` names, from `automation_flows` (`chat` when
unset): a name, the item fields it needs and `start(automation, item, prompt, run_id, session_id)` →
`Reply::Started {item_slug, tmux}` once a chat runs, or `Reply::Waiting(reason)` to stay queued.
`problem(flow, item)` says why a flow can't take an item (unknown flow, a needed field missing or blank; a
cron run's null item lacks every field); `start` fails with it, and for a yml the store would refuse. Both
pass claude `--session-id` (qm's uuid), then `--model`, `--permission-mode`, `--allowedTools` (one value, so
it can't swallow the prompt) when set.
- `chat` (`chat_flow`): tmux `<slug>--run-<run id>` on qm's socket running the chat command
  (`QM_CHAT_COMMAND` swaps it) with `QM_ITEM=<automation slug>`, `CLAUDE*` unset by `Tmux`; cwd the yml's
  `cwd`, else the project root, else home. The prompt is `<slug>.prompt.md`, plus for an item a final
  `## Item`: JSON pretty-printed, or a guard's plain line as the line.
- `pr-review` (`pr_review_flow`, needs `url`): reviews only a PR whose repo `repos` lists (any case; no
  list, none) — the prompt-injection guard. `automation_flows::refusal(flow, record, item)` says why not
  (none for a flow without the rule); `start` checks it first, failing with `FlowError::Refused`. The PR
  comes from the inbox cache, else `gh pr view URL --json …` (a failure fails the run). While its Review
  chat is live (`pr_review_start::live`) it answers `Waiting("Review chat for <repo>#<n> is open")`; else
  `pr_review_start::start` opens the Review item's chat, flags before the kickoff, prompt after.

**Guard** — `automation_guard::run(command, cwd)`: `sh -c <when>` in the automation's cwd (`chat_flow::cwd`)
with a 60 s limit (`call_bounded` kills the process group). Each non-empty stdout line is an item: a JSON
object with a string `key` as is, any non-JSON line `{key: line, line: line}`; a JSON object without one is
a problem for that line. A non-zero exit or timeout fails the whole guard ("guard failed: <stderr tail>").

**Tick** — `AutomationTick::call(now)` is one scheduler pass. It takes `automations/tick.lock` with a
non-blocking flock (held: answers `Tick::Locked` and does nothing), then:
1. Unless `automations.local_paused`, for each local automation not `enabled: false` with a valid `cron`: a
   scheduled minute in (its last `checked`, or the previous tick, or 300 s ago; now] runs its guard, or
   without one queues a cron run (`enqueue_cron`, coalesced); then `checked`. An empty `cron` is
   manual-only. A bad cron or yml goes in tick.json's `problems`.
2. The guard (**Guard** above) in the automation's cwd. An item the flow can't take (`problem`) is a
   `guard_error`; one it refuses (`refusal`) goes to `refuse_item` (reported once, never queued); the rest
   go through `enqueue_item` (seen keys skipped), trigger `guard`. A failed guard is one `guard_error`,
   nothing queued; a clean run writes `guard_ran`.
3. Usage hold: the rate-limits snapshot with five-hour used ≥ `automations.local_hold_five_hour` (80) or
   weekly ≥ `automations.local_hold_seven_day` (90) holds every start ("5h at 84%"); a reset five-hour
   window, or no snapshot, holds nothing. Guards still run.
4. Lifecycle (`run_lifecycle`), paused, held or disabled alike, for every started run. A run is busy while
   its session (`SessionLog`, by qm's `session_id`) is live and `ChatAttention::turn_for` says working,
   waiting or none (no prompt yet); before its SessionStart hook ran, while its tmux lives. A run is typed
   into once its session had a second prompt (the event fold's `prompts`).
   - A live run whose turn says `your_turn` (Stop, no background work) gets `finished`; one whose chat is
     gone gets `failed` (nothing killed), even if typed into: its session ended mid-turn ("session ended
     before the run finished"), or no session and no live tmux five minutes (`START_GRACE`) after
     `started` ("its chat ended before the session started").
   - A finished `--run-` chat not typed into, sat in `your_turn` for an hour (`CLOSE_AFTER`, from the
     turn's `since`), is killed and gets `closed`; a pr-review run stays `finished`.
   - A live, busy run not typed into, `timeout_minutes` (30) after `started`: `timed_out`, its `--run-`
     tmux killed (a Review chat stays open, and the item's note "run <id> timed out after 30 min" says so)
     and a notification, quiet or not. A blocked run never times out.
5. Cap: `automations.local_max_running` (default 2) minus the live runs that are busy, counted after the
   lifecycle, so a run timed out frees its slot in the same tick.
6. Unless paused or held, queued runs start oldest-first across automations while slots are free (of a
   disabled automation only its `manual` and `retry` runs): `flows::start` with a fresh uuid, then
   `started`. A flow answering `Waiting` leaves the run queued with that reason and uses no slot; one that
   fails with `Refused` marks it `refused`, any other error `failed`, with the message.
7. Writes `automations/tick.json` atomically: `{v: 1, last_tick_at, paused, held, running, max_running,
   problems}` (`automation_tick::state` reads it, empty when missing).

`call` answers the `Summary` (`queued`, `started`, `failed`, `finished`, `closed`, `timed_out` as `(slug, run
id)` pairs, `problems`, `paused`, `held`, `running`, `max_running`; `to_json` shapes it for the CLI), or none
after an error (logged to `qm.log` as `automation-tick`). `dry_run(slug)` runs the guard and answers `items`
(new, the flow takes them), `seen` (also a key repeated in the output) and `problems` (refusals too),
writing nothing; it fails for an automation without a guard and on a failing guard. `queue_guard(slug,
trigger)` runs the guard now and queues its new items, returning their run ids.

**Tick installer** — `TickInstaller` owns the LaunchAgent `com.quartermaster.automation-tick` at
`~/Library/LaunchAgents/<label>.plist` (directory injectable). Its hand-written plist (values XML-escaped):
`ProgramArguments` = the `quartermaster` launcher's realpath, `automation`, `tick`; `StartInterval` 300;
`RunAtLoad` false; stdout and stderr appended to `<root>/automations/tick.log`; `EnvironmentVariables` = the
installing process's `PATH` (launchd's has no asdf shims, Homebrew, tmux or claude) plus `QM_ROOT` when set.
`install` writes the plist atomically, runs `launchctl bootout gui/<uid>/<label>` (failure ignored, so a
reinstall picks up a changed plist), then `launchctl bootstrap gui/<uid> <plist>`; a failed bootstrap removes
the plist and fails with launchctl's message. `uninstall` boots out and removes the plist. `installed` = the
plist exists.

**Run log** — `RunLog::new(slug, dir)` is `automations/<slug>.runs.jsonl`, one `{v: 1, at, event, …}` line
per event, appended under a flock; a writer that decides from the fold (`enqueue_item`, `enqueue_cron`,
`retry`, `waiting`, `refuse_item`) re-reads it and appends under that one flock, so a tick and a CLI or GUI
write never both queue a key. Events:
- `queued` (`run_id`, `key`, `item`, `flow`, `trigger`: `cron` | `guard` | `manual` | `retry`); `started`
  (`run_id`, `session_id`, `tmux`, `item_slug`); `waiting` (`run_id`, `reason`, only when it changed);
  `finished`, `timed_out`, `closed` (`run_id`); `failed` (`run_id`, `error`); `retried` (`run_id`,
  `new_run_id`); `refused` (`run_id`, `reason`; an unqueued item's too)
- `guard_error` (`error`, `item` when one item was refused); `guard_ran` (`items`, a clean run); `seen`
  (`keys` recorded without queuing: "mark existing as seen"); `checked` (the tick handled a due cron minute
  — only then, and the next tick's window starts at its `at`)

A run id is 8 lowercase alphanumerics (`random_id`; safe in a tmux name). The fold, read fresh on each
call: `queue` (queued, not yet started or ended, oldest first, same second in log order); `live` (started,
not ended); `recent(limit)` (every run that left the queue, newest first, `status` `live`, `finished`,
`timed_out`, `closed`, `failed` or `refused`, the reason as `error`); `run(id)`, `seen_keys` (every
`queued`, `refused` and `seen` key), `cron_queued`, `last_guard_error` (the latest `guard_error`, cleared
by a later `guard_ran`), `last_cron_check`. Writers: `enqueue` (no dedupe), `enqueue_item` (none for a seen
key), `refuse_item` (same dedupe; a `refused` run that never queues), `enqueue_cron(due)` (none while a
cron run is queued; key `cron:<due minute, UTC ISO>`, no item), `retry(run_id)` (an ended run's key, item
and flow as a new `retry` run, past dedupe; refuses unknown, queued or live runs), and one per event.

## Rules

- `bypassPermissions` is refused for local automations at the store and again when a flow starts.
- pr-review never runs outside `repos` (queue, start, retry); no list means no repo, never all.
- Only a `chat` run gets a `--run-` tmux session; a `pr-review` run lives in its Review item's chat.
- One tick at a time (the flock), never waiting for runs; one automation's error goes in `problems`, the
  rest go on.
- qm only ever kills a `--run-` tmux session (closing or timing out), never an item's own chat, and never a
  run the user typed into; a typed-into run is theirs until its session ends.
- Lifecycle runs every tick, paused or not; `local_paused` holds every start, `enabled: false` only cron and
  guard runs (its `manual`/`retry` ones start, under hold and cap, to try it by hand).
- `notify: quiet` keeps a run out of attention and notifications (`RunLog::quiet_session_ids`); a timeout
  notification still fires, since a timeout is a failure to fix.
- The LaunchAgent changes only on the user's command or button; `installed` reads only the plist.
- Guards and tmux go through `command_runner` and `Tmux`; tests run the real tmux on a `qm-test-…` socket
  with a stand-in for claude, a stand-in `gh` and `terminal-notifier` on PATH, a stand-in `launchctl` and a temp LaunchAgents
  directory, never a real guard target, claude, GitHub, notification or launchd.
- No TZ switching: the offset comes from `local_schedule::offset_minutes`.
- Cron search is bounded: 8 days back (`due`), nine years ahead (`next_after`), by local days.
- The run log is append-only; readers skip non-JSON lines and unknown events and fields.
- Dedupe at queue time: a key is consumed when queued or refused; only `retry` queues it again, never
  automatically. Cron runs coalesce to one queued per automation; guard items queue FIFO.

## Data

- `~/Library/LaunchAgents/com.quartermaster.automation-tick.plist` — outside the data root.
- `automations/tick.log` — the tick's stdout and stderr, appended by launchd.
- `automations/tick.json` — the last tick (`v: 1`), replaced each tick; `tick.lock` — its flock.
- `automations/<slug>.runs.jsonl` — a local automation's run log, `v: 1` per line, append-only.
- config.yml `automations.local_paused`, `local_max_running`, `local_hold_five_hour`, `local_hold_seven_day`
  (`config_schema`, read through `ProjectConfig::local_automations`: `paused`, `max_running`,
  `hold_five_hour`, `hold_seven_day`; defaults 2, 80, 90).
