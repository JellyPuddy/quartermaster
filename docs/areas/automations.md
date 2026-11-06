# Automations

**Code:** `lib/quartermaster/automations.rb`, `lib/quartermaster/cli_automation.rb`, `lib/quartermaster/routines_client.rb`, `lib/quartermaster/automation_store.rb`, `lib/quartermaster/local_schedule.rb`, `lib/quartermaster/automation_chat.rb`, `lib/quartermaster/gui_automations.rb`, `lib/quartermaster/gui/js/automations.js`, `lib/quartermaster/gui/js/automations-render.js`
**Tests:** `test/automation_cli_test.rb`, `test/routines_client_test.rb`, `test/automation_store_test.rb`, `test/local_schedule_test.rb`, `test/automation_chat_test.rb`, `test/gui_automations_test.rb`
**Depends on:** [work-items](work-items.md) (an automation is a work item), [settings](settings.md) (`automations.token_source`; writes the way `ConfigFile` does), [gui-shell](gui-shell.md) (`CommandRunner`), [chats](chats.md) (its chat is the item's pane)

## What it does

Automations are the user's claude.ai cloud routines: scheduled Claude Code agents that run on
claude.ai, not on this machine. qm reaches them through the same API the claude binary uses.
Every automation records `runner: cloud`; the field leaves room for other runners.

**Service** — `Automations` (the CLI's and the GUI's one entry point) pairs each store entry with
the `kind: automation` work item of the same slug (`routine:`, `runner: cloud` in its frontmatter).
- `local` — the store's entries and their items, no network. `overview(rows)` adds one `list`
  call: each row's routine (`remote`, nil when it isn't on claude.ai) and `drift` (its
  `updated_at` differs from the stored `remote_updated_at`), plus `unmanaged` routines (no local
  files). `detail(slug)` — one entry, its routine and its last 10 runs.
- `push(slug, force:)` — the one path that changes a routine. No `routine` yet: create, then
  merge the created routine (through `from_routine`, so the API's defaults such as `enabled` and
  `model` land locally; the local prompt stays) into the store and write the id to the item, so a
  second push has nothing to send. Else `get` the routine, refuse with `Stale` when it
  drifted (unless forced), and `update` only what differs from it: changed name / cron /
  enabled as they are, the stored connectors always, and all job fields when any of prompt /
  model / repos / tools / environment differs. A field unset locally is no change. Stores the answer's `updated_at`; nothing differing writes nothing.
- Each push with changes appends one `history` note (`pushed: schedule → Mon 07:00 (0 6 * * 1
  UTC); prompt changed`, `paused`, `resumed`, `created routine trig_…`), and the item's state
  follows `enabled`: `active`, or `fridge` while paused (`in_progress` until the first push).
- `pull` — the routine overwrites both local files (each kept as `.bak`), notes what changed.
- `pause` / `resume` — a local edit of `enabled`, then push. `run` — run it now.
- `adopt(id, project:, slug:)` — a routine no store entry holds becomes an entry plus an item
  (title the routine's name, slug by default its slug, description the name and the prompt's
  first paragraph), state from `enabled`. `create_item` makes such an item under any slug.
- `delete` — the API's delete removes the routine and the local files; without one
  (`:unsupported`) the routine is paused and its files stay, so it isn't "unmanaged"; never
  pushed, only the files go. The item is resolved either way, its notes kept.

**CLI** — `qm automation list | show | adopt | push | pull | pause | resume | run | delete`
(`CliAutomation`). `list` prints the local rows (slug, project, state, local schedule,
enabled) before its one list call, then a status line per row (last run, next run, drift) and
the routines "Not managed by qm"; `show` adds repos, connectors, links and runs. `delete` asks
y/N on stdin unless `--yes`; without an API delete it prints "paused; delete it on claude.ai:
<routine url>". A client error is an `ArgumentError`: its message, exit 1.

**Turning it on** — `automations.token_source` in `config.yml` (enum, one value: `claude_code`).
Unset, automations are off: nothing reads the keychain, and every call fails with `NotEnabled`,
whose message names `qm config set automations.token_source claude_code`. The key sits in the
Settings view's General card (a select: `(off)` or `claude_code`).

**API** — `RoutinesClient` calls `https://api.anthropic.com` with `Net::HTTP` through an
injectable transport (`#call(method, url, headers, body) → [status, body]`; tests pass a stub).
Headers: `Authorization: Bearer <token>`, `anthropic-version`, the `ccr-triggers-*`
`anthropic-beta` (its exact value is in `RoutinesClient::HEADERS`), `x-organization-uuid` and
`content-type: application/json`; without the beta and organization headers the API answers 404.
- `list` — `GET /v1/code/triggers`, the `data` routines as the API gives them.
- `get(id)`, `create(fields)` (`POST /v1/code/triggers`), `update(id, fields)` (`POST
  /v1/code/triggers/{id}`, partial), `run(id)` (`POST …/{id}/run`).
- Response shapes: a list answers `{"data": [routines], "has_more"}`, a single routine (get,
  verified; create and update assumed) `{"trigger": routine}`, which `get`, `create` and `update`
  unwrap in one place before the id check, still accepting a bare routine.
- `runs(id, limit:)` — `GET /v1/code/sessions?trigger_id=…&limit=…`, at most `limit` runs as
  `{id, title, status, created_at, updated_at, url}`; fields the API leaves out are nil.
- `delete(id)` — tries `DELETE /v1/code/triggers/{id}`; answers `:deleted`, or `:unsupported`
  on 404/405. The client only reports it; the caller decides what to do instead.
- Links: `routine_url(id)` (`https://claude.ai/code/routines/<id>`), `run_url(session id)`
  (`https://claude.ai/code/<id>`).

**Shapes** — `RoutinesClient.fields(routine)` reads a remote routine into the local shape: `id,
name, cron` (UTC, as the API holds it), `enabled, prompt` (the first job event's message, else
`derived_state.prompt`), `model` (else `derived_state.model`), `sources, allowed_tools,
environment_id, connectors` (the `mcp_connections` as given) and `updated_at`. `RoutinesClient.request_body(fields)` builds create
and update bodies: only the fields given (a partial update stays partial), never a nil name / cron / enabled; given `connectors` (nil
counts as none) become `mcp_connections`, plus `clear_mcp_connections: true` when empty; any of prompt / model /
sources / allowed_tools / environment_id sends the whole `job_config.ccr` (environment, one
user-message event carrying the prompt, session context).

**Token** — per call: `security find-generic-password -s "Claude Code-credentials" -w` through
the runner, JSON `claudeAiOauth.accessToken`; the organization from `~/.claude.json`
`oauthAccount.organizationUuid` (path injectable). A token whose `expiresAt` has passed fails
before any request.

**Errors** — every failure is a `RoutinesClient::Error` (an `ArgumentError`, qm's user-facing
channel), its message for the user: `NotEnabled`; `TokenExpired` on a 401, an expired, missing
or unreadable login, or no organization ("Claude Code's login token expired — open any Claude
Code session, then refresh"); `ApiChanged` on a 404 ("routines API changed — check the
`ccr-triggers-*` beta in the claude binary"); `BadShape` for an answer that isn't JSON or lacks
the expected fields; `Network` when the request doesn't complete; a plain `Error` naming any
other status and the API's error message.

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
returns it into `[record, prompt]` through `RoutinesClient.fields`, the one remote-to-local
mapping: the prompt is `job_config.ccr.events[0].data.message.content` (falling back to
`derived_state.prompt`), the model `job_config.ccr.session_context.model` (falling back to
`derived_state.model`); list fields the routine lacks stay unset, which drift and push treat
as empty. A value that isn't a routine with an id is a `BadShape` error. A record plus its
prompt is already `RoutinesClient.request_body`'s field shape, so a routine mapped and built
back gives its own `job_config`.

**Schedule** (`LocalSchedule`): a routine's cron is UTC, as the API holds it. `from_cron(cron, on:)`
reads `M H * * <weekdays or *>` (one minute, one hour; weekdays as numbers, ranges, 7 = Sunday)
as `days` (0 = Sunday) plus a local `time` in Europe/Amsterdam, with the offset in force at `on`;
`label` gives "Mon, Thu 08:00" or "every day 08:00". `0 7 * * 1,4` reads 08:00 in winter and
09:00 in summer. A UTC time that the offset pushes past midnight moves its weekdays forward.
`to_cron(days:, time:, on:)` is the reverse, for the current offset: a local time near midnight
moves its weekdays back a day in UTC; all seven days become `*`. Any other cron is `raw?`: no
days or time, labelled as itself plus "UTC", and edited as raw cron.

**New and edit** — `qm automation new TITLE --project P` (`AutomationChat.create`) makes a
`kind: automation` item (`runner: cloud`, state `in_progress`, no `routine` until the first
push) and its local files: an empty prompt and a yml with `name`, `runner` and `enabled: true`; a slug whose files
already exist is refused. It then opens the item's chat, as `qm automation edit SLUG` does:
through the running GUI's `automation-chat` action (a local action, so the CLI may post it
without an Origin), then `ChatOpener` brings the GUI up on it; without a GUI it prints the
`cd … && QM_ITEM=… claude …` line to run. The chat starts fresh when the item has no session, else
resumes its newest one, either way with the brief as claude's last argument
(`AutomationChat#plan`). **The brief** (`AutomationChat.brief`) holds the item's title, slug,
project and routine (or that the first push creates it), the absolute paths of both files, the
loop (edit the files → `qm automation push` → `qm automation run` → read the run via its claude.ai
link or RemoteTrigger `get_run_log` → refine), the rule never to call RemoteTrigger create/update
itself, decisions recorded with `qm note SLUG --kind decision`, the house rules verbatim from
`docs/automations-house-rules.md`, and the item's description and notes (oldest first, kind shown).

**GUI tab** — the ⚙ area's Automations tab (`GuiAutomations` server side; `automations.js`,
`automations-render.js`, `automations.css` in the page). `GET /api/automations` answers the
local rows at once (name, project, state, the schedule read in local time, enabled, runner,
links) merged with the routines the last list call saw (last run, next run, drift, a routine
gone from claude.ai), the routines "Not managed by qm", and `remote.state`: `idle`, `ok`, `off`
(with the `qm config set` command), `expired` or `error`. `GET /api/automations/<slug>` adds the
prompt, file paths, model, repos, connectors, the item's description and notes and its runs as
last loaded, and `runsState` (`idle`, `ok`, `error`). POSTs under `/api/automations/`: `refresh`
(the one list call), `runs` (the client's `runs(id, limit: 10)`, no GET of the routine), `apply` (a schedule as `days` + local `time` or a raw `cron`, and/or the `prompt`: saved
locally at once, then pushed), `pause`, `resume`, `run`, `pull`, `push` (`force` overwrites a
drifted routine), `delete`, `adopt` (`id`, `project`) and `new` (`title`, `project`: the item
and empty files; the page then opens its chat with the `automation-chat` action, as Edit with
Claude does). Every network call is a `GuiJobs` job (`automations`, `automation-<slug>`,
`automation-runs-<slug>`, `automation-adopt-<id>`); each action ends with one list call, and the
page reloads the tab when the state poll hands it the job's end. The page opens the tab with
one refresh and asks for the shown automation's runs while its `runsState` is `idle`: the first
time, and again after an action job on that slug ends (Run now, a refused push too) or a refresh
ends, both of which set loaded runs back to `idle` (still listed until the new ones arrive; a
refresh leaves runs that arrived while it ran, so opening the tab loads them once);
Apply is per automation. The detail's Description has an edit control that saves through the
GUI's `describe` action (`/api/action`, as `qm describe` does): the item's text, local, never pushed.

## Rules

- Opt-in: until `automations.token_source` is `claude_code`, nothing touches the keychain.
- The token is read per call and dropped: never stored, cached on disk, logged (`qm.log`
  included) or put in a message; messages built from outside text are scrubbed of it.
- Never refresh the token: a refresh rotates Claude Code's refresh token and can log it out.
  An expired token is the user's to renew by opening Claude Code.
- Request bodies are built only in `RoutinesClient.request_body`, so a changed API shape is
  fixed there.
- Every create and update `Automations` sends carries the stored connectors (none → `[]` plus
  `clear_mcp_connections`): the API attaches all the user's connectors to a routine created
  without them and ignores an empty list in an update, so a pushed routine has exactly its yml's.
- Tests stub the keychain (`FakeRunner`) and the transport; no test reaches the network.
- The local files are the source of truth; a remote routine only changes through
  `Automations#push` (pause and resume included), which refuses a drifted routine unless forced.
- Drift is never resolved automatically: the user picks pull or a forced push.
- History notes are one line each (notes are append-only).
- Fetching is on demand: one list call per listing, runs only for one automation; no polling.
- A write is atomic per file (`AtomicFile`) and keeps each replaced file as `<file>.bak`.
- Keys qm doesn't know survive every write; the yml carries `v:`, bumped only on a breaking change.
- Schedule: stdlib only, and no `ENV["TZ"]` switching (process-wide, races GUI threads): the EU rule
  is built in — CEST from the last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
- No automatic DST rewrites: a stored cron keeps its UTC time, so its local time moves with DST.
- A chat that already runs gets nothing typed: `automation-chat` answers `attached` with the brief,
  which the CLI prints to paste by hand. The brief is claude's argument, never keystrokes.
- Off and an expired token are states of the tab (`remote.state`), never an error toast; an
  action that hits them answers quietly and the tab says what to do.
- GUI network work runs on `GuiJobs` threads, never under the action mutex; `GET`s read only
  the local files and what the last calls left in memory.
- The house rules live only in `docs/automations-house-rules.md`; the brief reads it at runtime.

## Data

- `automations/<slug>.yml`, `automations/<slug>.prompt.md` (+ `.bak`) — the automation's settings and prompt.
