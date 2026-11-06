# Automations

**Code:** `lib/quartermaster/local_schedule.rb`
**Tests:** `test/local_schedule_test.rb`

## What it does

Automations are claude.ai cloud routines (scheduled Claude Code agents) that qm manages.

- **Schedule** (`LocalSchedule`): a routine's cron is UTC, as the API holds it. `from_cron(cron, on:)`
  reads `M H * * <weekdays or *>` (one minute, one hour; weekdays as numbers, ranges, 7 = Sunday)
  as `days` (0 = Sunday) plus a local `time` in Europe/Amsterdam, with the offset in force at `on`;
  `label` gives "Mon, Thu 08:00" or "every day 08:00". `0 7 * * 1,4` reads 08:00 in winter and
  09:00 in summer. A UTC time that the offset pushes past midnight moves its weekdays forward.
- `to_cron(days:, time:, on:)` is the reverse, for the current offset: a local time near midnight
  moves its weekdays back a day in UTC; all seven days become `*`.
- Any other cron is `raw?`: no days or time, labelled as itself plus "UTC", and edited as raw cron.

## Rules

- Stdlib only, and no `ENV["TZ"]` switching (process-wide, races GUI threads): the EU rule is built in
  — CEST from the last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
- No automatic DST rewrites: a stored cron keeps its UTC time, so its local time moves with DST.
