# Todos

**Code:** `lib/quartermaster/todo_list.rb`, `lib/quartermaster/cli_todo.rb`, `lib/quartermaster/gui_todo_actions.rb`, `lib/quartermaster/gui/js/todos.js`, `lib/quartermaster/gui/css/todos.css`
**Tests:** `test/todo_list_test.rb`, `test/gui_todos_test.rb`
**Depends on:** [work-items](work-items.md), [linking](linking.md), [cli](cli.md), [gui-shell](gui-shell.md)

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

**GUI** (`GuiTodoActions`, through the normal action router and its Origin checks, not
`LOCAL_ACTIONS`). `todo-add {text, project?, item?}` replies with the new todo;
`todo-edit {id, text?, project?}` (an absent field stays, `project: ""` clears it);
`todo-move {id, before|after}` (a neighbour's id); `todo-done {id, done}` (`done: false`
unticks); `todo-delete {id}`. They are in `GuiActions::UNLOCKED`: TodoList's flock already
serialises them. `todo-to-item {id, title, project?, prompt?}` (`GuiTodoActions#to_item`) is
the → Work item: it makes the item the way the board's new item does (`WorkItem.create`, no
project → `ProjectMap::NO_PROJECT`), starts its chat the way the chat pane's Start does
(`Launcher#chat_plan` fresh, so in the project's main checkout, with a non-blank `prompt` as
claude's argument, then `Tmux#open`), and marks the todo done with `item` = the new slug, its
project dropped, before the chat starts (a failed start leaves the item's Start, not a second
item); it replies `{slug, mode}` like `pane-start`, for the page to switch to that
chat. An unknown todo or a blank title is refused before anything is made. It creates an item,
so it runs under the action mutex, not in `UNLOCKED`; it takes no GuiJobs job (nothing in it
takes seconds). The state's `todos` is `GuiTodoActions.payload`: the open todos in order, then
`done_recent`, each `{id, text, created, done_at, item, project, itemTitle}` where `project` is
the item's when the todo has one (the todo's own otherwise) and `itemTitle` names that item (nil
for a deleted one). `TodoList#signature` (todos.json's size+mtime) is part of the pulse and
`/api/pulse`'s own `todos` field, so a CLI add reaches an open page within a second.

**The Todos tab** (`todos.js`, `todos.css`): a header mode after Issues, key `t`, its badge
the open count (never part of the tab title's count). One centred column: an always-present add
row (text + project picker; the picker defaults to the last project added under while no filter
is on, remembered per browser in `localStorage` `qm-todo-project`, and to the filtered project
while a project filter is), a filter row (All / no project / one chip per project with open
todos), the open todos in order, then a collapsed Done section (the 20 newest; unticking
reopens one). A row: checkbox, text, project tag, an item chip (the item's title; a click opens
its chat), a drag handle and a ⋯ menu (Edit, → Work item, Delete). A todo whose item has gone shows the slug. Keys
in the tab: `j`/`k` select, `⇧J`/`⇧K` move the todo past its neighbour *in the filtered list*
(`todo-move` before/after that neighbour), `x` tick/untick, `e` edit inline (text, and the project
unless the todo is on an item; Enter saves, Esc cancels), `w` → Work item, `⌫` delete (no
confirm), `n` or `/` focus the add input, `c` new item. Neither key clashes: the board takes
`/` only in its own mode. → Work item opens a dialog like the loose chat's: title and first
prompt prefilled with the todo text, the project the todo's (own or its item's), else the
last one used there (`qm-todo-item-project`), else the default; it posts `todo-to-item` and lands
in the new item's chat. The page refetches state when `/api/pulse`'s `todos` moves, in every
mode, so a CLI add shows within a second. An inline edit keeps its draft across a re-render.

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
