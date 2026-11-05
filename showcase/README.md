# qm showcase

Material for showing colleagues what qm can do: the real `qm gui` running on fake data
(the "Bakery webshop", a fictional Rails shop for a bakery), screenshots of it, and a
narrated overview video. Everything generated goes into `showcase/out/`, which git ignores.

## The demo world

```sh
showcase/demo-world/run    # wipe + reseed showcase/out/demo-world, start qm gui, print the URL
showcase/demo-world/stop   # stop that gui and kill the world's tmux server (its chats)
showcase/demo-world/seed [DIR]   # only (re)build the world, into DIR if given
showcase/demo-world/qm show gift-cards   # any qm command inside the world (QM_DEMO_WORLD=DIR for another)
```

The GUI serves on a port of its checkout's own, which `run` prints: a stable hash of the
world's absolute path picks it from 7700–8699 (the user's own `qm gui` keeps 49737), and its
chats run on tmux socket `qm-demo-<hash>` from the same path. So the main checkout and each
worktree run their own demo world side by side, and a script in a worktree never reaches
the main checkout's world. `QM_DEMO_PORT=7788` and `QM_DEMO_TMUX_SOCKET=qm-demo` override
them (set them for `run`, `stop`, `qm` and `capture.rb` alike). It opens nothing; point a
browser at the URL yourself. Its output lands in `out/demo-world/log/gui.log`.

The world is one directory, rebuilt from scratch on every run:

- `home/` — the GUI's `HOME`: `.claude/quartermaster` is its `QM_ROOT`, `.claude/projects`
  its `QM_TRANSCRIPTS_DIR`, `code/bakery-shop` and `code/bakery-design-system` the two
  projects' repos (history on main, feature branches, worktrees under `.claude/worktrees`,
  a merged spike for cleanup, and a three-layer gh-stack stack). Their origin is a GitHub
  URL that the world's gitconfig rewrites (`insteadOf`) to a bare repo under `remote/`,
  holding the pushed branches and `refs/pull/<n>/head`; https and ssh stay refused.
- `phone/index.html` — the phone page (`skills/work-items/page.html` with a local stand-in for
  its data store) over `phone/overview.json` from `qm overview --json`; open it at phone width.
- `bin/` — stub programs, first on the GUI's `PATH` and also its `~/bin`.
- `fixtures/` — what the stubs answer (below).
- `log/` — `gui.log`, and one JSON line per stub call: `gh.jsonl`, `claude.jsonl`, `stubs.jsonl`.

The GUI runs with only the world's environment (`DemoWorld::World#env`), so it never sees
the user's `~/.claude`, the `qm` tmux socket or their `CLAUDE*` variables.

### Stubs

- `gh` answers from `fixtures/gh/*.json`: arrays of `{match: [regex…], stdout, stderr, exit}`
  routes matched against the call's arguments joined by spaces; the most specific match
  wins. An unmatched call fails and is logged with `matched: null` in `log/gh.jsonl` —
  that is the list of fixtures still missing.
- `claude` prints a canned Claude Code screen and waits: `fixtures/claude/<slug>.txt` for an
  item's chat (slug from `QM_ITEM` or the tmux session name), `sessions/<id>.txt` for a
  `--resume`, else `default.txt`. `claude -p` prints `print.txt`.
- `open`, `osascript`, `terminal-notifier`, `devserver`, `curl`, `bakery-test-db`, `bakery-ide` (the world's `ide_command`),
  `caffeinate`, `pbcopy` log and do nothing else (`devserver` and `bakery-test-db` only answer
  from files, below); `curl` fails, so no status URL answers. qm's caffeinate runs
  `/usr/bin/caffeinate` by absolute path, so the ☕ toggle does keep the Mac awake — harmless,
  and it exits with the GUI.
- The Bakery webshop's config.yml entry is a mapping with `root:`, `dev_server:` (`devserver`,
  modes dev and tunnel, its `state_file` under the world's home) and `test_db: bakery-test-db`,
  so the GUI shows the mode controls and cleanup's test DBs. The `devserver` stub keeps only
  files in `home/.devserver/`: `switch` writes `state` and the `running` marker that `status`
  checks, `stop` removes the marker. The world is built serving the `gift-cards` worktree in
  dev mode. `bakery-test-db drop PATH --dry-run` names `bakery_test_<worktree>`.

A world seeded into another directory (`seed DIR`, `QM_DEMO_WORLD=DIR`) likewise gets a port
and tmux socket of its own from that path, so it never touches the running demo's chats.

### What the world contains

Times are relative to the seed, so the world never looks stale. `lib/demo_world/cast.rb`
scripts every session (who said what, when, which tool calls); the steps in `seeds/` write
the rest through qm's own classes where they exist, in a child process with the world's env.

| Story | What is there |
|---|---|
| Work items | 8 items: 5 in progress, 2 fridge, 1 resolved — notes of every kind, branches, a temp branch, a status board, a recorded rotation, distilled snapshots; `allergen-filter` is stale and has a transcript about to expire, plus one already pruned |
| Attention | live chats in tmux on the demo socket, each running the stub `claude` resumed on its session: `checkout-flow` blocked on a permission prompt, `gift-cards` your turn, `delivery-slots` working, `button-variants` waiting on a background agent; 2 unattached sessions in the inbox |
| Context | chat history above every chat; `delivery-slots` at 237k context (rotate?) with an earlier rotation divider, an earlier aside (promoted to a note) and a live aside drawer |
| Review | `gift-cards`: committed + uncommitted + untracked work, prompt snapshots for Since prompt, 2 viewed files, chat diff comments, a page annotation anchored on `GiftCardForm.jsx`, a GitHub review draft by the user and one by Claude (`qm draft add`), a thread reply; PR #38 with open, resolved and outdated review threads; the checkout stack #41 ← #42 ← #43 |
| PRs | 8 open PRs over both repos (yours, review requested, assigned) with CI chips, review decisions and three prerequisites (pending, not merged with a note, deployed) |
| Issues | `allergen-filter`'s issue drafts: one created (#57), one revised since last seen, comments on it; a bug draft on `checkout-flow`; `gh issue view` answers #57, #61, #63 and closed #29 for Start from issue; cleanup and sweep have the spike worktree and merged branch to offer |
| Side panel | usage and cost from the transcripts (`usage-cache.json`), rate limits (42% 5h, 61% week), the gift-cards board with a blocked row and an answers dir, and a running Workflow so Check build progress estimates two agents (the stub answers `--json-schema` calls from `fixtures/claude/structured.json`) |

### Adding demo data

`lib/demo_world.rb` is the module: `DemoWorld::World` names every path and the env, and
`DemoWorld::Repos` the branches, worktrees and PR numbers the fixtures must agree with.
Seeding data is a step: a file in `demo-world/seeds/` that calls

```ruby
DemoWorld.step("work-items") { |world| ... }   # world.work_items_dir, world.gh_fixtures_dir, …
```

Steps run in file-name order once the core world (home, stubs, repos, `config.yml`) exists.

## The screenshots

`shots/shots.yml` lists every screenshot; `shots/capture.rb` takes them from the demo GUI
with a headless Google Chrome and writes `out/shots/<id>.png` (2x device pixels, so the
video can cut to sharp close-ups).

```sh
ruby showcase/shots/capture.rb                     # every shot
ruby showcase/shots/capture.rb --shot diff --shot prs
ruby showcase/shots/capture.rb --list              # ids, taken or missing, what each shows
```

When nothing answers on the demo port it runs `demo-world/run` first. The phone shot reads
the world's `phone/index.html`; `QM_DEMO_WORLD=DIR` points it at a world other than
`out/demo-world`. Chrome runs with a throwaway profile in `out/chrome-profile` (removed
afterwards; its stderr in `out/chrome.log`) and DevTools on a port it picks itself, so it
never touches your own Chrome or the user's `qm gui` on 49737. Each shot gets a fresh browser
context, so nothing one shot did (localStorage, the remembered view) leaks into the next.

A shot is a URL, a viewport, a theme and steps — keys, clicks, JavaScript (the GUI's page
globals such as `selectChat`, `openDetail`, `toggleDiff` are all reachable), waits for a
selector — and optionally a `clip` for a close-up. The header of `shots.yml` lists the keys.
Two rules keep shots clean:

- Open a chat with `selectChat`, not `openChat` or `#chat=`: those focus the terminal, and
  any key pressed afterwards is typed into the demo chat's tmux pane (it stays there until
  the world is reseeded).
- Clip to a selector that survives a re-render (`:has()` helps), not to an id set in an
  eval step: the next poll can redraw the element without it.

Before the screenshot the script blurs the focused element, hides the text caret and
waits two frames. `capture.rb` speaks the DevTools Protocol itself (`shots/cdp.rb`: a small
WebSocket client over `TCPSocket`), so it needs no gems and no node.

## The video

`video/storyboard.yml` is the script; `video/render.rb` turns it into
`out/video/qm-overview.mp4` (1920x1080, 30 fps, H.264 + AAC). It needs `ffmpeg`/`ffprobe`,
ImageMagick's `magick` and macOS `say` on PATH.

```sh
ruby showcase/video/render.rb                # render every scene and stitch the video
ruby showcase/video/render.rb --scene board  # render one scene, print its mp4 path
ruby showcase/video/render.rb --list         # scenes, cache status, durations, missing shots
```

Each scene is cached as `out/video/cache/<id>-<hash>.mp4`, keyed by its own fields, the
settings that affect a scene and the bytes of its shots. Editing one scene's caption or
re-taking one shot re-renders only that scene, then the final stitch; a re-run with no
changes renders nothing. Changing `crossfade` only redoes the stitch. Old cache entries are
never cleaned up automatically; `rm -rf showcase/out/video/cache` starts fresh.

### Writing scenes

Each scene in `storyboard.yml` has:

- `id`: a lowercase slug, used in the cache file name and `--scene`.
- `caption`: the on-screen text. `style: lower_third` (default) puts it in a bar at the
  bottom; `style: title` puts it large and centered on a darkened frame.
- `visual`: a PNG under `showcase/out/`, e.g. `shots/board.png`. A list gives a sequence,
  each entry a path or `{file, duration, focus}`. Entries without a `duration` share the
  time left.
- `focus` (optional): `[x, y, w, h]` in the source image's pixels. The camera eases toward
  that rect and holds; without it, it pushes in slowly.
- `voiceover` (optional): spoken with `say`. Its length plus a short lead-in and padding
  sets the scene's length.
- `duration` (optional): seconds, for a scene without a voiceover, or a minimum with one.

`settings` holds the voice (default `Daniel`; `say -v '?'` lists others), speech `rate`,
resolution, fps, `crossfade` seconds and the caption fonts and colors.

A shot that doesn't exist yet renders as a placeholder card naming the scene, the missing
file and the caption, so the video renders before any screenshots are taken. `--list` shows
which shots are still missing.

### Shots the storyboard expects

Every `shots/<id>.png` a scene shows is a shot in `shots/shots.yml` (a test checks the two
agree), so `ruby showcase/shots/capture.rb` takes them all; any other PNG under
`showcase/out/` works too (any size; it is fitted to 16:9). Full-window shots are 3840x2160,
so a scene's `focus` is in those pixels; close-ups (`inbox`, `review-draft`, …) are their
element's size at 2x and usually go without one. After re-taking a shot, run the renderer
again: only the scenes that show it re-render.

## Tests

`ruby test/showcase_demo_world_test.rb` seeds the core world into a tmp dir and checks it is
complete and that its env points nowhere outside it; `ruby test/showcase_demo_data_test.rb`
seeds the whole world (every step, chats on a test tmux socket) and checks each story's data,
that every gh call met a fixture, and that nothing mentions the user's live `~/.claude`.
`ruby test/showcase_video_test.rb` checks storyboard parsing and scene hashing without ffmpeg;
`ruby test/showcase_shots_test.rb` checks `shots.yml` parsing, that it covers every storyboard
shot, and the DevTools client's WebSocket framing, without Chrome.
