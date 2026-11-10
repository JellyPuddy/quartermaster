# Rejected and deferred

Ideas that were weighed and not built, so a future session doesn't re-litigate them without
new reasons. One line each, with the reason.

## Rejected

- **Memory/CLAUDE.md instructions alone for linking** — best-effort; SessionStart hook stdout
  is harness-guaranteed and self-announcing, so memory is only the backup.
- **A headless summariser on every session end** — costs a model call per session; end events
  carry mechanical facts only and distill is on demand.
- **Review as a work-item state** — it is derived from the item's PR, not stored.
- **Clickable header buttons and a right-click menu in the fzf viewer** — fzf's `click-header` +
  `execute` handoff didn't reliably give the terminal to picker actions; only double-click to
  resume stayed, clickable actions live in the web GUI.
- **GUI self-shutdown (heartbeat/bye, liveness timers)** — hidden tabs throttle timers and a
  stale tab's bye killed newer servers; removed wholesale. The server runs until Ctrl-C.
- **One shared tmux session with a window per item** — when a chat ends tmux moves every
  attached pane onto another item's window; one tmux session per item instead.
- **Automatic context rotation or restack** — both type into the user's chat; only their click starts them.
- **Checking out a branch in an existing worktree** — it may hold uncommitted (agent) work; a
  new worktree is made instead.
- **Other agents (Codex, Gemini, …) and one prompt fanned out to several worktrees** — the user
  uses Claude only; fan-out multiplies cost for a comparison he rarely wants.
- **A built-in editor** — the IDE's job (`qm work-on` opens the configured one).
- **SSH worktrees, remote servers, a native mobile app, an account switcher** — no problem
  the user has; Remote Control plus the `/work-items` phone page covers mobile.
- **Linear/Jira panels** — GitHub only.
- **Several live sessions per item** — 3-5 days of work; parallel work goes in two
  items, or an aside.

Adopted from the same Orca (onorca.dev) comparison: notifications, usage limits, diff review
with comments, transcript search, and page annotations (Orca's "Design Mode", taken from a
dev server's page overlay). Orca is a worktree cockpit without work items or context injection, so it is
no qm replacement.

## Deferred

- **Cross-machine sync** — git the `~/.claude/quartermaster` dir.
- **More work-item states** — only if usage demands it.
- **Auto-title fallback** from the first user prompt for items Claude never titled.
- **Phone push when a chat is blocked**, ideally through something the Claude app already
  does — researched, not built.
- **Todos: due dates and reminders; todos on the phone page** (adding from the phone needs a
  write path the static page doesn't have); **todos on board cards or the side panel** — a todo
  on an item shows only as that item's chip in the Todos tab.
- **Clipboard annotations: ⌘V paste import**, and a global key that finds the item by
  checkout as the pf relay does.
