# Stacks

**Code:** `lib/quartermaster/gh_stack.rb`, `lib/quartermaster/gui/js/stacks.js`, `lib/quartermaster/gui/css/stacks.css`
**Tests:** `test/restack_test.rb`, `test/gh_stack_test.rb`
**Depends on:** [work-items](work-items.md), [chats](chats.md), [prs](prs.md), [side-panel](side-panel.md), [diff](diff.md)

## What it does

**Reading gh-stack** (`GhStack`): the gh-stack extension records stacks in `<git common dir>/gh-stack` (JSON, shared by every worktree): `stacks[]`, each with `branches[]` bottom → top (`branch`, optional `pullRequest {number, url}`) and an optional `trunk {branch}`. qm reads it, never writes it. `GhStack.for_root` finds the file via the common git dir and caches the parse per file mtime, so an unchanged file costs one `stat`; a root that isn't a git repo is cached too.

**Auto-link**: every branch of every stack holding any of an item's branches is linked to the item (`GhStack#link_into` → `WorkItem#link_branches`, under the work-item lock, idempotent, write-free when nothing is missing). `GhStack.sync` does it on every state build — the GUI state and `qm show` — and `TargetWorktree#resolve` does it too, so the stack top is known.

**Chains** (`GhStack.chains`, the item payload's `chains`): an item's linked branches minus mainline, as `[{kind: "stack"|"loose", trunk, layers: [{branch, pr_number, pr_url, prState, parent, ahead, needsRestack, merged, worktree}]}]`.

- Every stack holding one of the item's branches (an item can straddle two after a re-stack), bottom → top, newest-linked first; then every other branch as a loose chain of one, newest-linked first. Chains come only from gh-stack, never from PR bases.
- Per stack layer: `parent` (the layer below; for the bottom, the stack's trunk as gh-stack records it, else the first existing trunk ref), `ahead` (`rev-list --count parent..branch`), `needsRestack` (the parent's tip is not an ancestor of the branch), `merged` (PR state `MERGED`). Branches resolve locally, else from `origin/`; the trunk from `origin/` first, as the diff pane's base does. Loose layers carry branch and PR facts only.
- A PR number/url gh-stack hasn't recorded (every loose branch's) comes from `PrStatus#link_for`, a cache read.
- `GhStack.sync`'s return value — "the item's stack" — is the stack holding its most recently linked stacked branch (`stack_for`); `TargetWorktree` targets its top.
- `qm show` prints a `stack:` line per stack, trunk first, ⟳ on a layer needing a restack.

**Restack** (`restack` GUI action, `GuiActions#gui_restack`, args `branch` optional): only on the user's click of a ⟳, qm hands the restack to the item's chat as a one-line prompt: the stack `trunk ← bottom ← … ← top`, the layers flagged `needsRestack` (or that none is), and the ask to run `gh stack rebase` (the gh-stack skill) and resolve conflicts or stop and report the ones it can't resolve safely. `branch` picks the stack holding it, else the item's first stack.

- A live pane gets the prompt typed; refused while the chat is mid-turn (working/blocked) or waiting on background work.
- Without a pane, a fresh chat starts with it as its first prompt (`Launcher#chat_plan(prompt:)`, the item's usual start cwd); a chat running outside the GUI refuses.
- An item with no stack, or a `branch` in none of its stacks, refuses.

**The page** (`stacks.js`, shared by the side panel's rails, the chats list and the diff strip):

- **One selected branch per item** drives both the diff pane's branch and the Workspace target (pf, the IDE, Terminal, Work on this). An explicit pick (a rail node or the diff bar) is remembered per slug for the browser tab in sessionStorage `qm-branch-picks` (`""` = the chat's own folder); a pick no longer naming the chat's folder, a linked branch or where the chat runs falls back to the default. Default: the branch the chat runs on when a chain holds it, else the top of the first chain — the server answers it with the workspace fetch (`defaultBranch`, `Gui#default_selection`), since only it can ask where the chat runs.
- The diff pane asks for no branch while the default is the chat's own (the server's default is the chat's checkout), so the default costs no reload. Selecting a branch keeps the diff's scope unless that scope needs a checkout the branch lacks (then Branch). The workspace fetch and its actions only send a chain's branch.
- **Layer status** (`layerStatus`): merged, closed, no PR, or for an open PR draft / approved / changes requested / review required / open — the review state from the PRs view's list (`prs`), since a layer only knows OPEN/MERGED/CLOSED. `layerPrChip` is the `#PR + state` chip of rail nodes and the diff's layer headers.
- **Chats list**: a thin segment bar under the title (`chainSegmentBar`) — one segment per stack layer and per loose chain, a gap between chains, coloured by layer status, hatched where an unmerged layer needs a restack — and an amber `⟳ n` in the row meta (`restackCount`: open layers behind their parent). Visual only: no badge, no notification. The shrunk chats strip hides both.
- **Stale pf** (`stalePfText`): "pf serves ③ while the chat is on ⑤" when pf serves a lower layer of the stack the chat runs on.
- The rails themselves render in the side panel (`chat-side.js`, see [side-panel](side-panel.md)); their ⟳ calls `restackStack` → the `restack` action with that branch.
- **Rails**: one per chain — a stack's layers top first above its trunk anchor, a loose branch as a one-node rail. A node: number dot coloured by layer status, the branch with the stack's common prefix stripped (`chainPrefix`), `top`, ◆ when the chat runs on it, 🖥 when pf serves its checkout (`servedBranch`), #PR chip, ahead count, ⟳, worktree chip. Only the selected node has action buttons, built by `railTools` in `.rail-tools` (whose click never reaches the node's select): 📊 branch stats and 🏁 benchmark (items whose project configures benchmarks, with its finished-run dot) — the diff bar's own builders, `branchStatsButton(slug, branch)` and `benchmarkButton(item, branch)` ([diff](diff.md), [benchmarks](benchmarks.md)) — then **Diff ›**.
- Merged layers fold into "n merged ▾" (a selected merged layer stays in view); with three or more chains, those not holding the selection fold to a one-line summary that opens on a click (`railMergedOpen`/`railChainOpen`, per page life).

## Rules

- Stack branches are auto-linked on every state build: unlinking a branch still in the item's gh-stack doesn't stick — remove it from the stack first.
- A missing gh-stack file, bad JSON or an unfamiliar shape reads as "no stacks"; entries not shaped like a named branch are skipped. qm must keep working whatever the extension does next.
- `GhStack.sync` and `GhStack.chains` never raise (logged): a stack panel is not worth a failed page load.
- A restack is never automatic: ⟳ only marks a stack, and only the user's click sends the prompt — never a state build, poll or the notifier. qm itself never runs git or gh for it.
- The restack prompt is one line: typed into a pane, each newline would submit.
- Refused while the chat waits on background work: its report would land on top of the typed prompt.
- `needsRestack` is checked only above another stack branch: the trunk always moves, so the bottom layer is never flagged.
- `merged` is the PR's word, not git's: a squash merge leaves nothing in git to tell.
- A state build spawns no git for an unchanged repo: tip shas are read from the common git dir (loose ref files, `packed-refs` parsed once per mtime/size; only a reftable repo asks git), and `rev-list`/`merge-base` answers are cached per process keyed on the tip shas (`GhStack::FACTS`, bounded).
- A selected branch the item doesn't link is refused server-side (`TargetWorktree.require_linked`), so the page sends only chain branches.

## Data

- `<git common dir>/gh-stack` — owned by the gh-stack extension (`schemaVersion` 1); qm reads `stacks[].branches[].branch`, `.pullRequest.{number,url}` and `stacks[].trunk.branch`, and ignores the rest.
- sessionStorage `qm-branch-picks` — slug → picked branch, per browser tab.

## Known limits

- PR numbers for loose branches are only as fresh as `pr-cache.json` (an entry cached before numbers were kept gains them on its next refresh).
- The review-state colours need the PR in the PRs view's list (the user's own open PRs); other layers show plain open.
