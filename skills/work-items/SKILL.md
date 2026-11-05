---
name: work-items
description: Show the user's qm work items on the phone-friendly work-items page, and drive their chats from here. Use when they ask to see their work items (or what's in progress, what's blocked, whose turn it is), to start or resume a session for a work item, or to rotate another item's chat.
---

The work-items page is a published artifact that renders one database document, `overview/current`, written from `qm overview --json`. Refreshing the page means rewriting that document. The snapshot travels by file path only: the JSON never enters your context, and `qm` prints the one line you reply with.

## Show the work items

1. `qm overview --url` prints the page's URL. When it exits non-zero, `overview_artifact:` is unset in `~/.claude/quartermaster/config.yml`: tell the user the page isn't published yet and stop.
2. `qm overview --page` prints the page file's path when it changed since it was last published, else nothing. When it prints a path, republish the page before writing data: `Read` that file whole, `Artifact` `action: "read"` on the URL (a publish to an artifact this conversation hasn't read is refused), then `Artifact` publish with `url` and `file_path` set to that path, leaving `capabilities` out so the page keeps its database rule. Then `qm overview --page-published` records it. Mention the republish in your reply.
3. `qm overview --json <scratchpad>/qm-overview.json` writes the snapshot (atomically) and prints its summary line. Keep that line.
4. `ArtifactData` `get` on the URL, `collection: "overview"`, `doc_id: "current"`, with `out_dir: <scratchpad>/qm-overview-db` so the old snapshot lands in a file instead of your context. Note the `version` the result reports. No document yet means this is the first write.
5. `ArtifactData` `set`, same URL, collection and doc_id, `file_path: <scratchpad>/qm-overview.json`, `if_version: <that version>` (omit `if_version` only on the first write). A version mismatch names the current version: redo the `set` pinned to it.
6. Reply with the URL and the summary line from step 3. That's the whole reply.

## Act on an item

When the user describes an item rather than naming its slug, find the slug with `qm list`. Each command drives the running `qm gui` (no GUI → it says so and does nothing):

- **Start a session** for an item: `qm pane-start SLUG` opens a fresh chat in the item's GUI tmux pane; it reports when one is already running.
- **Resume** the item's last session there: `qm pane-resume SLUG [--session ID]`.
- **Rotate another item's chat**: `qm rotate SLUG` (add `--close` to wrap up and close instead of starting fresh). It refuses mid-turn; tell the user to retry once that chat's turn ends. Rotating *this* chat is `/rotate`, which only the user starts.

After an action, run "Show the work items" again so the page reflects it.
