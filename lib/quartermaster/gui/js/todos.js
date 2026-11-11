"use strict";

/* ------- Todos view: the user's own to-do list (state.todos, TodoList) -------
   Open todos in priority order, then a collapsed Done section (the newest 20,
   untickable). The add row and the filter row stay put across renders, so a
   poll never eats what is being typed; an inline edit keeps its draft in
   todoEdit (an outcome being typed in todoOutcome) for the same reason.
   Reorders post todo-move against a neighbour in the visible list, which the
   server maps onto the whole list. */
const TODO_NO_PROJECT = "No project";
let todoFilter = null;   // null: all · "": no project · a project's name
let todoFocus = null;    // the focused todo's id
let todoEdit = null;     // { id, text, project } while a row is edited inline
let todoOutcome = null;  // { id, text } while a row's outcome is typed inline
let todoDoneOpen = false;
let todoDrag = null;     // the id being dragged

const todoProject = t => (t.project && t.project !== TODO_NO_PROJECT ? t.project : "");
const todoOpen = () => todos.filter(t => !t.done_at);
const todoMatches = t => todoFilter === null || todoProject(t) === todoFilter;
/* The open rows in drawn order: the epic outline, then the todos in no epic (todos-outline.js). */
const todoVisibleOpen = () => todoOutlineRows();
const todoVisibleDone = () => todos.filter(t => t.done_at && todoMatches(t));
/* What j/k walk: the open rows, then the done ones while their section is open. */
const todoRows = () => todoVisibleOpen().concat(todoDoneOpen ? todoVisibleDone() : []);
const todoById = id => todos.find(t => t.id === id);
/* The picker's projects: the configured ones, plus `extra` (a todo's own project
   qm doesn't know), "" standing for no project. */
const todoProjects = extra => ["", ...new Set(PROJECTS.filter(p => p !== TODO_NO_PROJECT).concat(extra ? [extra] : []))];

function todoProjectSelect(select, value) {
  const want = todoProjects(value);
  if (JSON.stringify([...select.options].map(o => o.value)) !== JSON.stringify(want)) {
    select.innerHTML = want.map(p => `<option value="${esc(p)}">${esc(p || "no project")}</option>`).join("");
  }
  select.value = want.includes(value) ? value : "";
}

let todoLastProject = "";
try { todoLastProject = localStorage.getItem("qm-todo-project") || ""; } catch (e) { /* storage blocked: no project */ }

function renderTodosBadge() {
  const n = todoOpen().length;
  const badge = $("#todos-badge");
  badge.innerHTML = n ? `<span class="col-count">${n}</span>` : "";
  badge.parentElement.title = `Your own to-do list (t)${n ? `\n${plural(n, "open todo")}` : ""}`;
}

function renderTodos() {
  if (mode !== "todos") return;
  $("#todo-count").textContent = todoOpen().length;
  const picker = $("#todo-add-project");
  todoProjectSelect(picker, picker.options.length ? picker.value : todoLastProject);
  renderTodoFilters();
  const body = $("#todo-body");
  const hadEditFocus = !!((todoEdit || todoOutcome) && body.contains(document.activeElement));
  const hadAddFocus = !!document.activeElement && !!document.activeElement.closest("#todo-body .tde-addform");
  keepScroll(body.closest(".td-wrap"), () => {
    body.innerHTML = "";
    const rows = todoRows();
    if (todoEdit && !todoById(todoEdit.id)) todoEdit = null;
    if (todoOutcome && !todoById(todoOutcome.id)) todoOutcome = null;
    if (!rows.some(t => t.id === todoFocus)) todoFocus = rows.length ? rows[0].id : null;
    renderTodoOutline(body);
    const done = todoVisibleDone();
    if (done.length) {
      const head = el("button", "td-done-head", `${todoDoneOpen ? "▾" : "▸"} Done <span class="col-count">${done.length}</span>`);
      head.type = "button";
      head.onclick = () => { todoDoneOpen = !todoDoneOpen; renderTodos(); };
      body.appendChild(head);
      if (todoDoneOpen) done.forEach(t => body.appendChild(todoRow(t)));
    }
  });
  if (hadEditFocus) { const input = $("#todo-body .td-row .td-edit input"); if (input) input.focus({ preventScroll: true }); }
  if (hadAddFocus) focusTodoAddOn();
}

function renderTodoFilters() {
  const bar = $("#todo-filters");
  const projects = [...new Set(todoOpen().map(todoProject).filter(Boolean))].sort((a, b) => a.localeCompare(b));
  if (todoFilter && !projects.includes(todoFilter)) projects.push(todoFilter);
  const chips = [[null, "All"], ["", "no project"], ...projects.map(p => [p, p])];
  bar.innerHTML = "";
  chips.forEach(([value, label]) => {
    const b = el("button", "td-chip", esc(label));
    b.type = "button";
    b.setAttribute("aria-pressed", String(value === todoFilter));
    const n = todoOpen().filter(t => value === null || todoProject(t) === value).length;
    if (value !== null) b.appendChild(el("span", "td-chip-n", String(n)));
    b.onclick = () => setTodoFilter(value);
    bar.appendChild(b);
  });
}

function setTodoFilter(value) {
  todoFilter = value;
  // Adding while a project's todos are shown files the new one under it.
  todoProjectSelect($("#todo-add-project"), value === null ? todoLastProject : value);
  renderTodos();
}

/* nested: a row inside an epic's outline, which already says its item and project. */
function todoRow(t, nested = false, depth = "") {
  const row = el("div", "td-row" + (t.done_at ? " done" : "") + (todoOutcome && todoOutcome.id === t.id ? " outcome-edit" : "") + (t.id === todoFocus ? " focused" : "") + (nested ? " nested " + depth : ""));
  row.dataset.id = t.id;
  row.dataset.group = todoGroup(t);
  row.tabIndex = t.id === todoFocus ? 0 : -1;
  const box = el("input", "td-check");
  box.type = "checkbox";
  box.checked = !!t.done_at;
  box.tabIndex = -1;
  box.title = t.done_at ? "Not done after all (x)" : "Done (x)";
  box.onchange = () => toggleTodo(t);
  row.appendChild(box);
  if (todoEdit && todoEdit.id === t.id) { row.appendChild(todoEditor(t)); return row; }
  const text = el("span", "td-text", esc(t.text));
  text.ondblclick = () => editTodo(t);
  row.appendChild(text);
  if (todoOutcome && todoOutcome.id === t.id) row.appendChild(todoOutcomeEditor());
  else if (t.done_at && t.outcome) row.appendChild(el("span", "td-outcome", "→ " + esc(t.outcome)));
  if (todoProject(t) && !nested) row.appendChild(el("span", "td-proj", esc(todoProject(t))));
  if (t.item && !nested) {
    const chip = el("button", "td-item", esc(t.itemTitle || t.item));
    chip.type = "button";
    chip.tabIndex = -1;
    chip.title = t.itemTitle ? `${t.item}: open its chat` : `${t.item} is not a work item any more`;
    chip.onclick = () => openTodoItem(t);
    row.appendChild(chip);
  }
  if (!t.done_at) {
    const handle = el("span", "td-handle", "⠿");
    handle.draggable = true;
    handle.title = "Drag to reorder (⇧J / ⇧K), or onto an epic or item to move it there";
    handle.ondragstart = e => { todoDrag = t.id; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData(TODO_DRAG_TYPE, t.id); e.dataTransfer.setData("text/plain", t.id); row.classList.add("dragging"); };
    handle.ondragend = todoDragEnd;
    row.appendChild(handle);
  }
  const more = el("button", "td-more", "⋯");
  more.type = "button";
  more.tabIndex = -1;
  more.title = "More";
  more.onclick = e => { e.stopPropagation(); todoMenu(more, t); };
  row.appendChild(more);
  return row;
}

function todoEditor(t) {
  const form = el("div", "td-edit");
  const input = el("input");
  input.type = "text";
  input.value = todoEdit.text;
  input.oninput = () => { todoEdit.text = input.value; };
  form.appendChild(input);
  let select = null;
  if (t.item) form.appendChild(el("span", "td-proj", esc(todoProject(t) || "no project")));
  else {
    select = el("select");
    todoProjectSelect(select, todoEdit.project);
    select.onchange = () => { todoEdit.project = select.value; };
    form.appendChild(select);
  }
  const save = el("button", "act strong", "Save");
  save.onclick = () => saveTodoEdit();
  const cancel = el("button", "act", "Cancel");
  cancel.onclick = () => cancelTodoEdit();
  form.append(save, cancel);
  form.addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); saveTodoEdit(); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancelTodoEdit(); }
  });
  return form;
}

function editTodo(t) {
  todoFocus = t.id;
  todoOutcome = null;
  todoEdit = { id: t.id, text: t.text, project: todoProject(t) };
  renderTodos();
  const input = $("#todo-body .td-row .td-edit input");
  if (input) { input.focus(); input.select(); }
}

function cancelTodoEdit() { todoEdit = null; renderTodos(); focusTodoRow(); }

function saveTodoEdit() {
  const draft = todoEdit;
  const t = draft && todoById(draft.id);
  if (!t) return cancelTodoEdit();
  const text = draft.text.trim();
  if (!text) { toast("a todo needs text", false); return; }
  const args = { id: t.id, text };
  if (!t.item) args.project = draft.project;
  todoEdit = null;
  act("todo-edit", { args }).then(() => { renderTodos(); focusTodoRow(); });
}

function toggleTodo(t, outcome = "") {
  if (!t.done_at && t.id === todoFocus) {
    const open = todoVisibleOpen();
    const at = open.findIndex(r => r.id === t.id);
    const next = open[at + 1] || open[at - 1];
    if (next) todoFocus = next.id;
  }
  const args = { id: t.id, done: !t.done_at };
  if (outcome) args.outcome = outcome;
  act("todo-done", { args }).then(() => focusTodoRow());
}

function deleteTodo(t) {
  const rows = todoRows();
  const at = rows.findIndex(r => r.id === t.id);
  const next = rows[at + 1] || rows[at - 1];
  todoFocus = next ? next.id : null;
  act("todo-delete", { args: { id: t.id } }).then(r => { if (r.ok) { toast("todo deleted"); focusTodoRow(); } });
}

/* ⇧J / ⇧K: past the next or previous visible todo of its own group. */
function shiftTodo(t, d) {
  const open = todoVisibleOpen().filter(r => todoGroup(r) === todoGroup(t));
  const at = open.findIndex(r => r.id === t.id);
  const neighbour = at < 0 ? null : open[at + d];
  if (!neighbour) return;
  moveTodoNextTo(t, d > 0 ? "after" : "before", neighbour.id).then(() => focusTodoRow());
}

/* A reorder, in the page's list at once (optimisticAct). */
function moveTodoNextTo(t, where, neighbourId) {
  const change = () => {
    const was = todos;
    const now = todos.filter(x => x.id !== t.id);
    const at = now.findIndex(x => x.id === neighbourId);
    now.splice(where === "after" ? at + 1 : at, 0, t);
    todos = now;
    return () => { if (todos === now) todos = was; };
  };
  return optimisticAct(change, "todo-move", { args: { id: t.id, [where]: neighbourId } });
}

async function openTodoItem(t) {
  if (!items.some(i => i.slug === t.item)) await refresh();
  const it = items.find(i => i.slug === t.item);
  if (it) openChat(it); else toast(`${t.item} is not a work item any more`, false);
}

function todoMenu(anchor, t) {
  todoFocus = t.id;
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Todo"));
    const add = (label, fn) => { const b = el("button", "", esc(label)); b.onclick = () => { closePop(); fn(); }; p.appendChild(b); };
    add("Edit", () => editTodo(t));
    add(t.done_at ? "Outcome…" : "Done with outcome…", () => outcomeTodo(t));
    if (!t.done_at) add("→ Work item…", () => todoToItemModal(t));
    add("Move to epic / item…", () => todoMovePicker(anchor, t));
    p.appendChild(el("div", "sep"));
    add("Delete", () => deleteTodo(t));
  });
}

let todoItemProject = "";
try { todoItemProject = localStorage.getItem("qm-todo-item-project") || ""; } catch (e) { /* storage blocked: the default project */ }

/* → Work item: a new item and its chat, started with the todo as its first
   prompt; the todo is ticked and tied to the item. Like the loose chat's
   → Work item, the page then lands in that chat. */
function todoToItemModal(t) {
  modal(m => {
    m.innerHTML = `<h2>Todo → work item</h2><p class="sub">creates the item · starts its chat in the project's main checkout · ticks the todo</p>`;
    const tf = el("div", "field", `<label>Title</label><input type="text" placeholder="Short, intent-named title">`);
    const input = tf.querySelector("input");
    input.value = t.text;
    const pf = el("div", "field", `<label>Project</label><select>${PROJECTS.map(p => `<option>${esc(p)}</option>`).join("")}</select>`);
    const select = pf.querySelector("select");
    const want = [todoProject(t), todoItemProject, DEFAULT_PROJECT].find(p => p && PROJECTS.includes(p));
    select.value = want || TODO_NO_PROJECT;
    const qf = el("div", "field", `<label>First prompt <span style="text-transform:none;color:var(--faint)">(optional)</span></label><textarea></textarea>`);
    const ta = qf.querySelector("textarea");
    ta.value = t.text;
    m.append(tf, pf, qf);
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const create = el("button", "btn primary", "Create item &amp; start chat");
    create.onclick = () => {
      const title = input.value.trim();
      if (!title) { input.focus(); return; }
      const project = select.value;
      todoItemProject = project;
      try { localStorage.setItem("qm-todo-item-project", project); } catch (e) { /* storage blocked: this page only */ }
      create.disabled = true;
      act("todo-to-item", { args: { id: t.id, title, project, prompt: ta.value.trim() } }).then(r => {
        create.disabled = false;
        if (!r.ok) return;
        closeModal();
        toast(`created ${r.slug} and started its chat`);
        if (!panes.includes(r.slug)) panes = panes.concat(r.slug);
        const it = items.find(i => i.slug === r.slug);
        if (it) openChat(it);
      });
    };
    input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.isComposing) create.click(); });
    ta.addEventListener("keydown", e => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") create.click(); });
    bar.append(cancel, create); m.appendChild(bar);
    input.focus(); input.select();
  });
}

function focusTodoRow() {
  const row = $("#todo-body .td-row.focused");
  if (row) { row.focus({ preventScroll: true }); row.scrollIntoView({ block: "nearest" }); }
}

function moveTodoFocus(d) {
  const rows = todoRows();
  if (!rows.length) return;
  const at = Math.max(0, rows.findIndex(t => t.id === todoFocus));
  todoFocus = rows[Math.max(0, Math.min(rows.length - 1, at + d))].id;
  renderTodos();
  focusTodoRow();
}

function addTodo() {
  const input = $("#todo-add-input");
  const text = input.value.trim();
  if (!text) return;
  const project = $("#todo-add-project").value;
  if (todoFilter === null) {
    todoLastProject = project;
    try { localStorage.setItem("qm-todo-project", project); } catch (e) { /* storage blocked: this page only */ }
  }
  act("todo-add", { args: { text, project } }).then(r => { if (r.ok) { input.value = ""; if (r.todo) todoFocus = r.todo.id; renderTodos(); } });
}

$("#todo-add-input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); addTodo(); }
  else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); e.target.blur(); focusTodoRow(); }
});
$("#todo-add-project").addEventListener("change", e => {
  if (todoFilter !== null) return;
  todoLastProject = e.target.value;
  try { localStorage.setItem("qm-todo-project", todoLastProject); } catch (err) { /* storage blocked: this page only */ }
});
$("#todo-add-btn").addEventListener("click", addTodo);

$("#todo-body").addEventListener("click", e => {
  const row = e.target.closest(".td-row");
  if (!row || e.target.closest("input, select, button")) return;
  if (todoFocus !== row.dataset.id) { todoFocus = row.dataset.id; renderTodos(); focusTodoRow(); }
});

function todoKey(e) {
  const t = todoById(todoFocus);
  switch (e.key) {
    case "j": case "ArrowDown": e.preventDefault(); moveTodoFocus(1); break;
    case "k": case "ArrowUp":   e.preventDefault(); moveTodoFocus(-1); break;
    case "J": if (t && !t.done_at) { e.preventDefault(); shiftTodo(t, 1); } break;
    case "K": if (t && !t.done_at) { e.preventDefault(); shiftTodo(t, -1); } break;
    case "x": if (t) { e.preventDefault(); toggleTodo(t); } break;
    case "X": if (t) { e.preventDefault(); outcomeTodo(t); } break;
    case "e": if (t) { e.preventDefault(); editTodo(t); } break;
    case "w": if (t && !t.done_at) { e.preventDefault(); todoToItemModal(t); } break;
    case "Backspace": case "Delete": if (t) { e.preventDefault(); deleteTodo(t); } break;
    case "n": case "/": e.preventDefault(); $("#todo-add-input").focus(); break;
    case "c": e.preventDefault(); newItemModal(); break;
  }
}
