"use strict";

/* ------- Todos view: a todo's drag (todos.js draws the ⠿ that starts it) -------
   Over a row of its own group it reorders, a line
   before or after that row; over a head (data-todo-drop: an epic's, an item
   row, "Not in an epic") or a row of another group it moves the todo onto
   that item, and the head lights up. The body is rebuilt under a drag, so
   the drop ends the drag itself (a detached handle gets no dragend) and the
   drag carries its own type: an item's drag or a file is never a todo's. */
const TODO_DRAG_TYPE = "application/x-qm-todo";
const todoDropTarget = (node, slug) => { node.dataset.todoDrop = slug; };
epicDropTarget($("#todo-body"), "");

function todoDropAt(e) {
  if (!e.dataTransfer || !e.dataTransfer.types.includes(TODO_DRAG_TYPE)) return null;
  const t = todoDrag && todoById(todoDrag);
  if (!t || t.done_at) return null;
  const onto = e.target.closest("[data-todo-drop]");
  const row = !onto && e.target.closest(".td-row:not(.done)");
  if (row && row.dataset.group === todoGroup(t)) {
    if (row.dataset.id === t.id) return null;
    return { t, row, where: e.clientY > row.getBoundingClientRect().top + row.offsetHeight / 2 ? "after" : "before" };
  }
  const slug = onto ? onto.dataset.todoDrop : row ? (row.dataset.group === "loose" ? "" : row.dataset.group.slice("item:".length)) : null;
  if (slug === null || slug === (t.item || "")) return null;
  return { t, item: slug, head: onto || [...document.querySelectorAll("#todo-body [data-todo-drop]")].find(n => n.dataset.todoDrop === slug) };
}
function todoDropMark(d) {
  document.querySelectorAll(".td-row.drop-before, .td-row.drop-after").forEach(n => n.classList.remove("drop-before", "drop-after"));
  epicDropMark(d && d.head);
  if (d && d.row) d.row.classList.add("drop-" + d.where);
}
function todoDragEnd() {
  todoDrag = null;
  todoDropMark(null);
  document.querySelectorAll(".td-row.dragging").forEach(n => n.classList.remove("dragging"));
}

$("#todo-body").addEventListener("dragover", e => {
  if (!todoDrag || !e.dataTransfer.types.includes(TODO_DRAG_TYPE)) return;
  const d = todoDropAt(e);
  todoDropMark(d);
  if (!d) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = "move";
});
$("#todo-body").addEventListener("drop", e => {
  const d = todoDropAt(e);
  if (!d) return;
  e.preventDefault();
  todoDragEnd();
  todoFocus = d.t.id;
  if (d.row) moveTodoNextTo(d.t, d.where, d.row.dataset.id);
  else moveTodoTo(d.t, d.item);
});
