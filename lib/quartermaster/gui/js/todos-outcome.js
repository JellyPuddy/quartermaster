"use strict";

/* ------- A todo's outcome: one optional line on how or why it ended -------
   ⇧X or the ⋯ menu opens an inline input on the row (its draft in todos.js's
   todoOutcome, so a re-render keeps it). On an open todo Enter ticks it with
   that outcome (empty just ticks); on a done one it replaces the outcome
   (empty clears it). */
function todoOutcomeEditor() {
  const form = el("div", "td-edit td-outcome-edit");
  const input = el("input");
  input.type = "text";
  input.placeholder = "Outcome (optional) — why or how it ended";
  input.value = todoOutcome.text;
  input.oninput = () => { todoOutcome.text = input.value; };
  const save = el("button", "act strong", "Save");
  save.onclick = () => saveTodoOutcome();
  const cancel = el("button", "act", "Cancel");
  cancel.onclick = () => cancelTodoOutcome();
  form.append(input, save, cancel);
  form.addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); saveTodoOutcome(); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancelTodoOutcome(); }
  });
  return form;
}

function outcomeTodo(t) {
  todoFocus = t.id;
  todoEdit = null;
  todoOutcome = { id: t.id, text: t.done_at ? t.outcome || "" : "" };
  renderTodos();
  const input = $("#todo-body .td-row .td-outcome-edit input");
  if (input) { input.focus(); input.select(); }
}

function cancelTodoOutcome() { todoOutcome = null; renderTodos(); focusTodoRow(); }

function saveTodoOutcome() {
  const draft = todoOutcome;
  const t = draft && todoById(draft.id);
  if (!t) return cancelTodoOutcome();
  const outcome = draft.text.trim();
  todoOutcome = null;
  renderTodos();
  if (!t.done_at) return toggleTodo(t, outcome);
  act("todo-edit", { args: { id: t.id, outcome } }).then(() => { renderTodos(); focusTodoRow(); });
}
