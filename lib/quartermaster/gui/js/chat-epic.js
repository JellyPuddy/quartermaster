"use strict";

/* ------- epics in the chat view -------
   An epic is a work item of kind epic; a child names it in `epic:`. The chats
   list groups its rows by epic, the side panel opens with the epic's block and
   the chat head carries a crumb to it. Everything is derived here from `items`
   and `todos`; a dangling `epic:` reads as no epic. Function declarations
   only: this page's scripts share one global scope. */

function chatEpicOf(it) {
  if (!it) return null;
  if (it.kind === "epic") return it;
  return (it.epic && items.find(i => i.slug === it.epic && i.kind === "epic")) || null;
}
function chatEpicChildren(epic) { return items.filter(i => i.epic === epic.slug && i.kind !== "epic"); }
function chatOpenTodosOn(slug) { return todos.filter(t => t.item === slug && !t.done_at); }
function chatEpicOpenTodos(epic) {
  const slugs = new Set([epic.slug, ...chatEpicChildren(epic).map(c => c.slug)]);
  return todos.filter(t => !t.done_at && slugs.has(t.item));
}
/* Suggest-only: every child resolved and nothing open on the epic or its children. */
function chatEpicResolvable(epic) {
  const children = chatEpicChildren(epic);
  return epic.state !== "resolved" && children.length > 0 &&
    children.every(c => c.state === "resolved") && chatEpicOpenTodos(epic).length === 0;
}

/* ------- the list, grouped -------
   rows arrive in attention order, so a block's first row is its most urgent and
   blocks come out ordered by it. The epic's own entry joins its block only when
   it has a turn; otherwise the header stands for it. */
function chatListGroups(rows) {
  const blocks = new Map();
  const plain = [];
  rows.forEach(a => {
    const epic = chatEpicOf(items.find(i => i.slug === a.slug));
    if (!epic) { plain.push(a); return; }
    if (!blocks.has(epic.slug)) blocks.set(epic.slug, { epic, rows: [] });
    if (a.slug !== epic.slug || a.state !== "none") blocks.get(epic.slug).rows.push(a);
  });
  return { blocks: [...blocks.values()], plain };
}

let chatEpicFolds = new Set();
try { chatEpicFolds = new Set(JSON.parse(localStorage.getItem("qm-chat-epic-folds") || "[]")); } catch (e) { /* storage blocked: all open */ }
function toggleChatEpicFold(slug) {
  if (chatEpicFolds.has(slug)) chatEpicFolds.delete(slug); else chatEpicFolds.add(slug);
  try { localStorage.setItem("qm-chat-epic-folds", JSON.stringify([...chatEpicFolds])); } catch (e) { /* storage blocked: this page only */ }
  renderChat();
}

/* The slugs j/k walk, in the order the list shows them: an epic's header, then
   its rows unless folded (a folded block keeps the selected chat, so j/k go on
   from its dot), then the rows in no epic. */
function chatListSlugs() {
  const { blocks, plain } = chatListGroups(chatRows());
  const shown = b => chatEpicFolds.has(b.epic.slug) ? b.rows.filter(a => a.slug === chatSlug) : b.rows;
  return [...blocks.flatMap(b => [b.epic.slug, ...shown(b).map(a => a.slug)]), ...plain.map(a => a.slug)];
}

function renderChatList(list, rows) {
  const { blocks, plain } = chatListGroups(rows);
  blocks.forEach(b => list.appendChild(chatEpicBlock(b)));
  let labelled = false;
  plain.forEach(a => {
    if (a.extra) list.appendChild(el("div", "att-group", "opened from the board"));
    else if (blocks.length && !labelled) { list.appendChild(el("div", "att-group", "no epic")); labelled = true; }
    list.appendChild(chatRow(a));
  });
}

function chatEpicBlock({ epic, rows }) {
  const folded = chatEpicFolds.has(epic.slug);
  const box = el("div", "chat-epic" + (chatSlug === epic.slug ? " selected" : ""));
  box.dataset.slug = epic.slug;
  const head = el("div", "chat-epic-head");
  head.title = `${epic.title}\nClick: open the epic · ▸ fold`;
  const chev = el("button", "chat-epic-chev", folded ? "▸" : "▾");
  chev.title = folded ? "Show this epic's chats" : "Fold to status dots";
  chev.tabIndex = -1;
  chev.onclick = e => { e.stopPropagation(); toggleChatEpicFold(epic.slug); };
  const live = chatEpicChildren(epic).filter(c => attention.some(a => a.slug === c.slug && a.state !== "none")).length;
  const open = chatEpicOpenTodos(epic).length;
  head.append(chev, el("span", "epic-kind", "EPIC"), el("span", "chat-epic-glyph", "◆"),
    el("span", "chat-epic-title", esc(epic.title)),
    el("span", "chat-epic-roll", `${live} live · ${open} todo${open === 1 ? "" : "s"}`));
  head.onclick = () => selectChat(epic.slug);
  box.appendChild(head);
  if (!folded) { rows.forEach(a => box.appendChild(chatRow(a))); return box; }
  const dots = el("div", "chat-epic-dots");
  rows.forEach(a => {
    const it = items.find(i => i.slug === a.slug) || {};
    const d = attDot(a);
    if (a.slug === chatSlug) d.classList.add("on");
    d.title = `${it.title || a.slug}\n${attLabel(a)}`;
    d.onclick = () => selectChat(a.slug, { focusTerm: true });
    dots.appendChild(d);
  });
  box.appendChild(dots);
  return box;
}

/* ------- the chat head's crumb ------- */
function chatEpicCrumb(it) {
  const epic = it.kind === "epic" ? null : chatEpicOf(it);
  if (!epic) return null;
  const c = el("button", "chat-epic-crumb", `◆ ${esc(epic.title)} ›`);
  c.title = "Open the epic";
  c.tabIndex = -1;
  c.onclick = () => selectChat(epic.slug);
  return c;
}

/* ------- the side panel's Epic block ------- */
function epicLinkChips(it) {
  return (it.links || []).map(l => {
    const a = el("a", "epic-link", esc((l.label || "?").trim().charAt(0).toUpperCase() || "?"));
    a.href = l.url; a.target = "_blank"; a.rel = "noopener"; a.title = l.label;
    a.onclick = e => e.stopPropagation();
    return a;
  });
}
function resolveEpic(epic) {
  act("state", { slug: epic.slug, args: { state: "resolved" } }).then(r => {
    if (!r.ok) return;
    toast(`${epic.slug} → resolved`);
    if (r.cleanup) cleanupModal(epic.slug, r.cleanup, resolveHeading(r.cleanup));
  });
}
function epicResolveSuggestion(epic) {
  if (!chatEpicResolvable(epic)) return null;
  const b = el("button", "epic-suggest", "✓ all done — resolve epic?");
  b.title = "Every item is resolved and no todo is open: resolve the epic";
  b.onclick = e => { e.stopPropagation(); resolveEpic(epic); };
  return b;
}

function chatEpicSection(it) {
  const epic = chatEpicOf(it);
  if (!epic) return null;
  const isEpic = epic.slug === it.slug;
  const sec = el("div", "sheet-sec chat-epic-side");
  sec.appendChild(el("h3", "", isEpic ? "This epic" : "Epic"));
  const head = el("div", "chat-epic-side-head");
  head.append(el("span", `status-dot dot-${epic.state}`), el("b", "", esc(epic.title)), ...epicLinkChips(epic));
  const suggest = epicResolveSuggestion(epic);
  if (suggest) head.appendChild(suggest);
  if (!isEpic) { head.classList.add("link"); head.title = "Open the epic"; head.onclick = () => selectChat(epic.slug); }
  sec.appendChild(head);
  const desc = (epic.description || "").trim();
  if (!isEpic && desc) sec.appendChild(el("div", "desc-text", esc(desc)));

  const children = chatEpicChildren(epic);
  const open = children.filter(c => c.state !== "resolved");
  const label = el("div", "chat-epic-label", "Items ");
  label.appendChild(el("span", "n", `${open.length} open of ${children.length}`));
  sec.appendChild(label);
  open.forEach(c => {
    const a = attention.find(x => x.slug === c.slug) || { state: "none" };
    const r = el("div", "chat-epic-child" + (c.slug === chatSlug ? " on" : ""));
    r.append(attDot(a), el("span", "chat-epic-child-title", esc(c.title)),
      el("span", "chat-epic-child-state", a.state === "none" ? "" : esc(attLabel(a))));
    r.title = c.slug;
    r.onclick = () => selectChat(c.slug);
    sec.appendChild(r);
  });

  if (!isEpic) chatEpicTodoList(sec, "Todos on this item", chatOpenTodosOn(it.slug), true);
  chatEpicTodoList(sec, "Todos on the epic", chatOpenTodosOn(epic.slug), false);
  sec.appendChild(chatEpicTodoAdd(epic));
  return sec;
}
function chatEpicTodoList(sec, label, list, onlyWhenAny) {
  if (onlyWhenAny && !list.length) return;
  sec.appendChild(el("div", "chat-epic-label", esc(label)));
  list.forEach(t => {
    const line = el("label", "chat-epic-todo");
    const box = el("input");
    box.type = "checkbox";
    box.onchange = () => { box.blur(); act("todo-done", { args: { id: t.id, done: true } }); };
    line.append(box, el("span", "", esc(t.text)));
    sec.appendChild(line);
  });
}
/* "+ todo" opens an inline input; Enter adds the todo on the epic. The panel
   holds still while it has focus (renderChatSide skips a focused input). */
function chatEpicTodoAdd(epic) {
  const wrap = el("div", "chat-epic-add");
  const open = el("button", "chat-epic-addline", "+ todo");
  open.title = `Add a todo on ${epic.title}`;
  open.onclick = () => {
    const input = el("input");
    input.type = "text";
    input.placeholder = `Todo on ${epic.title} — ⏎ adds, Esc cancels`;
    input.onkeydown = e => {
      if (e.key === "Escape") { e.preventDefault(); input.blur(); renderChatSide(); return; }
      if (e.key !== "Enter" || !input.value.trim()) return;
      e.preventDefault();
      act("todo-add", { args: { text: input.value.trim(), item: epic.slug } }).then(r => {
        if (r.ok) { input.blur(); renderChatSide(); }
      });
    };
    input.onblur = () => { if (!input.value.trim()) setTimeout(renderChatSide); };
    wrap.replaceChildren(input);
    input.focus();
  };
  wrap.appendChild(open);
  return wrap;
}
