# Quartermaster (`qm`)

Quartermaster tracks every [Claude Code](https://claude.com/claude-code) session on your
machine and lets you curate them into **work items**: a markdown file per piece of work with a
state (`in_progress` / `fridge` / `resolved`), notes, and links to its branch, worktree, issue
and PR. Capture is automatic (Claude Code hooks append to a JSONL log); curation happens in
three places:

- **`qm`**, the CLI: bare `qm` is an fzf viewer; `qm help` lists every command.
- **`qm gui`**, a loopback web app: a kanban board, the item's Claude chats running in tmux
  panes, diffs with review comments, PRs, issues, stacked branches, and worktree cleanup.
- **A phone page** published as a claude.ai artifact (the `/work-items` skill).

A SessionStart hook tells each session which work item it belongs to and how to keep it
current, so Claude itself writes the notes.

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

All taken on a made-up demo world.

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
- **A Rust toolchain** to build it (`cargo build --release`; `.tool-versions` pins the version for asdf,
  or use [rustup](https://rustup.rs)).
- **Claude Code**, **git**, **tmux** (the GUI's chats) and **fzf** (the terminal viewer).
- **gh**, logged in, for PRs, issues and reviews, plus the gh-stack extension (`gh stack`) for
  stacked branches. Everything GitHub works offline too, just without that data.

Everything else is optional: see [Optional features](#optional-features).

## Install

```sh
git clone <this repo> ~/code/quartermaster
cd ~/code/quartermaster && cargo build --release       # target/release/qm
ln -s ~/code/quartermaster/quartermaster ~/bin/qm       # any directory on PATH
qm install-hooks                                        # prints the hooks snippet
```

`quartermaster` is a small `sh` launcher that runs `target/release/qm` through any symlink; rebuild after
every `git pull`, since the hooks run whatever binary is there.

1. **Hooks.** `qm install-hooks` prints the `hooks` block for `~/.claude/settings.json`, with
   absolute paths into your checkout. qm never writes that file: merge the block in yourself.
   Keep the checkout where it is afterwards; the hooks point at it.
2. **Skills.** Link the [bundled skills](#bundled-skills) you want into `~/.claude/skills/`.
3. **Status line** (optional, but it is where qm learns your rate limits): set
   `"statusLine": {"type": "command", "command": "/path/to/qm statusline"}` in settings.json.
4. Start a Claude Code session anywhere. qm creates `~/.claude/quartermaster/` (override with
   `QM_ROOT`) with a commented `config.yml`. Run `qm gui` and open the URL it prints.

## Migrating from the Ruby version

qm was written in Ruby and is now Rust, with the same commands, the same files and the same GUI. **Your
data needs no migration:** work items, `sessions.jsonl`, drafts, caches and `config.yml` in
`~/.claude/quartermaster/` (or `QM_ROOT`) are read and written as before, byte for byte.

1. **Build the binary** in your checkout: `git pull && cargo build --release`. The launcher
   `~/bin/qm` points at (`quartermaster`, now an `sh` script) runs `target/release/qm`, so the symlink
   and the hooks `qm install-hooks` printed earlier keep working unchanged. Until the build exists
   `qm` says to build it, and the hooks stay silent.
2. **Drop the Ruby settings.** `QM_USE_RUST`, `QM_RUST_BIN` and `QM_RUBY_LAUNCHER` mean nothing any more,
   and Ruby (and asdf's global ruby) is no longer needed.
3. **Move the status line** (the one step that breaks if skipped): `statusline/statusline.rb` is gone, so
   change the `statusLine` command in `~/.claude/settings.json` from
   `/usr/bin/ruby ~/.claude/statusline.rb` to `/path/to/qm statusline` and remove the
   `~/.claude/statusline.rb` symlink.
4. **Restart `qm gui`.** It is the Rust server now.

A few things differ on purpose: an option qm cannot read says `qm: invalid option: --x` instead of a
Ruby backtrace; a title with no letter or digit is refused instead of making an item with an empty
slug; YAML qm writes for unusual titles (line breaks, `~`, `<<`) is double-quoted. **To go back**, check
out commit `6c25480`, the last one with the Ruby code. Report anything else that differs as a bug: the
port was checked against Ruby on every command and GUI route ([testing](docs/areas/testing.md)).

## Optional features

Each feature below needs something beyond the requirements. A feature behind a config key is
off while that key is unset: its buttons stay hidden, and `qm ide` or a dev-server command
refuses with a message naming the setting. The keys are in [config.yml](#configyml).

### Bundled skills

`skills/` holds Claude Code skills qm's buttons and sessions rely on. Link each one you want:

```sh
for s in rotate work-items branch-stats adopt-worktree draft-issues; do
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
or the per-project `review_skill:`.

### Loose-chat starters

`loose_starters:` presets fill "Start with" in the loose-chat dialog (`qm loose --starter`).
Each prompt loads something, typically through the chat's own MCP server (an issue tracker,
say), and ends mid-sentence: qm appends " answer my question about them: …" or " ask me what I
want to know about them.".

### Status board and build progress

The side panel's **Board** mirrors a status-board artifact and **Check build progress**
estimates how far running sub-agents are. Both are fed by a `delegate-build`-style skill of your
own, not bundled: it publishes a claude.ai artifact whose database holds one row per task in
collection `tasks` (`status`, `title`, `note`, `order`, `dependsOn`, `batch`, `batchLabel`,
`updatedAt`), writes it with `ArtifactData`, and links it to the item with
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

### Other tools

- **ripgrep** (`rg`): transcript search.
- **terminal-notifier**: clickable notifications that open the chat (else plain `osascript` ones).
- **Warp**: the "open in a terminal tab" actions (`qm resume`, `qm term`).
- **Arc**: a notification's click brings the GUI's tab to that chat.

### macOS-only pieces

- Notifications: `osascript` (or terminal-notifier).
- Opening URLs, Warp tabs and the GUI: `open`; focusing the GUI tab in Arc: `osascript`.
- Keeping the Mac awake while chats work (`qm caffeinate`): `/usr/bin/caffeinate`.

## config.yml

`~/.claude/quartermaster/config.yml` maps project names to repo roots. Sessions in a repo (or
its worktrees) get that project; everything else is "No project". A project is a plain path,
or a mapping with `root:` plus optional feature keys. A missing key leaves that feature off.

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
- **`qm gui` listens on `127.0.0.1` only** and refuses requests from other origins, but
  anything on your machine that can reach that port can drive it, and it can run commands:
  tmux chats running `claude`, `git worktree` add and remove, `gh`, and whatever dev-server,
  test-database and IDE commands you configure.
- **Some features start `claude -p` in the background** (summaries, asides, benchmarks), which
  counts against your Claude usage or API bill.
- **Nothing is sent anywhere by qm itself**, except through the tools it calls: `gh` (GitHub),
  `claude` (Anthropic), and the claude.ai artifacts you choose to publish.

## Development

```sh
cargo test                                                # unit tests, goldens, the GUI server's tests
QM_RUBY_ORACLE=$PWD/../qm-ruby cargo test                 # plus the Ruby-vs-Rust comparisons (see below)
```

The comparisons against the old Ruby implementation need a checkout of the last commit that had it:
`git worktree add ../qm-ruby 6c25480`; without `QM_RUBY_ORACLE` they skip
([testing](docs/areas/testing.md)).

Tests run against a temporary `QM_ROOT` and their own tmux socket, never your live data. Start
with [`CLAUDE.md`](CLAUDE.md) (the hard constraints) and [`docs/README.md`](docs/README.md),
which indexes one page per area.

## License

[MIT](LICENSE)
