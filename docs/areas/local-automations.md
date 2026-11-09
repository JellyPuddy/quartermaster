# Local automations

**Code:** `src/local_cron.rs`, `src/run_log.rs`, `src/run_fold.rs`, `src/random_id.rs`
**Tests:** `tests/local_cron.rs`, `tests/run_log.rs`, `tests/automation_store.rs`
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

- No TZ switching: the offset comes from `local_schedule::offset_minutes`.
- Cron search is bounded: 8 days back (`due`), nine years ahead (`next_after`), by local days.
- The run log is append-only; readers skip non-JSON lines and unknown events and fields.
- Dedupe at queue time: a key is consumed when queued or refused; only `retry` queues it again, never
  automatically. Cron runs coalesce to one queued per automation; guard items queue FIFO.
- `bypassPermissions` is refused for local automations at the store.

## Data

- `automations/<slug>.runs.jsonl` — a local automation's run log, `v: 1` per line, append-only.
