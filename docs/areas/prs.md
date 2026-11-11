# PRs

**Code:** `lib/quartermaster/pr_inbox.rb`, `lib/quartermaster/pr_items.rb`, `lib/quartermaster/pr_review_start.rb`, `lib/quartermaster/pr_status.rb`, `lib/quartermaster/pr_prerequisites.rb`, `lib/quartermaster/pr_deployment.rb`, `lib/quartermaster/gui/js/prs.js`, `lib/quartermaster/gui/css/prs.css`
**Tests:** `test/prs_view_test.rb`, `test/pr_review_start_test.rb`, `test/pr_prerequisites_test.rb`, `test/pr_deployment_test.rb`
**Depends on:** [work-items](work-items.md), [gui-shell](gui-shell.md), [worktrees](worktrees.md), [review](review.md)

## What it does

**PR state per linked branch** (`PrStatus`): `gh pr view <branch> --json state,number,url` in the project's root, cached in `pr-cache.json` keyed `<project>#<branch>`. The CLI blocks on an expired entry; the GUI (`background: true`, for the board and cleanup plans alike, asking through `Gui.new`'s `pr_fetcher:`, nil = gh) serves the stale entry and refetches on a thread, one fetch per key in flight, and `refreshing?` says an answer may still improve. `link_for` reads the cached number/url only (the chains' PR chips for branches gh-stack hasn't recorded). `open_web` opens a branch's PR (default: the newest linked branch, a stack's tip).

**The PRs view** is the third header mode, `Board | Chats | PRs | Issues` (key `p`). It lists every open PR the user wrote (`author:@me`), is directly asked to review (`user-review-requested:@me`) or is assigned (`assignee:@me`), across all repos, from one `gh api graphql` call with a search per role (`PrInbox`). Results merge by URL, each PR carrying every role it matched, newest activity first. `GET /api/prs` (`Gui#prs_payload`, off the action mutex) adds per PR: `label` (`<repo>#<n>`), `project` (a repo maps to the configured project whose main checkout's `origin` it is, worked out once per GUI — `PrItems#project_for_repo`), `item` (the item holding the PR's head branch, unresolved first) and whether its chat `pane` is live, `reviewItem`, `worktree` (where the head is checked out), `served` (pf serves that worktree), `jobKey` and `prerequisites`.

- **Groups**: Review requested, Yours, Assigned to you (a PR goes in the first that matches). Within a group, a PR whose base is another listed PR's head (same repo) sits on that one: chains run bottom first, headed `stack · n PRs onto <base>` with approved/changes-requested tallies, rows numbered `i/n`; a chain keeps the place of its most recently updated PR; a base cycle still shows, unordered.
- **Row**: `<repo>#<n>` linking to GitHub, draft badge, review badge (approved / changes requested / review required), CI chip, prerequisite chips, a running job's label; title; author, `head → base`, updated-ago, 🌳 worktree, 🖥 when pf serves it, the item link (with "(live)") and the review item link.
- **Review decision**: GitHub's `reviewDecision`, or — where branch protection requires none, e.g. a PR onto a stacked branch — each reviewer's latest review: changes requested over approved.
- **CI chip** (`PrInbox.ci`): the head commit's checks like GitHub's PR page — `✓ 31 / 31`, `✗ 28 / 31`, `● …` while running — linking to the PR's checks tab. Only each workflow's newest check suite counts, and within it each check's latest attempt. OK = success, neutral, skipped; any failure, error, cancelled, timed-out, action-required, startup-failure or stale latest run makes it red.
- **Mode tally** on the PRs toggle: the user's own non-draft PRs as ✓approved / ✗changes / open, then the count waiting on them (review requested, or assigned and not a draft).
- **Actions** (buttons and keys; `j`/`k`/arrows move, `c` new item):
  - **Chat** (⏎, `pr-chat`): opens the chat of the item holding the PR's branch; with none, creates item `<repo>#<n>: <title>` with the branch linked and the PR summarised in its description.
  - **Review** (`w`, `pr-review`): a separate item `Review <repo>#<n>: <title>`, found again by slug prefix, no branch linked, a resolved one reopened to in_progress; started fresh in the main checkout with the project's `review_skill` (config.yml, default `/code-review`; the PR payload's `reviewSkill`) and `<url>` plus the instruction to record each finding with `qm draft add <slug> …` instead of posting to GitHub and, when done, its overall verdict and a short summary with `qm draft add <slug> --summary --verdict … --body …` (`PrItems#review_kickoff`). A pane already running is attached to; a session of the item running outside one refuses. `PrItems#review_pr` reads a Review item's PR back from its description. The logic is `PrReviewStart`, which needs no GUI (tmux, `PrItems` and project map injected) so the pr-review automation flow calls it too: `start(pr, extra_argv:, kickoff_suffix:)` puts extra flags before the kickoff (still the last argument) and appends a non-blank suffix as its own paragraph; `live?(pr)` says whether the Review chat runs, in a pane or outside, creating and starting nothing.
  - **<IDE label>** / **<dev-server command>** (`pr-ide` / `pr-pf`, the former only when an `ide_command:` applies to the PR's project, payload `ide` (its label), the latter only when it has a `dev_server:`, payload `devServer`): act on the PR's own head branch — its existing worktree, else a new one (`TargetWorktree#materialize_branch`) — as a background job keyed by the PR's item when it has one, else by the label. The switch uses the item's `pf_mode` or the server's default mode.
  - **GitHub ↗** (`o`): a plain link; the row's label links there too. The item links open that item's chat.
- `prs.js` also holds the page's `setMode`, `openChat` and `pulseTick` (the ~1 s `/api/pulse` poll; see [gui-shell](gui-shell.md) and [attention](attention.md)).

**PR prerequisites** (`PrPrerequisites`): a PR may need an earlier PR or commit of the same repo *deployed* before it merges. qm records this locally only.

- Entry fields: `kind` (`pr` | `commit`), `ref` (PR URL or full 40-char sha), `repo`, `addedAt`, `session` (`--session`, else `CLAUDE_CODE_SESSION_ID`, else nil), optional `note` (free text such as a backfill to run between deploy and merge; trimmed, line breaks kept, blank = absent).
- `qm pr-requires <pr-or-sha> [--pr <pr>] [--note TEXT]` adds; `--remove <pr-or-sha>` removes (a sha prefix matching one stored commit, no gh call); `--list` lists, each note indented under its prerequisite, without `--pr` and without a branch PR every entry. `--note` on an existing prerequisite sets or replaces its note instead of the "already requires" refusal, `--note ""` clears it; `--note` with `--remove`/`--list` is a usage error.
- `<pr>` is a URL, `owner/repo#n`, or `#n`/`n` against cwd's `origin`; omitted, the current branch's PR (`gh pr view --json url`). A bare number is always a PR, never a sha. A short sha resolves via `gh api repos/<o>/<r>/commits/<sha>`.
- Agents learn the command from a SessionStart protocol line, only in projects with `pr_prerequisites: true` (`HookHandler#pr_requires_protocol_line`, ~30 tokens, names `[--note TEXT]`).

**Deploy check** (`PrDeployment`): *deployed* = contained in the repo's latest published release (`gh api repos/<o>/<r>/releases/latest`, which skips drafts and prereleases). The commit is a `commit` prerequisite's sha, or a merged `pr` prerequisite's `mergeCommit.oid` (`gh pr view <url> --json state,mergeCommit`); containment via `gh api repos/<o>/<r>/compare/<tag>...<sha>`, `behind`/`identical` = deployed. States: `deployed` (+ tag), `pending` (+ the tag it is not in), `unmerged`, `closed`, `unknown` (not fetched yet, or every lookup failed).

- **On the tab**: each prerequisite is a chip after the CI count — `⏳ needs #1234 — not in 2026.10.8` (amber), `needs #1234 — not merged`, `needs #1234 — closed` (red), `needs #1234 — ?` (unknown), `✓ #1234 deployed in 2026.10.8` (green); a commit shows its 7-char sha. The chip links to the PR or commit; its ✕ posts `pr-unrequire` (`url`, `ref`) through the same store, then reloads. A chip with a note ends in 📝 and its body opens a `.pop` popover (`prReqNote`) with the note as escaped `pre-wrap` text and a focused "Open … on GitHub ↗" link; it closes on outside mousedown and Esc (`popAt`/`closePop`).
- The page polls `/api/prs` every 2 s while `refreshing` (inbox fetch) or `prerequisitesRefreshing` (deploy check) is true.

## Rules

- Review requests use `user-review-requested:@me`, never `review-requested`, which also matches every team and buried the direct requests.
- `GET /api/prs` never waits on GitHub: the inbox is cached 5 min in `pr-inbox.json` and refetched single-flight on a thread; the page's Refresh forces one.
- A GraphQL `errors` body (gh exits 0, searches null) raises, so a failed fetch keeps the last good list with its error instead of caching "no open PRs".
- Actions name a PR by URL only; the server takes every other field from the inbox cache (`PrInbox#find`), never from the page. A PR not in the cache is refused ("refresh it").
- A Review item links no branch: a branch on two items makes auto-matching ambiguous. Its findings go to qm drafts, not GitHub.
- CI counts only each workflow's newest check suite and each check's latest attempt; the rollup (and `gh pr checks`, keyed by name) counts a concurrency-cancelled earlier suite whose jobs even start later.
- `PrStatus` caches by how soon the answer changes: merged/closed 6 h, open 5 min (the PR about to merge — a stack layer's merged chip must not lag), "no PR" 10 min (a PR is usually opened within the hour). A failed or offline `gh` reads as "no PR" too, so it retries after 10 min.
- Nothing about prerequisites is written to GitHub; every `gh` call is read-only, through injectable seams (`gh:`, the deployment `fetcher:`, the GUI's `pr_fetcher:`); tests never call gh — test_helper gives every `Gui` a "no PR" `pr_fetcher` unless the test passes its own.
- The store never holds a short sha; every PR form goes through `gh pr view <url>` so its key has GitHub's casing of `owner/repo` — otherwise it never matches the inbox's URLs.
- A cross-repo or self prerequisite is refused; adding the same one twice is a no-op. CLI errors are one line, exit 1.
- Store writes are read-modify-write under a mutex (GUI threads) plus a `flock` (CLI processes), then temp file + rename.
- Deploy answers come from the cache only; `states` (the GUI) starts a single-flight background refresh when anything is stale. `qm pr-requires --list` reads the cache without refreshing (its process would exit first), so it is as fresh as the GUI's last refresh.
- Release tag, PR states and pending verdicts expire after 5 min; a pending verdict is also re-checked once the latest tag differs from the one it was checked against. `deployed` (per sha) and `MERGED` with its merge commit are final.
- Each lookup fails on its own and keeps its last good answer; a failed lookup still counts as attempted, so one that keeps failing (a repo without releases) retries once per TTL, not every poll. `unknown` never shows as deployed.
- Pruning is the store's only automatic removal: the deploy refresh drops entries whose dependent PR GitHub confirms `MERGED` or `CLOSED`. A failed lookup never prunes, and absence from the PR inbox never prunes (it only holds the user's author/review/assignee PRs). Deployed prerequisites stay, as the green chip.
- The cache drops entries the store no longer names.
- Adding a prerequisite and editing a note stay CLI-only: an agent knows what its PR waits on, the tab doesn't. The tab only removes.
- ⏎ on a focused button or link inside a PR row is that control's own click; it must not also open the chat.

## Data

- `pr-cache.json` — `PrStatus`: `{"<project>#<branch>": {state, number, url, ts}}`.
- `pr-inbox.json` — `PrInbox`: `{prs, ts, error}`; each PR `url, number, title, repo, author, head, base, draft, reviewDecision, ci {state, ok, total}, updatedAt, roles`.
- `pr-prerequisites.json` (+ `pr-prerequisites.lock`) — `{v: 1, prs: {<dependent PR URL>: [entry…]}}`, insertion order. Entries from before notes read as no note.
- `pr-deployment.json` — `PrDeployment` cache, `v: 1` (another version reads as empty).

## Known limits

- The inbox holds at most 50 PRs per role search.
- `--list` and the GUI's chips are only as fresh as the last background refresh.
- Open PRs outside the inbox keep their prerequisites until GitHub reports them merged or closed; `--list` shows them.
