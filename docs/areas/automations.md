# Automations

**Code:** `src/automation_store.rs`, `src/local_schedule.rs`
**Tests:** `tests/automation_store.rs`, `tests/local_schedule.rs`
**Depends on:** [work-items](work-items.md) (an automation is a work item of `kind: automation`)

## What it does

Automations are scheduled Claude Code runs. A cloud automation is a claude.ai routine; a local one is a
run qm starts on this machine → [local automations](local-automations.md). Each records its `runner`:
`cloud` or `local`. This page owns what both kinds share: the local files and the schedule's DST rule.

**Local store** — `AutomationStore` keeps each automation as two files under `automations/`: `<slug>.yml`
and `<slug>.prompt.md` (the prompt, nothing else). A cloud yml holds `v: 1` first, then `routine` (the
trigger id, `trig_…`), `runner`, `name`, `cron` (UTC, as the API holds it), `model`, `sources` (the repos),
`connectors` (the routine's `mcp_connections`), `allowed_tools`, `environment_id`, `enabled`,
`remote_updated_at` (the routine's `updated_at` at the last sync), then any other keys; a `runner: local`
yml's keys → [local automations](local-automations.md). `read(slug)` gives an `Entry` (slug, record,
prompt) or none; `list` every entry by slug; `find_by_routine(id)` the entry holding a trigger id;
`exists`; `delete_local` removes both files (and a local run log), leaving their `.bak`s. `write(slug,
record, prompt)` merges the record onto the stored keys, so keys a caller doesn't name survive, and
returns the stored entry; the yml is written the way `ConfigFile` writes config.yml (Psych's layout, `v`
and the known fields first in their order). A slug is `[a-z0-9][a-z0-9-]*`, refused otherwise.

**Schedule** (`local_schedule`): a routine's cron is UTC, as the API holds it. `from_cron(cron, on)`
reads `M H * * <weekdays or *>` (one minute, one hour; weekdays as numbers, ranges, 7 = Sunday) as `days`
(0 = Sunday) plus a local `time` in Europe/Amsterdam, with the offset in force at `on`; `label` gives
"Mon, Thu 08:00" or "every day 08:00". `0 7 * * 1,4` reads 08:00 in winter and 09:00 in summer. A UTC time
that the offset pushes past midnight moves its weekdays forward. `to_cron(days, time, on)` is the reverse,
for the current offset: a local time near midnight moves its weekdays back a day in UTC; all seven days
become `*`. Any other cron is `raw`: no days or time, labelled as itself plus "UTC", and edited as raw
cron.

## Rules

- The local files are the source of truth for what a routine or a local run does.
- A write is atomic per file (`atomic_file`) and keeps each replaced file as `<file>.bak`.
- Keys qm doesn't know survive every write; the yml carries `v:`, bumped only on a breaking change.
- Schedule: no TZ switching (process-wide, races GUI threads): the EU rule is built in — CEST from the
  last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
- No automatic DST rewrites: a stored cron keeps its UTC time, so its local time moves with DST.

## Data

- `automations/<slug>.yml`, `automations/<slug>.prompt.md` (+ `.bak`) — the automation's settings and prompt.
