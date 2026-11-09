# Automations

**Code:** `src/routines_client.rs`, `src/automation_store.rs`, `src/local_schedule.rs`, `src/automation_chat.rs`
**Tests:** `tests/routines_client.rs`, `tests/routines_curl.rs`, `tests/automation_store.rs`, `tests/local_schedule.rs`, `tests/automation_chat.rs`
**Depends on:** [work-items](work-items.md) (an automation is a work item of `kind: automation`), [settings](settings.md) (`automations.token_source`), [chats](chats.md) (its chat is the item's pane)

## What it does

Automations are scheduled Claude Code runs. A cloud automation is a claude.ai routine; a local one is a
run qm starts on this machine → [local automations](local-automations.md). Each records its `runner`:
`cloud` or `local`. This page owns what both kinds share (the local files and the schedule's DST rule) and the cloud side: the routines client.

**Turning it on** — `automations.token_source` in `config.yml` (enum, one value: `claude_code`). Unset,
automations are off: nothing reads the keychain, and every call fails with `NotEnabled`, whose message names
`qm config set automations.token_source claude_code`. The key sits in the Settings view's General card (a
select: `(off)` or `claude_code`).

**API** — `RoutinesClient` calls `https://api.anthropic.com` through a `Transport` (`call(method, url,
headers, body) → (status, body)`; the real one is `curl` run through `command_runner` with its options,
headers and body on stdin (`-K -`), so the token never sits in an argument list; tests pass a stub).
Headers: `Authorization: Bearer <token>`, `anthropic-version`, the `ccr-triggers-*` `anthropic-beta`,
`x-organization-uuid` and `content-type: application/json`; without the beta and organization headers the API
answers 404. The calls are the `Routines` trait the service is written against:
- `list` — `GET /v1/code/triggers`, the `data` routines as the API gives them.
- `get(id)`, `create(fields)` (`POST /v1/code/triggers`), `update(id, fields)` (`POST /v1/code/triggers/{id}`,
  partial), `run(id)` (`POST …/{id}/run`). A single routine answers `{"trigger": routine}`, which `get`,
  `create` and `update` unwrap in one place before the id check, still accepting a bare routine.
- `runs(id, limit)` — `GET /v1/code/sessions?trigger_id=…&limit=…`, at most `limit` runs as `{id, title,
  status, created_at, updated_at, url}`; fields the API leaves out are null.
- `delete(id)` — tries `DELETE /v1/code/triggers/{id}`; answers `Deleted`, or `Unsupported` on 404/405. The
  client only reports it; the caller decides what to do instead.
- Links: `routine_url(id)` (`https://claude.ai/code/routines/<id>`), `run_url(session id)`
  (`https://claude.ai/code/<id>`).

**Shapes** — `fields(routine)` reads a remote routine into the local shape: `id, name, cron` (UTC, as the API
holds it), `enabled, prompt` (the first job event's message, else `derived_state.prompt`), `model` (else
`derived_state.model`), `sources, allowed_tools, environment_id, connectors` (the `mcp_connections` as given)
and `updated_at`. `request_body(fields, uuid)` builds create and update bodies: only the fields given (a
partial update stays partial), never a null name / cron / enabled; given `connectors` (null counts as none)
become `mcp_connections`, plus `clear_mcp_connections: true` when empty; any of prompt / model / sources /
allowed_tools / environment_id sends the whole `job_config.ccr` (environment, one user-message event carrying
the prompt, session context).

**Token** — per call: `security find-generic-password -s "Claude Code-credentials" -w` through the command
runner, JSON `claudeAiOauth.accessToken`; the organization from `~/.claude.json`
`oauthAccount.organizationUuid`. A token whose `expiresAt` has passed fails before any request.

**Errors** — every failure is a `QmError` of a `RoutinesClient::…` class, its message for the user:
`NotEnabled`; `TokenExpired` on a 401, an expired, missing or unreadable login, or no organization ("Claude
Code's login token expired — open any Claude Code session, then refresh"); `ApiChanged` on a 404 from the
collection endpoints ("routines API changed — check the `ccr-triggers-*` beta in the claude binary");
`RoutineMissing` on a 404 from one routine's paths (get, update, run, runs): "routine <id> isn't on claude.ai
any more — delete the automation in qm"; `BadShape` for an answer that isn't JSON or lacks the expected
fields; `Network` when the request doesn't complete; a plain `Error` naming any other status and the API's
error message.

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

**Mapping** — `automation_store::from_routine(routine)` turns a routine as the API returns it into `(record, prompt)` through `routines_client::fields`, the one remote-to-local mapping; list fields the routine lacks stay unset, which drift and push treat as empty. A value that isn't a routine with an id is a `BadShape` error. A record plus its prompt is already `request_body`'s field shape, so a routine mapped and built back gives its own `job_config`.

**Schedule** (`local_schedule`): a routine's cron is UTC, as the API holds it. `from_cron(cron, on)`
reads `M H * * <weekdays or *>` (one minute, one hour; weekdays as numbers, ranges, 7 = Sunday) as `days`
(0 = Sunday) plus a local `time` in Europe/Amsterdam, with the offset in force at `on`; `label` gives
"Mon, Thu 08:00" or "every day 08:00". `0 7 * * 1,4` reads 08:00 in winter and 09:00 in summer. A UTC time
that the offset pushes past midnight moves its weekdays forward. `to_cron(days, time, on)` is the reverse,
for the current offset: a local time near midnight moves its weekdays back a day in UTC; all seven days
become `*`. Any other cron is `raw`: no days or time, labelled as itself plus "UTC", and edited as raw
cron.

**New and its chat** — `automation_chat::create(title, project, description, runner)` makes a `kind:
automation` item (its `runner`, state `in_progress`, no `routine` until the first push) and its local
files under the work-item lock: an empty prompt and a yml with `name`, `runner` and `enabled` (`true`;
`false` for local); a slug whose files already exist is refused, and so is any runner but `cloud` or
`local`. `open(slug)` starts the item's chat the way the GUI pane does: fresh when the item has no
session, else its newest one resumed — a local one's run sessions (`RunLog`) never count, live or ended —
either way with the brief as claude's last argument (`plan`); a live pane is only shown again, answering
`attached` with the brief for the caller to print. **The brief** (`brief`; a local one's loop →
[local automations](local-automations.md)) holds the item's title, slug, project and routine (or that the
first push creates it), the absolute paths of both files, the loop (edit the files → `qm automation push` →
`qm automation run` → read the run via its claude.ai link or RemoteTrigger `get_run_log` → refine), the
rule never to call RemoteTrigger create/update itself, decisions recorded with `qm note SLUG --kind
decision`, the house rules verbatim from `docs/automations-house-rules.md`, and the item's description and
notes (oldest first, kind shown).

## Rules

- Opt-in: until `automations.token_source` is `claude_code`, nothing touches the keychain.
- The token is read per call and dropped: never stored, cached on disk, logged (`qm.log` included), put in a
  message or in an argument list; messages built from outside text are scrubbed of it.
- Never refresh the token: a refresh rotates Claude Code's refresh token and can log it out. An expired token
  is the user's to renew by opening Claude Code.
- Request bodies are built only in `request_body`, so a changed API shape is fixed there.
- Tests stub the keychain and the transport (or put a stand-in `curl` on `PATH`); no test reaches the network.
- The local files are the source of truth for what a routine or a local run does.
- A write is atomic per file (`atomic_file`) and keeps each replaced file as `<file>.bak`.
- Keys qm doesn't know survive every write; the yml carries `v:`, bumped only on a breaking change.
- Schedule: no TZ switching (process-wide, races GUI threads): the EU rule is built in — CEST from the
  last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
- No automatic DST rewrites: a stored cron keeps its UTC time, so its local time moves with DST.
- A chat that already runs gets nothing typed: `open` answers `attached` with the brief, which the CLI
  prints to paste by hand. The brief is claude's argument, never keystrokes.
- The house rules live only in `docs/automations-house-rules.md`; the brief embeds that file.

## Data

- `automations/<slug>.yml`, `automations/<slug>.prompt.md` (+ `.bak`) — the automation's settings and prompt.
