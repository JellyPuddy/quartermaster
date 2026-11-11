"use strict";

/* ------- Todos view: the epic outline and Move to (todos.js draws the rest) -------
   Each epic: its own open todos, its open child items with their todos, a
   "+ todo on <epic>" line, then "n resolved items". The todos in no epic
   follow, as the flat list. j/k walk todoOutlineRows(), the rows in drawn
   order; ⇧J/⇧K and drag move a todo only among its own group (one item's
   todos, or the todos in no epic), against a neighbour in todos.json. */
let todoCollapsed = new Set();
try { todoCollapsed = new Set(JSON.parse(localStorage.getItem("qm-todo-epics-collapsed") || "[]")); } catch (e) { /* storage blocked: all open */ }
let todoAddOn = null;  // { slug, text } while a "+ todo on <epic>" line is typed in

const todoItem = slug => items.find(i => i.slug === slug);
/* The epic a todo hangs in: its item, or its item's epic; a dangling epic is none. */
function todoEpicOf(t) {
  const it = t.item && todoItem(t.item);
  const e = isEpic(it) ? it : epicOf(it);
  return e ? e.slug : null;
}
const todoGroup = t => (todoEpicOf(t) ? "item:" + t.item : "loose");

/* The outline as data, so drawing and the keyboard agree. A resolved epic stays
   while a todo hangs in it; the project filter picks epics by their project. */
function todoOutline() {
  const open = todoOpen();
  const on = slug => open.filter(t => t.item === slug);
  const epics = items.filter(isEpic).map(e => {
    const children = epicChildren(e);
    const shown = children.filter(c => c.state !== "resolved" || on(c.slug).length);
    const all = on(e.slug).concat(...children.map(c => on(c.slug)));
    return { epic: e, own: on(e.slug), children: shown.map(c => ({ item: c, todos: on(c.slug) })),
             count: children.length, openCount: children.filter(c => c.state !== "resolved").length,
             resolved: children.length - shown.length, todoCount: all.length };
  }).filter(n => (n.epic.state !== "resolved" || n.todoCount) &&
                 (todoMatches({ project: n.epic.project }) || n.own.concat(...n.children.map(c => c.todos)).some(todoMatches)));
  return { epics, loose: open.filter(t => !todoEpicOf(t) && todoMatches(t)) };
}

function todoOutlineRows() {
  const { epics, loose } = todoOutline();
  const rows = [];
  epics.filter(n => !todoCollapsed.has(n.epic.slug)).forEach(n => {
    rows.push(...n.own);
    n.children.forEach(c => rows.push(...c.todos));
  });
  return rows.concat(loose);
}

function renderTodoOutline(body) {
  const { epics, loose } = todoOutline();
  epics.forEach(n => body.appendChild(todoEpicNode(n)));
  if (epics.length) body.appendChild(el("div", "tde-loose-head", `Not in an epic <span class="col-count">${loose.length}</span>`));
  if (!loose.length && !epics.length) body.appendChild(el("div", "col-empty", todos.length ? "nothing open here" : "no todos yet — type one above"));
  loose.forEach(t => body.appendChild(todoRow(t)));
}

function todoEpicNode(n) {
  const e = n.epic;
  const collapsed = todoCollapsed.has(e.slug);
  const node = el("div", "tde-node" + (collapsed ? " collapsed" : ""));
  const head = el("div", "tde-head", `<span class="tde-chev">${collapsed ? "▸" : "▾"}</span><span class="epic-kind">EPIC</span>` +
    `<span class="status-dot dot-${esc(e.state)}"></span><span class="tde-title">${esc(e.title)}</span>` +
    `<span class="tde-roll">${plural(n.count, "item")}${n.count ? ` · ${n.openCount} open` : ""} · ${plural(n.todoCount, "todo")}</span>`);
  head.title = collapsed ? "Show this epic's todos" : "Fold this epic";
  head.appendChild(linkChips(e));
  const suggest = resolveSuggestion(e);
  if (suggest) head.appendChild(suggest);
  head.onclick = ev => { if (!ev.target.closest("a, button")) toggleTodoEpic(e.slug); };
  node.appendChild(head);
  if (collapsed) return node;
  n.own.forEach(t => node.appendChild(todoRow(t, true)));
  node.appendChild(todoAddOnLine(e));
  n.children.forEach(c => {
    node.appendChild(todoChildRow(c.item, c.todos.length));
    c.todos.forEach(t => node.appendChild(todoRow(t, true, "child")));
  });
  if (n.resolved) node.appendChild(el("div", "tde-sub", plural(n.resolved, "resolved item")));
  return node;
}

function toggleTodoEpic(slug) {
  if (todoCollapsed.has(slug)) todoCollapsed.delete(slug); else todoCollapsed.add(slug);
  try { localStorage.setItem("qm-todo-epics-collapsed", JSON.stringify([...todoCollapsed])); } catch (e) { /* storage blocked: this page only */ }
  renderTodos();
}

function todoChildRow(it, openTodos) {
  const r = el("div", "tde-child", `<span class="status-dot dot-${esc(it.state)}"></span><span class="tde-child-title">${esc(it.title)}</span>` +
    `${it.live ? '<span class="live-dot">live</span>' : ""}<span class="sess">${it.sessions || 0} sess</span>` +
    (openTodos ? `<span class="tde-roll">☐ ${openTodos}</span>` : ""));
  r.title = `${it.slug}: open its chat`;
  r.onclick = () => openChat(it);
  return r;
}

/* "+ todo on <epic>": a line that turns into an input; Enter adds on the epic. */
function todoAddOnLine(e) {
  if (!todoAddOn || todoAddOn.slug !== e.slug) {
    const line = el("button", "tde-addline", `+ todo on ${esc(e.title)}`);
    line.type = "button";
    line.tabIndex = -1;
    line.onclick = () => { todoAddOn = { slug: e.slug, text: "" }; renderTodos(); focusTodoAddOn(); };
    return line;
  }
  const form = el("div", "td-edit tde-addform");
  const input = el("input");
  input.type = "text";
  input.placeholder = `todo on ${e.title}…`;
  input.value = todoAddOn.text;
  input.oninput = () => { todoAddOn.text = input.value; };
  input.addEventListener("keydown", ev => {
    if (ev.key === "Enter" && !ev.isComposing) {
      ev.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      act("todo-add", { args: { text, item: e.slug } }).then(r => {
        if (!r.ok) return;
        todoAddOn = { slug: e.slug, text: "" };
        if (r.todo) todoFocus = r.todo.id;
        renderTodos(); focusTodoAddOn();
      });
    } else if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); todoAddOn = null; renderTodos(); focusTodoRow(); }
  });
  form.appendChild(input);
  return form;
}

function focusTodoAddOn() { const input = $("#todo-body .tde-addform input"); if (input) input.focus({ preventScroll: true }); }

/* ⋯ → Move to epic / item…: epics with their open children, the other open
   items, and nothing (the todo keeps the project it showed). */
function todoMovePicker(anchor, t) {
  const opts = [];
  items.filter(i => isEpic(i) && (i.state !== "resolved" || i.slug === t.item)).forEach(e => {
    opts.push({ slug: e.slug, label: `◆ ${e.title}`, cls: "epic" });
    epicChildren(e).filter(c => c.state !== "resolved" || c.slug === t.item)
      .forEach(c => opts.push({ slug: c.slug, label: c.title, cls: "child" }));
  });
  const inEpic = new Set(opts.map(o => o.slug));
  items.filter(i => i.kind !== "automation" && !inEpic.has(i.slug) && (i.state !== "resolved" || i.slug === t.item))
    .forEach(i => opts.push({ slug: i.slug, label: i.title, cls: "item" }));
  opts.push({ slug: "", label: "— nothing (just its project)", cls: "none" });
  const pick = o => {
    closePop();
    if (o.slug === (t.item || "")) return;
    act("todo-edit", { args: { id: t.id, item: o.slug } }).then(r => { if (r.ok) toast(o.slug ? `todo moved to ${o.label.replace(/^◆ /, "")}` : "todo is on no item now"); });
  };
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Move todo to"));
    const input = el("input", "tde-pick-input");
    input.type = "text";
    input.placeholder = "filter epics and items…";
    const list = el("div", "tde-pick");
    const shown = () => { const q = input.value.trim().toLowerCase(); return opts.filter(o => !q || o.label.toLowerCase().includes(q)); };
    const draw = () => {
      list.innerHTML = "";
      shown().forEach(o => {
        const b = el("button", `tde-pick-${o.cls}` + (o.slug === (t.item || "") ? " on" : ""), esc(o.label));
        b.type = "button";
        b.onclick = () => pick(o);
        list.appendChild(b);
      });
    };
    input.oninput = draw;
    input.addEventListener("keydown", ev => {
      if (ev.key === "Enter" && !ev.isComposing) { ev.preventDefault(); const first = shown()[0]; if (first) pick(first); }
    });
    p.append(input, list);
    draw();
  });
  const input = openPop && openPop.querySelector(".tde-pick-input");
  if (input) input.focus({ preventScroll: true });
}
