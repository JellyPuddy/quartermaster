# Local automations

**Code:** `src/local_cron.rs`, `src/automation_flows.rs`, `src/chat_flow.rs`, `src/pr_review_flow.rs`, `src/automation_guard.rs`, `src/run_log.rs`, `src/run_fold.rs`, `src/random_id.rs`
**Tests:** `tests/automation_config.rs`, `tests/automation_flows.rs`, `tests/automation_guard.rs`, `tests/local_cron.rs`, `tests/run_log.rs`, `tests/automation_store.rs`
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
- Guards and tmux go through `command_runner` and `Tmux`; tests run the real tmux on a `qm-test-…` socket
  with a stand-in for claude, and a stand-in `gh` on PATH, never a real guard target, claude or GitHub.
- No TZ switching: the offset comes from `local_schedule::offset_minutes`.
- Cron search is bounded: 8 days back (`due`), nine years ahead (`next_after`), by local days.
- The run log is append-only; readers skip non-JSON lines and unknown events and fields.
- Dedupe at queue time: a key is consumed when queued or refused; only `retry` queues it again, never
  automatically. Cron runs coalesce to one queued per automation; guard items queue FIFO.

## Data

- `automations/<slug>.runs.jsonl` — a local automation's run log, `v: 1` per line, append-only.
- config.yml `automations.local_paused`, `local_max_running`, `local_hold_five_hour`, `local_hold_seven_day`
  (`config_schema`, read through `ProjectConfig::local_automations`: `paused`, `max_running`,
  `hold_five_hour`, `hold_seven_day`; defaults 2, 80, 90).
