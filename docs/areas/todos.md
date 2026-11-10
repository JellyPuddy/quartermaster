# Todos

**Code:** `lib/quartermaster/todo_list.rb`, `lib/quartermaster/cli_todo.rb`
**Tests:** `test/todo_list_test.rb`
**Depends on:** [work-items](work-items.md), [linking](linking.md), [cli](cli.md)

## What it does

The user's own free-form to-do list: things *they* must do, often nothing a Claude session
does. It is not built from work-item `open` notes and not Claude's TodoWrite lists; nothing
turns a note into a todo or back.

**Storage** (`TodoList`). `todos.json` under the data root: `{"v": 1, "todos": [...]}`, an
ordered array whose order is the priority (index 0 on top). A todo is `id` (8 hex chars),
`text` (one line: whitespace runs, newlines included, become one space; required), `created`
(UTC ISO-8601), `done_at` (UTC ISO-8601, absent while open), and either `item` (a work-item
slug) or `project` (any string). A todo on an item stores no project: it shows the item's.
No due dates, priorities, tags or body. Every change (`add`, `edit`, `move`, `done`, `undone`,
`delete`) holds an exclusive `flock` on `todos.lock`, re-reads the file and rewrites it whole
through `AtomicFile`, so the CLI and the GUI both write it directly; reads take no lock.

**Adding and ordering.** A new todo goes on top. `move(id, before:|after:)` places a todo next
to a neighbour by id, so a reorder in a filtered view lands in the right place of the whole list.

**Done.** Ticking sets `done_at`; the todo stays in the file, and unticking clears it.
`open` is the open todos in order; `done_recent` the 20 newest done ones by `done_at`.
`done(id, item:)` also ties the todo to the work item it became, dropping its project.
Delete removes a todo outright. Nothing prunes the file.

**CLI** (`CliTodo`). `qm todo add [--item SLUG | --project NAME] "text"` adds on top (text may
start with `- `, or follow `--`); `qm todo list` prints the open todos numbered 1..n in order,
each with `[project · item]`; `qm todo done N` ticks the Nth of that list. There is no CLI
edit, move or delete.

**Sessions learn it** through one line of the linked work-item protocol ([linking](linking.md)):
when the user asks, or something needs their own hands outside the session, `qm todo add "…"
[--item <slug>]`. Asides and loose chats get no such line.

## Rules

- `--item` and `--project` are never inferred — not from `QM_ITEM`, not from the cwd: a todo
  is tied to what the flags say and nothing else. Both together is an error.
- An unknown `--item` slug is an error (`WorkItem.find`), from the CLI and from `TodoList#add`.
- Fields qm doesn't know, on the file or on a todo, survive every rewrite.
- A missing file is an empty list. An unreadable one (not JSON, or no `todos` array) reads as
  empty and is logged to `qm.log`; it is never rewritten — every change is refused naming the
  file until the user fixes or removes it, so a read can't destroy what is there.
- Writes always go through `TodoList`'s flock; never write `todos.json` another way.

## Data

- `todos.json` — the list, `v: 1`, rewritten atomically.
- `todos.lock` — the flock every change holds.
