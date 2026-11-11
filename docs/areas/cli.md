# CLI and viewer

**Code:** `lib/quartermaster/cli.rb`, `lib/quartermaster/cli_format.rb`, `lib/quartermaster/cli_viewer.rb`, `lib/quartermaster/cli_attention.rb`, `lib/quartermaster/cli_chats.rb`, `lib/quartermaster/cli_prs.rb`, `lib/quartermaster/cli_cleanup.rb`, `lib/quartermaster/cli_workspace.rb`, `lib/quartermaster/cli_setup.rb`, `lib/quartermaster/cli_epic.rb`, `lib/quartermaster/free_text_args.rb`, `lib/quartermaster/viewer.rb`, `lib/quartermaster/feature_use.rb`, `lib/quartermaster/ruby_pin.rb`, `lib/quartermaster/ruby_floor.rb`, `lib/quartermaster/doctor.rb`, `quartermaster`
**Tests:** `test/viewer_test.rb`, `test/free_text_args_test.rb`, `test/feature_use_test.rb`, `test/ruby_pin_test.rb`, `test/doctor_test.rb`
**Depends on:** [work-items](work-items.md), [linking](linking.md), [gui-shell](gui-shell.md)

## What it does

`qm` is shared by the user, Claude and the hooks. `./quartermaster` is a launcher only, one
file that is both `sh` and Ruby. Run directly, its `sh` half reads `$QM_ROOT/ruby-version`
(`RubyPin`) and, when it names a version asdf has installed (or there is no asdf), exports it as
`ASDF_RUBY_VERSION` and `MISE_RUBY_VERSION`, overriding any inherited value (kept in
`QM_OUTER_*`, which the Ruby half restores before running anything, so the chats, dev servers and
IDEs qm starts run on their own directory's Ruby); then it execs
`ruby` on the same file, which starts at the `#!ruby` line. No file, an empty one, or a version
asdf lacks: plain `ruby`, resolved as the cwd pins it. Loaded by Ruby (tests, `RbConfig.ruby
EXECUTABLE`), the `sh` half is a `=begin` comment. The Ruby half runs `RubyFloor` before anything
else (see [capture](capture.md)), then requires `lib/quartermaster` through its realpath, so the
`~/bin/qm` and `~/bin/quartermaster` symlinks keep working, and runs `CLI#run`. Help text comes from `CliFormat::USAGE_SECTIONS`;
`qm help` is authoritative. Commands, one line each (flags in `qm help`):

**Viewer and GUI**
- `qm` — the fzf viewer in a terminal with fzf; otherwise (piped, no fzf) `qm list`.
- `qm viewer` — the fzf viewer explicitly.
- `qm gui` — the loopback web UI ([gui-shell](gui-shell.md)).
- `qm caffeinate on|off|auto|status` — the running GUI's ☕ ([side-panel](side-panel.md)).
- `qm open-chat SLUG` — bring the GUI up on an item's chat (a notification's click; [attention](attention.md));
  `--benchmark BRANCH` opens that branch's benchmark modal over it.

**Work items**
- `qm new TITLE` — create an item, print its slug (`--project`, `--branch`, `--session`, `--description`, `--pf-mode`; `--kind epic` for an epic, `--epic SLUG` for a child of one).
- `qm epic SLUG EPIC_SLUG` / `qm epic SLUG --clear` — put an item in an epic or take it out; `--make` / `--unmake` turn the item itself into an epic or back ([work-items](work-items.md)).
- `qm link SLUG LABEL URL` / `qm link SLUG LABEL --remove` — add or replace (by label) an item's link, or remove it; `qm link SLUG --refresh` adds the Tracker / Notion links an epic's GitHub issue gives and it lacks ([work-items](work-items.md)).
- `qm attach SLUG --session ID` / `qm detach SLUG --session ID` — link or unlink a session; attach moves it off any other item.
- `qm note SLUG [--kind open|decision|history] TEXT` / `qm retag SLUG POSITION KIND` — add a note, change a note's kind.
- `qm state SLUG STATE` — in_progress | active | fridge | resolved.
- `qm link-branch SLUG [BRANCH] [--temp]` / `qm unlink-branch SLUG BRANCH` — branch links (default: current branch; `--temp` marks a scratch branch cleanup may delete).
- `qm board SLUG [URL|clear] [--answers-dir DIR]` / `qm board-rows SLUG [--json]` / `qm board-answer SLUG ROW TEXT` — status board URL, mirrored rows, answering a blocked row.
- `qm move SLUG PROJECT` / `qm retitle SLUG TITLE` / `qm describe SLUG [TEXT|-]` — project, title (slug never changes), description (stdin-capable).
- `qm show SLUG` — the item with sessions, warnings, stack lines and usage (and kind, routine, runner for an automation; an epic's children and any links; a child's epic).
- `qm list [--kind automation|epic]` — table of all items but automations, with an epic column (`◆ epic`, `◆ <epic>`); `--kind` lists only that kind.
- `qm draft add SLUG …` (`--summary [--verdict V]` for the PR's suggested verdict) / `qm draft list SLUG [--json]` — Claude's review drafts ([review](review.md)).
- `qm issues-dir SLUG` — the item's issue-drafts directory ([drafts](drafts.md)).
- `qm cleanup SLUG [--yes] [--force P]` / `qm sweep [--yes] [--force P]` — plan or run worktree cleanup ([worktrees](worktrees.md)).
- `qm delete SLUG [--force]` — remove an item made by accident and kill its chat; refused for one holding work unless `--force` ([work-items](work-items.md)).
- `qm feature-use [--days N]` — per kind, each name used in the last N days (default 30) with its count and last use, then the known names nobody used; dates the log's first line.
- `qm todo add|list|done` — the user's own to-do list ([todos](todos.md)).
- `qm ask QUERY` — find items by meaning (headless claude); `qm grep PHRASE` — sessions whose prompts or replies contain it ([gui-shell](gui-shell.md)).

**Attention**
- `qm attention` — chats by whose move it is, plus expiring transcripts, stale items, merged PRs.
- `qm overview --json [PATH] | --url | --page | --page-published` — the phone page ([phone-page](phone-page.md)).
- `qm ack SLUG [SESSION_ID]` / `qm snooze SLUG 1d|7d|Nd|turn|clear` — quiet a warning or the current your-turn.
- `qm distill SLUG [--session ID] [--force]` — snapshot expiring transcripts ([work-items](work-items.md)).

**Sessions and workspace**
- `qm resume SLUG [--session ID] [--here]` / `qm start SLUG [--here]` — resume or start in a new Warp tab (or this terminal).
- `qm pane-start SLUG` / `qm pane-resume SLUG [--session ID]` — the same in the running GUI's pane ([chats](chats.md)).
- `qm start-issue N [--project P] [--as-item]` — item + issue worktree + kickoff chat, or an epic for an epic issue ([issues](issues.md)).
- `qm automation new TITLE --project P` / `qm automation edit SLUG` — an automation item and files, then its chat with qm's brief ([automations](automations.md)).
- `qm loose [--project P] [--model M] [--starter NAME] ["prompt"]` — a chat with no work item in the GUI; `--starter` opens it with a config.yml `loose_starters:` kickoff ([loose-chats](loose-chats.md)).
- `qm rotate SLUG [--close]` / `qm rotate --self [--close]` — context rotation ([rotation](rotation.md)).
- `qm pr SLUG` / `qm pr-requires PR-OR-SHA …` — open the PR; PR prerequisites ([prs](prs.md)).
- `qm work-on SLUG` / `qm pf-switch SLUG` / `qm ide SLUG` / `qm term SLUG` — pf + IDE, pf, IDE, Warp tab on the target worktree (`--worktree PATH`; `--mode M` for the pf ones). The IDE is config.yml's `ide_command:`; without one `qm ide` refuses naming it and `qm work-on` only switches.
- `qm pf-mode SLUG [MODE]` / `qm pf-status` / `qm pf-stop` — an item's dev-server mode (one of its project's `dev_server.modes`); what the dev server serves; stop it. The `pf-*` command names stay; their output names the configured command.
- `qm sessions [-n N]` / `qm inbox [-n N]` / `qm dismiss ID` / `qm show-session ID` — captured sessions, the unlinked inbox.
- `qm session-item ID` — the linked item's title (for the status line).

**Hooks**: `qm hook-session-start`, `qm hook-session-end`, `qm install-hooks` (prints the
settings snippet) — see [capture](capture.md).
- `qm pin-ruby [VERSION|--clear]` — write `ruby-version` (default: the running `RUBY_VERSION`),
  refusing a version below the floor or one asdf has not installed (checked against
  `$ASDF_DATA_DIR/installs/ruby`, default `~/.asdf`); `--clear` removes it.
- `qm doctor` — one `✓`/`!`/`✗` line per check, a fix hint on the others, exit 1 on any `✗`
  (`Doctor`): the SessionStart, SessionEnd and record-event.sh hooks registered (record-event.sh
  on every event `qm install-hooks` gives it) in `$QM_CLAUDE_SETTINGS` (default
  `~/.claude/settings.json`) and pointing at existing files; the Ruby pin (`!` when absent, `✗`
  when below the floor or not installed); the running Ruby against `RubyFloor::FLOOR`; the data
  root present and writable (doctor never creates it); unseen `qm.log` errors (`!` with the
  newest, counted by `ErrorLog`: header lines that are neither `transient` nor `recovered`,
  newer than `errors-seen-at` or else the last day, from the log's last 256 KB;
  [capture](capture.md) owns it); and capture (`!` when neither `sessions.jsonl` nor
  `events.jsonl`'s tail has an event from the last day).

**Settings**
- `qm config get [PATH]` / `qm config set PATH VALUE` / `qm config unset PATH` / `qm config path` —
  config.yml by dotted path (VALUE is YAML); errors refuse the write with exit 1, warnings don't;
  unsetting a project warns with its work-item count ([settings](settings.md)).

Internal, called by the viewer's fzf bindings: `viewer-rows`, `sessions-view`, `inbox-view`,
`cycle-filter`, `session-rows`, `inbox-rows`, `choose-state`, `choose-project`,
`choose-snooze`, `attach-session`, `item-from-session`. Internal, spawned by the GUI: `bench-run
<run dir>`, a benchmark run's detached pipeline ([benchmarks](benchmarks.md)).

**Command groups.** `CLI` keeps the work-item commands; the rest live in modules mixed into it,
one file each: `CliViewer` (viewer rows and pickers, `list`, `show`, sessions), `CliEpic` (`epic`, `link`, the epic parts of `show`), `CliAttention` (inbox,
attention, overview, ack, snooze, distill), `CliChats` (commands acting on the running GUI),
`CliPrs` (pr, pr-requires, draft), `CliCleanup` (cleanup, sweep), `CliWorkspace` (resume, start,
pf, IDE, terminal), `CliSetup` (how qm itself runs: pin-ruby, doctor), `CliConfig` (`qm config`, owned by
[settings](settings.md)), `CliAutomation` (`qm automation`, owned by [automations](automations.md)), `CliTodo` (`qm todo`, owned by [todos](todos.md)), and `CliFormat` (shared output helpers and the help text). Each group's frozen
`COMMANDS` maps a word to the method `CLI#run` calls with argv; `CLI.commands` merges them and
refuses a word claimed twice. A new command touches only its group's file (and `qm help`). Hooks
and commands called otherwise (no argv, extra arguments, another class) stay explicit `when`
branches in `CLI#run`.

**The viewer** (`Viewer`, bare `qm`). One fzf list of items: a state badge, ▶ when a session is
live, attention reasons; items with attention entries first, then by activity. The preview pane
is `qm show`. The filter cycles open → in_progress → fridge → resolved → all (`^F`, kept in
`viewer-filter` under the data root). Bindings: Enter or double-click resume (new Warp tab), `^N`
new session, `^X` the item's sessions (Enter resumes one), `^B` the inbox (Enter attach, `^W` new
item from session, `^D` dismiss), `^S` state, `^P` project, `^O` PR, `^T` distill, `^A` ack,
`^Z` snooze, `^R` reload. The viewer stays open while actions run.

**Feature use** (`FeatureUse`). Every `qm` command (by its word; not hooks, not `qm doctor`
(`FeatureUse::UNRECORDED`, also left out of the never-used list), not `QM_SKIP` runs), every
GUI action (by `cmd`; other POST routes by route) and every GUI `/api/` read except the `/api/state` and `/api/pulse` polls and the CLI's `/api/root` probe (by route, cut to `/api/<word>`) appends one
`{v, at, kind, name}` line to `feature-use.jsonl`: the evidence for deleting unused features.
`qm feature-use` reads it back. Its never-used lists come from the dispatchers themselves —
`GuiActions#dispatch` and `Gui#respond`'s other POST routes, `Gui#respond`'s `/api/` GET routes,
`CLI.commands` and `CLI#run`'s explicit words — read by `FeatureUse.known_names`, so a new action, route or
command shows up without touching a list.

**Live sessions.** SessionStart records the claude pid; SessionEnd clears it. `qm sessions`
marks `● live` sessions; the viewer and GUI show a live badge. Resuming a live session is
refused ("switch to its Warp tab"): it would fork the conversation.

## Rules

- Never rename or move `./quartermaster`: the `~/bin` symlinks and the hook registrations point at it.
- The launcher's `sh` half stays before `=end` and its Ruby half after `#!ruby`; `ruby_floor.rb`, which runs before `lib/` loads, must parse on Ruby 2.x and require nothing.
- Commands that act on the GUI (`caffeinate`, `pane-start`, `pane-resume`, `rotate`, `start-issue`, `loose`, `automation new|edit`) POST `/api/action` to `127.0.0.1:$QM_GUI_PORT` (default 49737) without an Origin, after `GET /api/root` shows that GUI serves their own data root (`Quartermaster.root_id`); a GUI on another root (a CLI under a test `QM_ROOT` beside the live GUI) or a server that names no root counts as no GUI. With no GUI they say so, do nothing and exit 1 — except `start-issue`, which then makes the item and worktree itself and prints how to start the chat, and `loose` and `automation new|edit`, which print how to start it. Each needs its action in `LoopbackGuard::LOCAL_ACTIONS`.
- `qm install-hooks` prints the snippet and never writes `~/.claude/settings.json`; that file is the user's.
- Hook commands never print except SessionStart's context, honour `QM_SKIP`, rescue everything and exit 0.
- `qm board SLUG` with no URL prints only the URL and exits non-zero when unset, so a shell can test it in one call.
- `qm rotate --self` refuses from an aside and from a process that belongs to no item's chat; only the `/rotate` skill runs it.
- Liveness is checked at read time (`kill(0, pid)`), never trusted from the log: SessionEnd doesn't fire on crashes.
- The viewer's actions are plain `qm` subcommands, so the viewer, the GUI and Claude share one implementation; mouse support is double-click resume only — fzf's `click-header` + `execute` handoff didn't reliably hand the terminal to picker actions, so clickable actions live in the GUI.
- The feature-use log holds a kind and a name only — never a slug, argument, path or session id — is only appended to, and recording is best-effort: a failed write goes to `qm.log` and never fails the command or request.
- `FeatureUse.known_names` reads `CLI.commands`, plus `when "…" then` branches and `method == … && route …` conditions; a dispatcher reshaped away from that loses its names from the never-used lists (the known-names test pins a few).
- `qm doctor` writes nothing, not even a feature-use line, so a missing data root stays missing and fails its check: `events.jsonl` is read from its tail through `EventLog#last_ts`, never folded, so not even `events-fold.json` changes.
- `ArgumentError` or `OptionParser::ParseError` (a bad flag) from any command becomes `qm: <message>` and exit 1, never a backtrace.
- Free text may start with a dash: for `new`, `note` and `loose` (`FreeTextArgs.parse`) an argument that starts with `-` and holds whitespace (`qm note SLUG "- a bullet"`) is text, never an option or an abbreviation of one (`"-d does stuff"` is not `--description`), unless it is an inline `--flag=value`; right after a flag that takes a value it is that value; `--` ends options there and is dropped before the text of `retitle`, `describe`, `board-answer`, `ask` and `grep` (`FreeTextArgs.words`). A one-word dash text needs the `--`: `qm new -- -x`.

## Data

- `viewer-filter` — the viewer's current state filter.
- `feature-use.jsonl` — one line per feature use, append-only, never pruned.
- `ruby-version` — one Ruby version and a newline, written by `qm pin-ruby`, read by the launcher's `sh` half.
