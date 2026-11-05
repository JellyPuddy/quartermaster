---
name: rotate
description: Hand this work-item chat over to a fresh session - record what the work item is missing, then qm rotates once this turn ends. /rotate close wraps up and closes instead.
disable-model-invocation: true
argument-hint: "[close]"
---

You are the chat of a work item running in the qm gui, and the user asked you to rotate: a fresh session takes over from the work item's notes, so whatever is not in the work item is lost with this context.

1. **Hand-over notes.** Record every decision and open item from this session that the work item does not hold yet, following the work-item protocol injected at session start: `qm note <slug> "..." --kind decision|open|history`, and `qm retag <slug> <position> <kind>` for an `open` note that is now resolved. Done when a fresh session reading only the work item's digest would know what was decided and what is still open. One line per fact; skip what the notes already say.
2. **Request the rotation.** Run `qm rotate --self`, or `qm rotate --self --close` when the argument is `close`. It returns at once; qm waits for this turn to end, then exits this chat and starts the fresh one in the same pane (or closes it with `--close`). When it refuses, tell the user its message in one line and stop: nothing rotates.
3. **End the turn** with one line: what you recorded and that the rotation follows. Make no further tool calls; the rotation starts when this turn ends.
