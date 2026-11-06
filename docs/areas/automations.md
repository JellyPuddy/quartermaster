# Automations

**Code:** `lib/quartermaster/automation_store.rb`, `lib/quartermaster/local_schedule.rb`
**Tests:** `test/automation_store_test.rb`, `test/local_schedule_test.rb`
**Depends on:** [work-items](work-items.md) (an automation is a work item), [settings](settings.md) (writes the way `ConfigFile` does)

## What it does

An automation is a claude.ai cloud routine (a scheduled Claude Code agent) that qm manages.
Every automation records `runner: cloud`; the field leaves room for other runners.

**Local store** — `AutomationStore` keeps each automation as two files under
`automations/`: `<slug>.yml` and `<slug>.prompt.md` (the prompt, nothing else). The yml holds
`v: 1` first, then `routine` (the trigger id, `trig_…`), `runner`, `name`, `cron` (UTC, as the
API holds it), `model`, `sources` (the repos), `connectors` (the routine's `mcp_connections`),
`allowed_tools`, `environment_id`, `enabled` and `remote_updated_at` (the routine's
`updated_at` at the last sync), then any other keys. `read(slug)` gives an `Entry` (slug,
record, prompt) or nil; `list` every entry by slug; `find_by_routine(id)` the entry holding a
trigger id; `exists?`; `delete_local` removes both files and leaves their `.bak`s. `write(slug,
record, prompt)` merges the record onto the stored keys, so keys a caller doesn't name (qm's
or anyone's) survive, and returns the stored entry. A slug is `[a-z0-9-]`, refused otherwise.

**Mapping** — `AutomationStore.from_routine(routine)` turns a routine as the routines API
returns it into `[record, prompt]`: the prompt is `job_config.ccr.events[0].data.message.content`
(falling back to `derived_state.prompt`), the model `job_config.ccr.session_context.model`
(falling back to `derived_state.model`); a value that isn't a routine with an id is an
`ArgumentError`. `AutomationStore.routine_body(record, prompt)` is the one place a create or
update request body is built: `name`, `cron_expression`, `enabled`, the whole `job_config.ccr`
(`environment_id`, one user-message event holding the prompt with a fresh uuid,
`session_context` {`allowed_tools`, `model`, `sources`}) and `mcp_connections`; unset values are
left out. A routine mapped and built back gives its own `job_config`.

**Schedule** (`LocalSchedule`): a routine's cron is UTC, as the API holds it. `from_cron(cron, on:)`
reads `M H * * <weekdays or *>` (one minute, one hour; weekdays as numbers, ranges, 7 = Sunday)
as `days` (0 = Sunday) plus a local `time` in Europe/Amsterdam, with the offset in force at `on`;
`label` gives "Mon, Thu 08:00" or "every day 08:00". `0 7 * * 1,4` reads 08:00 in winter and
09:00 in summer. A UTC time that the offset pushes past midnight moves its weekdays forward.
`to_cron(days:, time:, on:)` is the reverse, for the current offset: a local time near midnight
moves its weekdays back a day in UTC; all seven days become `*`. Any other cron is `raw?`: no
days or time, labelled as itself plus "UTC", and edited as raw cron.

## Rules

- The local files are the source of truth; a remote routine only changes through push.
- A write is atomic per file (`AtomicFile`) and keeps each replaced file as `<file>.bak`.
- Keys qm doesn't know survive every write; the yml carries `v:`, bumped only on a breaking change.
- Request bodies are built only in `routine_body`, so a change in the API's shape is fixed in one place.
- Schedule: stdlib only, and no `ENV["TZ"]` switching (process-wide, races GUI threads): the EU rule
  is built in — CEST from the last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
- No automatic DST rewrites: a stored cron keeps its UTC time, so its local time moves with DST.

## Data

- `automations/<slug>.yml`, `automations/<slug>.prompt.md` (+ `.bak`) — the automation's settings and prompt.
