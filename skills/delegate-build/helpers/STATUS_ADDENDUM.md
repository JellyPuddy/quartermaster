Board instructions for builders and reviewers of the delegate-build skill. Your prompt gives the board URL, your task id, your start status and your final status.

A status board at the board URL shows the user your progress. You own one row on it: `collection: "tasks"`, `doc_id: "<your task id>"`. Write it with the `ArtifactData` tool (load its schema with ToolSearch `select:ArtifactData` when it is deferred), and leave every other row alone.

Every write carries `updatedAt`: the output of `date -u +%Y-%m-%dT%H:%M:%SZ`, run in Bash right before that write.

The row already exists, unless your prompt says it may not exist yet (see **New row**), so every write is an `update` pinned with `if_version`:

1. **Start.** `action: "get"` on your row and note its `version`. Then `action: "update"`, `if_version: <that version>`, `data: {status: "<your start status>", note: "", updatedAt}`. Each write's result carries the row's new `version`; pin your next write to it.
2. **Checkpoints.** At 1-2 meaningful milestones, `update` with a few words in `note` ("schema migrated", "specs green") and a fresh `updatedAt`.
3. **Blocked.** When you need the user's decision, `update` with `status: "blocked"` and the question in `note`, then follow the blocked-question steps in `BRIEF_RULES.md`. Once answered, `update` back to your start status.
4. **Finish.** `update` with `status: "<your final status>"` and a one-line `note` on what you did.

**New row.** When your prompt says your row may not exist yet, `get` it first. If it exists, carry on from step 1. If not, `get` the proposer's row your prompt names, then create yours with `action: "set"` and no `if_version` (a pinned write cannot create a row): `data: {status: "<your start status>", title, note, dependsOn, batch, batchLabel, order, updatedAt}`, with title, note and dependsOn from your prompt, batch and batchLabel copied from the proposer's row, and order the proposer's plus 0.5. Pin your next write to the version the `set` returns.

A pinned write refused for a version mismatch names the current version: redo the same write pinned to that version. When the `get` finds no row and your prompt doesn't say it may not exist yet, skip the board for the rest of your run and say so in your handback.

These are your only board calls.
