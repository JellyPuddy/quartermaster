# Automations

**Code:** `src/automations.rs`, `src/automation_fields.rs`, `src/automation_command.rs`, `src/routines_client.rs`, `src/automation_store.rs`, `src/local_schedule.rs`, `src/automation_chat.rs`, `src/gui_automations.rs`, `gui/js/automations.js`, `gui/js/automations-render.js`, `gui/css/automations.css`
**Tests:** `tests/automations.rs`, `tests/automation_cli.rs`, `tests/automation_new_cli.rs`, `tests/routines_client.rs`, `tests/routines_curl.rs`, `tests/automation_store.rs`, `tests/local_schedule.rs`, `tests/automation_chat.rs`, `tests/gui_automations.rs`, `tests/gui_automations_http.rs`
**Depends on:** [gui-shell](gui-shell.md) (`gui_jobs`, Origin rules), [work-items](work-items.md) (an automation is a work item of `kind: automation`), [settings](settings.md) (`automations.token_source`), [chats](chats.md) (its chat is the item's pane)

## What it does

Automations are scheduled Claude Code runs. A cloud automation is a claude.ai routine; a local one is a
run qm starts on this machine → [local automations](local-automations.md). Each records its `runner`:
`cloud` or `local`. This page owns what both kinds share (the local files and the schedule's DST rule) and the cloud side: the routines client.

**Service** — `Automations` (the CLI's one entry point) pairs each store entry with the `kind: automation`
work item of the same slug (`routine:`, `runner: cloud` in its frontmatter), over a `Routines` client.
- `local` — the store's entries and their items, no network. `overview(rows)` adds one `list` call: each row's
  routine (`remote`, none when it isn't on claude.ai) and `drift` (its `updated_at` differs from the stored
  `remote_updated_at`), plus `unmanaged` routines (no local files). `detail(slug, limit)` — one entry, its
  routine and its last runs.
- `push(slug, force, recreate)` — the one path that changes a routine. No `routine` yet: create, then merge the
  created routine (through `from_routine`, so the API's defaults such as `enabled` and `model` land locally;
  the local prompt stays) into the store and write the id to the item, so a second push has nothing to send.
  Else `get` the routine, refuse with `Stale` when it drifted (unless forced), and `update` only what differs
  from it: changed name / cron / enabled as they are, the stored connectors always, and all job fields when any
  of prompt / model / repos / tools / environment differs. A field unset locally is no change. Stores the
  answer's `updated_at`; nothing differing writes nothing. A routine gone from claude.ai (`RoutineMissing`)
  fails the push with "<slug>: routine … isn't on claude.ai any more — delete the automation in qm (`qm
  automation delete <slug>`) or re-create it (`qm automation push <slug> --recreate`)", writing nothing.
  `recreate` acts only when that `get` answers `RoutineMissing`: it takes the create path (connectors
  explicit, the new routine merged into the yml, its id on the item, `remote_updated_at` stored, state
  synced); on a routine still there, or one never pushed, it refuses and writes nothing.
- Each push with changes appends one `history` note (`pushed: schedule → Mon 07:00 (0 6 * * 1 UTC); prompt
  changed`, `paused`, `resumed`, `created routine trig_…`, `re-created routine trig_new (was trig_old)`), and
  the item's state follows `enabled`: `active`, or `fridge` while paused (`in_progress` until the first push).
- `pull` — the routine overwrites both local files (each kept as `.bak`), notes what changed.
- `pause` / `resume` — a local edit of `enabled`, then push. `run` — run it now.
- `adopt(id, project, slug)` — a routine no store entry holds becomes an entry plus an item (title the
  routine's name, slug by default its slug, description the name and the prompt's first paragraph), state from
  `enabled`. `WorkItem::create_automation` makes such an item under any slug (made under the slug as its title,
  then retitled, in one move).
- `delete` — the API's delete removes the routine and the local files; without one (`Unsupported`) the routine
  is paused and its files stay, so it isn't "unmanaged"; when that pause finds the routine already gone it
  counts as deleted; never pushed, only the files go. The item is resolved either way, its notes kept.
- `runner: local` slugs go to `LocalAutomations` ([local automations](local-automations.md)); `push`, `pull` and
  `adopt` refuse them ("<slug> runs locally — nothing on claude.ai").

**CLI** — `qm automation list | show | adopt | push | pull | pause | resume | run | delete` (`automation_command`;
the local-only subcommands are `local_automation_command`'s). `list` prints every row (slug, project, state,
schedule, enabled, runner) before its one list call (cloud rows only), then a status line per routine (last
run, next run, drift) and the routines "Not managed by qm"; `show` adds repos, connectors, links and runs;
`push --recreate` re-creates a routine deleted on claude.ai. `delete` asks y/N on stdin unless `--yes`; without
an API delete it prints "paused; delete it on claude.ai: <routine url>". An error is its message on stderr as
`qm: …`, exit 1; a slug command with a stray word prints the usage and does nothing. `qm automation tick` is
not recorded by feature use (launchd runs it every five minutes).

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

**New and its chat** — `qm automation new TITLE --project P [--description TEXT] [--runner cloud|local]` and `qm automation edit SLUG` open the item's chat through the running GUI's `automation-chat` action (a local action, so the CLI may post it without an Origin; it also needs the GUI to serve this data root), then bring the GUI page up on it; without a GUI they print the `cd … && QM_ITEM=… claude …` line to run. `automation_chat::create(title, project, description, runner)` makes a `kind:
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

**GUI tab** — the ⚙ area's Automations tab (`gui_automations`; `automations.js`, `-render.js`,
`automations.css`): one list for both runners, a ☁ or 💻 badge per row. `GET /api/automations`
answers the local rows at once (name, project, state, local-time schedule, enabled, runner, links)
merged with the routines the last list call saw (last run, next run, drift, a routine gone from
claude.ai), the routines "Not managed by qm", `remote.state` (`idle`, `ok`, `off` with the `qm
config set` command, `expired` or `error`) and `local` (the tick header). `GET
/api/automations/<slug>` adds the prompt, file paths, model, repos, connectors, the item's
description and notes and its runs as last loaded, and `runsState` (`idle`, `ok`, `error`). POSTs
under `/api/automations/`: `refresh` (the one list call), `runs` (the client's `runs(id, 10)`, no GET
of the routine), `apply` (a schedule as `days` + local `time` or a raw `cron`, and/or the `prompt`:
saved locally at once, then pushed), `pause`, `resume`, `run`, `pull`, `push` (`force` overwrites a
drifted routine), `recreate` (the detail's **Re-create on claude.ai**, shown only while the row is
`missing`), `delete`, `adopt` (`id`, `project`) and `new` (`title`, `project`, `runner` from the New
form's runner choice: the item and empty files; the page then opens its chat with the
`automation-chat` action, as Edit with Claude does). Every network call is a `gui_jobs` job
(`automations`, `automation-<slug>`, `automation-runs-<slug>`, `automation-adopt-<id>`) that builds its
own client on its thread; each action ends with one list call, and the page reloads the tab when the
state poll hands it the job's end. Opening the tab is one refresh; the shown automation's runs load
while its `runsState` is `idle` — at first, and after an action job on it or a refresh ends, both of
which set loaded runs back to `idle` (a refresh spares runs that arrived while it ran). Apply is per
automation; Description saves through `describe` (`/api/action`), never pushed. Local rows, details and
actions are `gui_local_automations`' ([local-automations](local-automations.md)). Every POST needs our
Origin: none of these routes is a `LOCAL_ACTIONS` entry.

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
- Off and an expired token are states of the tab (`remote.state`), never an error toast; an action that
  hits them answers quietly and the tab says what to do.
- GUI network work runs on `gui_jobs` threads, never under the action mutex; `GET`s read only the local
  files and what the last calls left in memory.
- The house rules live only in `docs/automations-house-rules.md`; the brief embeds that file.

## Data

- `automations/<slug>.yml`, `automations/<slug>.prompt.md` (+ `.bak`) — the automation's settings and prompt.
