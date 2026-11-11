# Quartermaster (`qm`)

Quartermaster tracks every [Claude Code](https://claude.com/claude-code) session on your
machine and lets you curate them into **work items**: a markdown file per piece of work with a
state (`in_progress` / `fridge` / `resolved`), notes, and links to its branch, worktree, issue
and PR. Capture is automatic (Claude Code hooks append to a JSONL log); curation happens in
three places:

- **`qm`**, the CLI: bare `qm` is an fzf viewer; `qm help` lists every command.
- **`qm gui`**, a loopback web app: a kanban board, the item's Claude chats running in tmux
  panes, diffs with review comments, PRs, issues, your todos, stacked branches, and worktree cleanup.
- **A phone page** published as a claude.ai artifact (the `/work-items` skill).

A SessionStart hook tells each session which work item it belongs to and how to keep it
current, so Claude itself writes the notes.

qm also keeps **your own to-do list**: things you must do yourself, often outside any Claude
session. `qm todo add "renew the passport" [--item SLUG | --project NAME]` puts one on top,
`qm todo list` numbers the open ones in priority order, and `qm todo done N` ticks one off;
the GUI's Todos tab (`t`) lists, filters by project, reorders and ticks them, and turns one into a
work item with its chat started (`w`). It shows each epic as an outline (its todos, its open items
and theirs, a "+ todo" line, foldable) above the todos in no epic, and a todo's ⋯ menu moves it
onto an epic or item, or off it. Done todos stay in the list until you delete them.

Bigger work can be grouped into **epics**: an epic is a work item of its own (`qm new "Title"
--kind epic`), and an item joins one with `qm new "Title" --epic EPIC` or `qm epic SLUG EPIC`
(`--clear` takes it out); epics don't nest. `qm epic SLUG --make` turns an existing item into an
epic (keeping its sessions, notes and chat; new sessions on its branch then stop attaching on
their own) and `--unmake` turns it back once no item is in it; the GUI's ⋯ menu offers the
same. `qm link SLUG "Label" https://…` hangs a link on an item (`--remove` drops it), `qm list` marks epics and children with ◆, and `qm show` on an epic
lists its children and links. A session is never linked to an epic by guesswork, only by
`qm attach` or a chat started from it; a child's session is told its epic, an epic's session
its children. On the GUI board an epic is a card holding its items (which leave their columns),
its todos, link chips and, once everything in it is done, an offer to resolve it; the New item
dialog makes epics or puts the item in one, ⋯ → **Epic…** moves an item (so does dragging it onto
an epic, on the board, in the Todos outline or onto a Chats epic header; dropped on a bare board
column it leaves its epic; a drop never changes its state), and an epic's detail
sheet edits its links. In `qm gui`'s Chats view the list groups chats by epic (▸ folds a block to
its status dots), and an item's side panel opens with its epic: links, sibling chats to switch
to, the epic's todos to tick or add, and a nudge to resolve it once everything is done.

> [!WARNING]
> **This project is 100% vibe-coded.** Claude Code wrote essentially all of it, steered by
> one person for their own daily use. There are no guarantees whatsoever about its quality,
> correctness, security or safety, and it is provided as-is under the [MIT license](LICENSE),
> without warranty of any kind. Read the code before you run it, and use it at your own risk.
>
> It is a personal tool shared in case it is useful: expect rough edges, breaking changes
> without notice, and issues or pull requests that may go unanswered.

![qm gui: the chats list, a work item's chat and its side panel](docs/images/side-panel.png)

## Screenshots

All taken on the made-up demo world in [`showcase/`](showcase/README.md).

| | |
|---|---|
| ![The board: work items by state](docs/images/board.png) | ![A branch diff with review comments](docs/images/diff.png) |
| **Board**: every work item by state, with whose turn it is. | **Diff**: a branch, PR or since-prompt diff, with review comments. |
| ![The PRs view](docs/images/prs.png) | ![A chat after rotation, with the carried notes](docs/images/chat-rotation.png) |
| **PRs**: your PRs and review requests, with checks and threads. | **Rotation**: a chat handed to a fresh session, notes carried over. |

<img src="docs/images/phone.png" alt="The phone work-items page" width="260" align="right">

**Phone page**: the work items and whose turn it is, as a claude.ai artifact you can open
anywhere.

<br clear="right">

## Requirements

- **macOS** (see [macOS-only pieces](#macos-only-pieces); other platforms are untested).
- **Ruby ≥ 3.3** as `ruby` on `PATH` (stdlib only, no gems).
- **Claude Code**, **git**, **tmux** (the GUI's chats) and **fzf** (the terminal viewer).
- **gh**, logged in, for PRs, issues and reviews, plus the gh-stack extension (`gh stack`) for
  stacked branches. Everything GitHub works offline too, just without that data.

Everything else is optional: see [Optional features](#optional-features).

## Install

```sh
git clone <this repo> ~/code/quartermaster
ln -s ~/code/quartermaster/quartermaster ~/bin/qm   # any directory on PATH
qm install-hooks                                     # prints the hooks snippet
```

1. **Hooks.** `qm install-hooks` prints the `hooks` block for `~/.claude/settings.json`, with
   absolute paths into your checkout. qm never writes that file: merge the block in yourself.
   Keep the checkout where it is afterwards; the hooks point at it.
2. **Skills.** Link the [bundled skills](#bundled-skills) you want into `~/.claude/skills/`.
3. **Status line** (optional, but it is where qm learns your rate limits):
   `ln -s ~/code/quartermaster/statusline/statusline.rb ~/.claude/statusline.rb` and set
   `"statusLine": {"type": "command", "command": "/usr/bin/ruby ~/.claude/statusline.rb"}` in settings.json.
4. Start a Claude Code session anywhere. qm creates `~/.claude/quartermaster/` (override with
   `QM_ROOT`) with a near-empty `config.yml`. Run `qm gui` and open the URL it prints, then add
   your projects in the ⚙ Settings view (`,`) or with `qm config set` (see [config.yml](#configyml)).

## Optional features

Each feature below needs something beyond the requirements. A feature behind a config key is
off while that key is unset: its buttons stay hidden, and `qm ide` or a dev-server command
refuses with a message naming the setting. The keys are in [config.yml](#configyml).

### Bundled skills

`skills/` holds Claude Code skills qm's buttons and sessions rely on. Link each one you want:

```sh
for s in rotate work-items branch-stats adopt-worktree draft-issues delegate-build; do
  ln -s ~/code/quartermaster/skills/$s ~/.claude/skills/$s
done
```

| Skill | What uses it |
|---|---|
| `rotate` | `/rotate` in a qm chat: hand the work item to a fresh session |
| `work-items` | the [phone page](#phone-page) |
| `branch-stats` | how big a branch is (the GUI runs its script from the repo, linked or not) |
| `adopt-worktree` | the side panel's **Adopt worktree…**: move a worktree's branch into the main checkout |
| `draft-issues` | the GUI's Issues pane: issue drafts revised in place before they are created |
| `delegate-build` | the side panel's **Board** and **Check build progress**. Optional: it needs the Workflow tool and launches many sub-agents per build, so link it only if you want that |

### Dev server

**Switch &lt;command&gt;** (and, with an [IDE](#ide) set, **Work on this**) hands one dev
server between checkouts. Needs a per-project `dev_server:` whose `command` you provide: qm runs `command switch PATH MODE`,
`command stop` and `command status` (exit 0 while it serves). `modes` lists the modes it
accepts (e.g. `dev`, `tunnel`) and `default_mode` the one a plain switch uses. To show what it
serves, give `status_url` (JSON `{mode, root, switching}`) or `state_file` (`<mode> <root>`).

### Test database per worktree

Per-project `test_db:` names a command: a new worktree runs `<test_db> prepare` in it, and
worktree cleanup runs `<test_db> drop PATH [--dry-run]`.

### IDE

**Open in &lt;label&gt;**, the IDE half of **Work on this**, the PRs view's IDE button and
`qm ide` need `ide_command:`, an argv array with a literal `PATH` placeholder:
`[open, -a, MyIDE, PATH]`, `[code, PATH]`, or a shell script such as `[zsh, -ic, "myide PATH"]`
(`PATH` inside a longer element is shell-escaped). `ide_label:` names it in buttons and messages
(default `IDE`). Set them at the top level; a project may override both.

### Benchmarks

The 🏁 branch benchmarks measure a branch against main, stage by stage for a stack. They assume
a Rails app on Postgres and need a per-project `benchmark:` with both `database` (a Postgres
database a run reads, or clones as a template for a case that writes; fill it with
production-sized data yourself) and `skill` (a folder you write, holding a `SKILL.md` on how
to benchmark your app and a `bin/example_bench.rb`); `notes` adds prompt lines. Not bundled.

### Review skill

The PRs view's **Review** types a review skill into the item's chat: `/code-review` by default,
or the per-project `review_skill:`. Claude is asked to record its findings as qm drafts on the PR
and, when done, its suggested verdict and summary (`qm draft add --summary`); you curate them in
the diff pane's tray, and nothing goes to GitHub until you post it. **Post as pending review**
adds the drafts to your pending review; **Submit review…** posts them and submits the review with
the verdict you pick (Approve, Comment or Request changes) and a summary, then hands the PR back
to its author: the author is added to the PR's assignees and you are removed if you were
assigned (not on your own PR; a failure shows as a warning). Only that click in the GUI
submits: no command, chat or automation can.

### Loose-chat starters

`loose_starters:` presets fill "Start with" in the loose-chat dialog (`qm loose --starter`).
Each prompt loads something, typically through the chat's own MCP server (an issue tracker,
say), and ends mid-sentence: qm appends " answer my question about them: …" or " ask me what I
want to know about them.".

### Status board and build progress

The side panel's **Board** mirrors a status-board artifact and **Check build progress**
estimates how far running sub-agents are. Both are fed by the bundled
[`delegate-build`](#bundled-skills) skill. To feed the board your own way, keep its row
contract: publish a claude.ai artifact whose database holds one row per task in collection
`tasks` (`status`, `title`, `note`, `order`, `dependsOn`, `batch`, `batchLabel`, `updatedAt`),
write it with `ArtifactData`, and link it to the item with
`qm board SLUG URL [--answers-dir DIR]`. The PostToolUse hook from `qm install-hooks` records
every `ArtifactData` call, so the GUI renders the board without reaching claude.ai. A
`blocked` row gets an answer box that writes `<answers dir>/<doc_id>.md` for the agent to wait
on. Build progress reads the Workflow runs of the item's sessions and asks `claude -p --model
haiku` for an estimate, only on your click.

### Phone page

Needs claude.ai Artifacts with a database. Ask Claude to publish `skills/work-items/page.html`
once with `capabilities: {db: {rules: [{path: "", read: "view", write: "owner"}]}}`, put its URL
in `overview_artifact:`, and link the `work-items` skill. Then "show my work items" in any
session refreshes it. To act on items from the phone, talk to a qm chat through Claude's Remote
Control.

### Desktop app

`qm gui` installs as a Chrome app window: with it open, click the install icon in the address
bar (or ⋮ → Cast, save and share → Install page as app) and install **Quartermaster**. The
app's Dock icon shows the same count as the tab title, the chats whose move is yours (blocked,
or your turn and not snoozed). While `qm gui` isn't running the window shows a "qm gui isn't
running" page that comes back by itself once you start it. Links to other sites (PRs, issues,
claude.ai) open in your default browser, not in Chrome. `qm gui` still opens its URL with
`open`, so Chrome may launch it in a tab unless you turn on "Open supported links" in the app's
settings in Chrome.

### Automations

Manage your claude.ai cloud routines (scheduled Claude Code agents that run on claude.ai) from
qm: each one is a work item with its schedule and prompt in local files. The ⚙ Automations tab
and `qm automation list | show | adopt | push | pull | pause | resume | run | delete` list
them, adopt the ones you already have, and push your edits; `qm automation new` and **Edit with
Claude** create or change one through the item's chat. Off until
`qm config set automations.token_source claude_code`, because it uses your Claude Code login
(see [What qm does on your machine](#what-qm-does-on-your-machine)). Details:
[docs/areas/automations.md](docs/areas/automations.md).

### Local automations

Scheduled Claude Code runs on your own Mac, managed by qm: a `runner: local` automation in the
same ⚙ Automations tab (marked 💻, cloud ones ☁). They need no claude.ai login token, so they
work with `automations.token_source` unset. Create one with `qm automation new TITLE --project P
--runner local` (or **New** in the tab); it starts disabled (its cron and guard
don't run, but `qm automation run` and Retry still start a run), and its chat helps you write the
prompt and the yml.

- **The tick.** Nothing runs until you install the scheduler: `qm automation install-tick`
  (or **Install tick** in the tab) writes a LaunchAgent that runs `qm automation tick` every
  5 minutes; `--print` shows its plist without writing, `uninstall-tick` removes it. The tab
  warns when local automations are enabled and no tick has run for 15 minutes.
- **Schedule and guard.** `cron:` is a 5-field cron in Amsterdam local time. An optional
  `when:` guard is a shell command run when the cron is due (in the automation's `cwd`, 60 s
  limit). Each non-empty output line is one item to work on: a JSON object with a string
  `key` (plus the fields its flow needs), or a plain line that is its own key. Each key runs
  once, ever; a failing guard queues nothing and shows its error. Without a guard, a due cron
  queues one run. Try it with `qm automation tick --dry-run SLUG`, which writes nothing.
- **Flows.** `flow: chat` (the default) starts a tmux chat running `claude` with the prompt
  file plus the item; you can open it from the tab and take it over. `flow: pr-review` takes
  items with a `url` and starts that PR's Review chat, as the PRs view's Review button does.
  It only reviews repos its yml lists (`repos: [owner/name]`): an unattended review reads PR
  text others wrote with your permissions, so a PR elsewhere could steer it (prompt
  injection). A PR outside the list is refused, shown once as "refused" in its runs, and never
  started; with no list, nothing is reviewed.
- **Limits.** At most 2 runs work at once (`automations.local_max_running`); starts hold
  while your 5-hour usage is at 80% or the weekly at 90% (`local_hold_five_hour`,
  `local_hold_seven_day`); `automations.local_paused` or the tab's pause toggle stops all new
  work, and Pause stops one automation. A run still working after `timeout_minutes` (30) is
  stopped and notified; a finished run's chat closes after an hour idle, unless you typed
  into it. `notify: quiet` keeps its runs out of your attention list.
- **Results are drafted, never posted.** The house rules tell a run to put its results in
  qm (`qm draft add`, `qm note`) for you to review and send.
- `qm automation run | runs | retry | pause | resume [--skip-existing] | delete` work on them
  too; Enable in the tab can mark the guard's current items as seen, so only new ones run.
  Details: [docs/areas/local-automations.md](docs/areas/local-automations.md).

### Other tools

- **ripgrep** (`rg`): transcript search.
- **terminal-notifier**: clickable notifications that open the chat (else plain `osascript` ones).
- **Warp**: the "open in a terminal tab" actions (`qm resume`, `qm term`).
- **Arc**: a notification's click brings the GUI's tab to that chat.

### macOS-only pieces

- Notifications: `osascript` (or terminal-notifier).
- Opening URLs, Warp tabs and the GUI: `open`; focusing the GUI tab in Arc: `osascript`.
- Keeping the Mac awake while chats work (`qm caffeinate`): `/usr/bin/caffeinate`.
- The status line runs under macOS's system Ruby, `/usr/bin/ruby`.
- Automations read Claude Code's login from the keychain: `security`.
- Local automations' scheduler is a LaunchAgent: `launchctl`.

## config.yml

`~/.claude/quartermaster/config.yml` maps project names to repo roots. Sessions in a repo (or
its worktrees) get that project; everything else is "No project". A project is a plain path,
or a mapping with `root:` plus optional feature keys. A missing key leaves that feature off.

Edit it in `qm gui`'s ⚙ Settings view (the header's cog, or `,`), with
`qm config get | set | unset | path` (`qm config set projects.my-app ~/code/my-app`), or by
hand. Both editors check the whole file and refuse to write one with errors. They rewrite it in
qm's own layout, so **comments you add by hand are dropped** on their next save; the previous
file is kept as `config.yml.bak`.

```yaml
projects:
  my-app: ~/code/my-app
  my-web-app:
    root: ~/code/my-web-app
    dev_server:                   # one dev server, switched between checkouts
      command: devserver          # qm runs: devserver switch PATH MODE | stop | status
      modes: [dev, tunnel]
      default_mode: dev
      status_url: http://localhost:3000/status   # optional, JSON {mode, root, switching}
      state_file: ~/.cache/devserver/current     # optional, "<mode> <root>"
    test_db: my-test-db           # new worktree: my-test-db prepare; cleanup: my-test-db drop PATH [--dry-run]
    review_skill: /review-my-pr   # the PRs view's Review button (default /code-review)
    pr_prerequisites: true        # PRs ship by release: sessions learn `qm pr-requires`
    benchmark:                    # 🏁 branch benchmarks (a Rails app on Postgres)
      database: my_app_benchmark  # the database a run reads, or clones for a writing case
      skill: ~/.claude/skills/benchmark   # holds SKILL.md and bin/example_bench.rb
      notes: Use nothing outside the bundle.   # optional extra prompt lines
    ide_command: [code, PATH]     # this project's own IDE, overriding the global one
    ide_label: VS Code

default_project: my-app           # where a bare issue number starts (default: the first project)

ide_command: [open, -a, MyIDE, PATH]   # "Open in …": PATH becomes the checkout
ide_label: MyIDE                       # the buttons' name (default IDE)

loose_starters:                   # presets in the loose-chat dialog's "Start with"
  backlog:
    label: Sprint backlog
    # qm appends " answer my question about them: …" or " ask me what I want
    # to know about them.", so the prompt ends mid-sentence, ready for that.
    prompt: Load the open issues of the current sprint. Don't change code. Then give a one-line count of them and

automations:
  token_source: claude_code       # turns on Automations: qm uses Claude Code's login token
  # local_max_running: 2          # local automations: runs working at once
  # local_hold_five_hour: 80      # hold local starts at this 5-hour usage %
  # local_hold_seven_day: 90      # ... or this weekly usage %
  # local_paused: true            # start no local runs, run no guards

# prices:                         # per-model token price overrides (docs/areas/side-panel.md)
# overview_artifact: <URL>        # the published phone page's artifact URL
```

`docs/overview.md` describes each key, and the area pages under `docs/areas/` what it turns on.

## What qm does on your machine

Know this before you install it:

- **Its hooks run in every Claude Code session**, on session start and end, on every prompt
  and on every tool call. They append to files under `~/.claude/quartermaster/`: session and
  tool-call events (session ids, working directory, branch, tool names), commit and diff
  stats at session end, a git snapshot of the worktree on each prompt, and the full payload of
  every `ArtifactData` call. qm also reads your Claude Code transcripts under
  `~/.claude/projects/`.
- **Your to-do list lives in `~/.claude/quartermaster/todos.json`** (with `todos.lock` beside
  it), written by `qm todo` and the GUI. Sessions linked to a work item are told they may add a
  todo there with `qm todo add` when you ask or when something needs your own hands.
- **`qm gui` listens on `127.0.0.1` only** and refuses requests from other origins, but
  anything on your machine that can reach that port can drive it, and it can run commands:
  tmux chats running `claude`, `git worktree` add and remove, `gh` (which posts your review
  drafts and, on your click in its verdict form, submits your review on GitHub and then
  assigns the PR to its author and unassigns you), and whatever dev-server, test-database and
  IDE commands you configure.
- **The `qm gui` page registers a service worker in your browser** for `127.0.0.1:<port>`. It
  stores one offline page in the browser's cache and answers only page loads that fail because
  `qm gui` isn't running; it caches nothing else and sends nothing anywhere. Chrome's site data
  settings for that address remove it.
- **In the installed `qm gui` app, a link to another site runs macOS `open <url>`** (http and
  https links only), so it opens in your default browser instead of a Chrome window.
- **Some features start `claude -p` in the background** (summaries, asides, benchmarks), which
  counts against your Claude usage or API bill. Benchmark runs keep their folders (script,
  results, logs) in `~/.local/share/quartermaster/benchmarks/`, outside `~/.claude`, where
  Claude Code would refuse the background agent's writes.
- **With [Automations](#automations) on, qm reads Claude Code's login token from the macOS
  keychain** (`security find-generic-password -s "Claude Code-credentials"`) and your
  organization id from `~/.claude.json`, on every call. The token is never stored, logged or
  refreshed; an expired one is yours to renew by opening Claude Code. The routines it manages
  run in the cloud on their schedule, with the connectors listed in each automation's file.
- **With [local automations](#local-automations), qm runs `claude` unattended.**
  `qm automation install-tick` (only that command or the tab's Install tick button) writes
  `~/Library/LaunchAgents/com.quartermaster.automation-tick.plist`, carrying your shell's
  `PATH`, and loads it with `launchctl bootstrap`; `uninstall-tick` runs `launchctl bootout`
  and deletes it. Every 5 minutes it runs `qm automation tick`, which runs each enabled local
  automation's `when:` guard command when its schedule is due, as you, in its working
  directory, and starts `claude` sessions in tmux with the automation's prompt and your normal
  Claude Code permissions (`bypassPermissions` is refused). They use your Claude usage, and qm
  kills a run's tmux session on timeout or an hour after it finished.
- **qm sends nothing itself, except to `api.anthropic.com` with Automations on**: the routines
  API, called directly with that token, only while you use the Automations tab or
  `qm automation`.
  Everything else goes through the tools it calls: `gh` (GitHub), `claude` (Anthropic), and the
  claude.ai artifacts you choose to publish.

## Development

```sh
ruby test/quartermaster_test.rb
```

This runs every test file as its own process, as many at once as you have CPUs; set
`QM_TEST_JOBS` to change that (`QM_TEST_JOBS=1` runs them all in one process). A failing file's
output comes with the command that replays it alone.
Tests run against a temporary `QM_ROOT` and their own tmux socket, never your live data. Start
with [`CLAUDE.md`](CLAUDE.md) (the hard constraints) and [`docs/README.md`](docs/README.md),
which indexes one page per area. `showcase/` builds a fake demo world to run the real GUI on
made-up data.

## License

[MIT](LICENSE)
