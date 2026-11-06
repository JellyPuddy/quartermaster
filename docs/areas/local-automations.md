# Local automations

**Code:** `lib/quartermaster/run_log.rb`, `lib/quartermaster/tick_installer.rb`, `lib/quartermaster/automation_flows.rb`, `lib/quartermaster/chat_flow.rb`, `lib/quartermaster/pr_review_flow.rb`
**Tests:** `test/run_log_test.rb`, `test/automation_store_test.rb`, `test/tick_installer_test.rb`, `test/automation_flows_test.rb`
**Depends on:** [automations](automations.md) (the store, the item, the GUI tab), [attention](attention.md) (a run's session state), [gui-shell](gui-shell.md) (`CommandRunner`), [chats](chats.md) (tmux, the chat env), [prs](prs.md) (`PrReviewStart`)

## What it does

A local automation is a scheduled Claude Code run on this machine, managed by qm. It shares the
cloud automations' store (`AutomationStore`), its `kind: automation` work item and its GUI tab;
its yml says `runner: local` instead of `cloud`.

**Fields** — a `runner: local` yml holds `v`, `runner`, `name`, `cron` (5-field, Europe/Amsterdam
local time), `enabled`, `when` (the guard: a shell command), `flow` (default `chat`), `cwd`
(default the project's root), `model`, `allowed_tools` (a list), `permission_mode`,
`timeout_minutes` (default 30) and `notify` (`attention` or `quiet`, default `attention`); no
`routine` or `remote_*`. `AutomationStore.local_settings(record)` fills the defaults for unset
fields without writing them. `AutomationStore#write` validates the merged record of a local
automation with `AutomationStore.validate_local` and writes nothing when it fails: an
ArgumentError naming every bad field — `permission_mode: bypassPermissions`, a `notify` outside
the two values, a `flow` that isn't a non-empty string, a `timeout_minutes` that isn't a positive
whole number, an `allowed_tools` that isn't a list of strings. Cloud records are never held to it.

**New and its brief** — `qm automation new TITLE --project P --runner local` (the GUI's `new` with
`runner: local`) makes the item with `runner: local` and a yml with `enabled: false`, so nothing
runs until the user enables it. Its chat's brief (`AutomationChat.local_brief`) names both files
(cron in local time, the local fields), and the loop: edit the files → `qm automation tick
--dry-run SLUG` (the guard's items, nothing written) → `qm automation run SLUG` → read the run
(`qm automation runs SLUG` for its session id, `qm show-session`, the transcript under
`~/.claude/projects/`) → refine. Nothing to push; no RemoteTrigger wording. Its end — decisions as
notes, the house rules verbatim (with their "Local automations" section on drafting, unattended
runs and the guard's output), description and notes — is the cloud brief's (`brief_tail`).

**Flows** — every run goes through the flow its yml's `flow:` names, from `AutomationFlows`
(`chat` when unset). A flow has a `name`, the item fields it `needs` and `start(automation, item,
prompt, run_id:, session_id:)`, answering `{item_slug:, tmux:}` once a chat runs or `{waiting:
reason}` when the run stays queued. `AutomationFlows#problem(flow, item)` says why a flow can't take
an item (an unknown flow, or a `needs` field missing or blank; a cron run's nil item lacks every
field), and `#start` raises it as an ArgumentError. Both flows pass claude `--session-id` (qm's
uuid), then `--model`, `--permission-mode` and `--allowedTools` (one comma-joined value: the flag
is variadic and would swallow the prompt) when the yml sets them, before the prompt.
- `chat` (`ChatFlow`): tmux session `<slug>--run-<run id>` on qm's socket, running
  `Launcher#chat_command` (so `QM_CHAT_COMMAND` swaps it) with `QM_ITEM=<automation slug>`; Tmux
  unsets every `CLAUDE*` var. cwd is the yml's `cwd`, else the automation item's project root,
  else home. The prompt is `<slug>.prompt.md`, plus for an item a final `## Item` section: the
  item pretty-printed as JSON, or a guard's plain line (an item of only `key` and `line`) as the line.
- `pr-review` (`PrReviewFlow`, needs `url`): the PR from the inbox cache, else one
  `gh pr view URL --json …` through the runner (a failure raises). While the PR's Review chat is
  live (`PrReviewStart#live?`) it answers `waiting: "Review chat for <repo>#<n> is open"` and
  starts nothing; else `PrReviewStart#start` opens the Review item's own chat (tmux named by its
  slug) with the flags before the kickoff and the automation's prompt appended to it.

**Run log** — `RunLog.new(slug)` is `automations/<slug>.runs.jsonl`, one `{v: 1, at, event, …}`
line per event, appended under a flock; a writer that decides from the fold (`enqueue_item`,
`enqueue_cron`, `retry`, `waiting`) re-reads it and appends under that one flock, so a tick and a
CLI or GUI write never both queue a key. Events:
- `queued` (`run_id`, `key`, `item`, `flow`, `trigger`: `cron` | `guard` | `manual` | `retry`)
- `started` (`run_id`, `session_id`, `tmux`, `item_slug`)
- `waiting` (`run_id`, `reason`) — written only when the reason differs from the run's last one
- `finished`, `timed_out`, `closed` (`run_id`); `failed` (`run_id`, `error`)
- `retried` (`run_id`, `new_run_id`)
- `guard_error` (`error`, `item` when one item was refused); `guard_ran` (`items`) — a guard run
  that exited cleanly
- `seen` (`keys`) — keys recorded without queuing (enable with "mark existing as seen")
- `checked` — the tick handled a due cron minute; written only when the cron was due, so a tick
  that finds nothing due appends nothing, and the next tick's window starts at this `at`

A run id is 8 lowercase alphanumerics (safe in a tmux name). The fold, re-read after each write:
- `queue` — runs queued and not yet started, failed or otherwise ended, oldest first.
- `live` — started runs not yet `finished`, `timed_out`, `closed` or `failed`.
- `recent(limit: 20)` — every run that left the queue, newest start first, each with `status`
  (`live`, `finished`, `timed_out`, `closed`, `failed`); a finished run closed later reads `closed`.
- `run(id)`, `seen_keys` (every `queued` key plus every `seen` key), `cron_queued?`,
  `last_guard_error` (the latest `guard_error` line, cleared by a later `guard_ran`),
  `last_cron_check` (the latest `checked` time).

Writers: `enqueue` (no dedupe), `enqueue_item` (nil when the key was seen), `enqueue_cron(due:)`
(nil while a cron run is queued; key `cron:<due minute, UTC ISO>`, item nil), `retry(run_id)`
(an ended run's key, item and flow as a new `retry` run, bypassing dedupe; refuses an unknown,
queued or live run), `started`, `waiting`, `finished`, `timed_out`, `closed`, `failed`,
`guard_error`, `guard_ran`, `mark_seen`, `checked`.

**Tick installer** — `TickInstaller` owns the one LaunchAgent that runs `qm automation tick`
every 300 s. Its label is `com.quartermaster.automation-tick`; its plist lives at
`~/Library/LaunchAgents/<label>.plist` (directory injectable). The plist (`plist`, written by
hand, values XML-escaped) holds `ProgramArguments` = the realpath of the `quartermaster`
launcher, `automation`, `tick`; `StartInterval` 300; `RunAtLoad` false; stdout and stderr both
appended to `<root>/automations/tick.log`; and `EnvironmentVariables` with the installing
process's `PATH` (launchd's own PATH has no asdf shims, Homebrew, tmux or claude) plus
`QM_ROOT` when it is set. `install` creates the log's directory, writes the plist atomically,
runs `launchctl bootout gui/<uid>/<label>` (its failure ignored, so a reinstall picks up a
changed plist) and then `launchctl bootstrap gui/<uid> <plist>`; a failed bootstrap removes the
plist and raises an `ArgumentError` carrying launchctl's message. `uninstall` boots the label
out and removes the plist, whether or not launchd still held it. `installed?` is whether the
plist exists.

## Rules

- The run log is append-only: every write appends one line; readers skip lines that aren't JSON
  objects, events they don't know and fields they don't know.
- Never skip, dedupe at queue time: a key is consumed when queued and a failed or timed-out run is
  never retried automatically; only `retry` queues a key again.
- Cron runs coalesce to at most one queued cron run per automation; guard items queue one each, FIFO.
- `bypassPermissions` is refused for local automations at the store.
- Only a `chat` run gets a `--run-` tmux session; a `pr-review` run lives in its Review item's own
  chat and never opens a second one beside it.
- Flows hand tmux the argv and env only through the `Tmux` wrapper; tests pass a `FakeTmux`.
- Deleting an automation (`AutomationStore#delete_local`) removes its run log with its files.
- The LaunchAgent is installed or removed only on the user's explicit command or button, never
  as a side effect of anything else.
- Every `launchctl` call goes through `CommandRunner`; tests pass a stub runner and a temp
  LaunchAgents directory and never reach real launchctl.
- `installed?` reads only the plist file; it never asks launchctl.

## Data

- `automations/<slug>.runs.jsonl` — a local automation's run log, `v: 1` per line, append-only.
- `automations/tick.log` — the tick's stdout and stderr, appended by launchd.
- `~/Library/LaunchAgents/com.quartermaster.automation-tick.plist` — outside the data root.
