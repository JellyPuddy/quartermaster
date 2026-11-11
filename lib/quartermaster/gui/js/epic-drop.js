"use strict";

/* ------- drag a work item into an epic -------
   Sources (data-drag-item): board cards, epic cards and their item rows, the
   Todos outline's item rows, the chats list's rows. Targets (data-epic-drop):
   an epic card, an epic's Todos head, an epic's chats-list header; a board
   column's bare part is "" (out of its epic), but not the dragged card itself:
   a drag let go where it started changes nothing. The nearest target wins, so an
   epic card inside a column is the epic. Every drop goes through moveToEpic
   (epics.js): only the epic changes, a refusal is qm epic's own text. The
   lists are rebuilt under a drag, so the handlers sit on the document and the
   drag carries its own type: a todo's reorder drag or a file never lands here. */
const EPIC_DRAG_TYPE = "application/x-qm-item";
let epicDrag = null;  // the dragged item's slug

function epicDragSource(node, slug) { node.draggable = true; node.dataset.dragItem = slug; }
function epicDropTarget(node, epicSlug) { node.dataset.epicDrop = epicSlug; }

function epicDropAt(ev) {
  if (!epicDrag || !ev.dataTransfer || !ev.dataTransfer.types.includes(EPIC_DRAG_TYPE)) return null;
  const t = ev.target.closest && ev.target.closest("[data-epic-drop]");
  if (!t) return null;
  const it = items.find(i => i.slug === epicDrag);
  const epic = t.dataset.epicDrop;
  if (!it || epic === (it.epic || "")) return null;
  const over = ev.target.closest("[data-drag-item]");
  if (epic === "" && over && over.dataset.dragItem === epicDrag) return null;
  return { t, it, epic };
}
function epicDropMark(target) {
  document.querySelectorAll(".epic-drop-on").forEach(n => { if (n !== target) n.classList.remove("epic-drop-on"); });
  if (target) target.classList.add("epic-drop-on");
}
function epicDragEnd() {
  epicDrag = null;
  epicDropMark(null);
  document.querySelectorAll(".epic-dragging").forEach(n => n.classList.remove("epic-dragging"));
}

document.addEventListener("dragstart", ev => {
  const src = ev.target.closest && ev.target.closest("[data-drag-item]");
  if (!src) return;
  epicDrag = src.dataset.dragItem;
  ev.dataTransfer.effectAllowed = "move";
  ev.dataTransfer.setData(EPIC_DRAG_TYPE, epicDrag);
  src.classList.add("epic-dragging");
});
document.addEventListener("dragover", ev => {
  const d = epicDropAt(ev);
  if (epicDrag) epicDropMark(d && d.t);
  if (!d) return;
  ev.preventDefault();
  ev.dataTransfer.dropEffect = "move";
});
document.addEventListener("drop", ev => {
  const d = epicDropAt(ev);
  if (!d) return;
  ev.preventDefault();
  epicDragEnd();
  moveToEpic(d.it, d.epic);
});
document.addEventListener("dragend", epicDragEnd);
