"use strict";

/* ------- epics in the chat view -------
   An epic is a work item of kind epic; a child names it in `epic:`. The chats
   list groups its rows by epic, the side panel opens with the epic's block and
   the chat head carries a crumb to it. The epic helpers (isEpic, epicOf,
   epicChildren, linkChips, resolveSuggestion, …) live in epics.js. Function
   declarations only: this page's scripts share one global scope. */

/* ------- the list, grouped -------
   rows arrive in attention order, so a block's first row is its most urgent and
   blocks come out ordered by it. The epic's own entry joins its block only when
   it has a turn; otherwise the header stands for it. */
function chatListGroups(rows) {
  const blocks = new Map();
  const plain = [];
  rows.forEach(a => {
    const it = items.find(i => i.slug === a.slug);
    const epic = isEpic(it) ? it : epicOf(it);
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
  head.title = `${epic.title}\nClick: open the epic · ▸ fold · drop a chat here to put it in the epic`;
  epicDropTarget(head, epic.slug);
  const chev = el("button", "chat-epic-chev", folded ? "▸" : "▾");
  chev.title = folded ? "Show this epic's chats" : "Fold to status dots";
  chev.tabIndex = -1;
  chev.onclick = e => { e.stopPropagation(); toggleChatEpicFold(epic.slug); };
  const live = epicChildren(epic).filter(c => attention.some(a => a.slug === c.slug && a.state !== "none")).length;
  const open = epicOpenTodos(epic).length;
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
  const epic = isEpic(it) ? null : epicOf(it);
  if (!epic) return null;
  const c = el("button", "chat-epic-crumb", `◆ ${esc(epic.title)} ›`);
  c.title = "Open the epic";
  c.tabIndex = -1;
  c.onclick = () => selectChat(epic.slug);
  return c;
}

/* ------- the side panel's Epic block ------- */
function chatEpicSection(it) {
  const epic = isEpic(it) ? it : epicOf(it);
  if (!epic) return null;
  const self = epic.slug === it.slug;
  const sec = el("div", "sheet-sec chat-epic-side");
  sec.appendChild(el("h3", "", self ? "This epic" : "Epic"));
  const head = el("div", "chat-epic-side-head");
  head.append(el("span", `status-dot dot-${epic.state}`), el("b", "", esc(epic.title)), linkChips(epic));
  const suggest = resolveSuggestion(epic);
  if (suggest) head.appendChild(suggest);
  if (!self) { head.classList.add("link"); head.title = "Open the epic"; head.onclick = () => selectChat(epic.slug); }
  sec.appendChild(head);
  const desc = (epic.description || "").trim();
  if (!self && desc) sec.appendChild(el("div", "desc-text", esc(desc)));

  const children = epicChildren(epic);
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
  chatEpicSubIssues(sec, epic);

  if (!self) chatEpicTodoList(sec, "Todos on this item", openTodosOn(it.slug), true);
  chatEpicTodoList(sec, "Todos on the epic", openTodosOn(epic.slug), false);
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

/* ------- the epic's GitHub sub-issues -------
   Read on demand (epic-sub-issues: gh, read-only) the first time the Epic
   block shows an epic whose description links a GitHub issue, and again on
   its ↻; never from the state or a poll. Cached per epic, since the panel
   re-renders on every poll. Listed: the sub-issues no item holds yet (an item
   holding one is drawn as a child above), each with a Start that runs the
   issue start inside the epic; a closed one dimmed, still startable like any
   closed issue. One in another repo than the project's has no Start. */
const epicSubIssues = new Map(); // epic slug → { loading } | { list, started } | { error }

async function loadEpicSubIssues(slug) {
  epicSubIssues.set(slug, { loading: true });
  let res;
  try {
    const r = await fetch("/api/action", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cmd: "epic-sub-issues", slug: null, args: { epic: slug } }),
    });
    res = await r.json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  epicSubIssues.set(slug, res.ok ? { list: res.sub_issues, started: new Set() } : { error: res.error || "sub-issue lookup failed" });
  renderChatSide();
}

/* Called once an issue start inside the epic is under way: its row shows
   "starting…" until the new item (its URL in the description) hides it. */
function epicSubIssueStarted(slug, number) {
  const got = epicSubIssues.get(slug);
  if (got && got.started) got.started.add(number);
}

function chatEpicSubIssues(sec, epic) {
  if (!GITHUB_ISSUE_URL.test(epic.description || "")) return;
  if (!epicSubIssues.has(epic.slug)) loadEpicSubIssues(epic.slug);
  const got = epicSubIssues.get(epic.slug);
  const held = s => s.item || items.some(i => (i.description || "").split(/\s+/).includes(s.url));
  const loose = got.list ? got.list.filter(s => !held(s)) : [];
  const label = el("div", "chat-epic-label", "Sub-issues without an item ");
  if (got.list) label.appendChild(el("span", "n", `${loose.length} of ${got.list.length}`));
  const again = el("button", "chat-epic-subs-again", "↻");
  again.title = "Read the sub-issues from GitHub again";
  again.disabled = !!got.loading;
  again.onclick = () => loadEpicSubIssues(epic.slug);
  label.appendChild(again);
  sec.appendChild(label);
  if (got.loading || got.error) { sec.appendChild(el("div", "chat-epic-subs-note", got.loading ? "reading GitHub…" : esc(got.error))); return; }
  loose.forEach(s => {
    const r = el("div", "chat-epic-sub" + (s.closed ? " closed" : ""));
    const link = el("a", "chat-epic-sub-title", `#${esc(s.number)} ${esc(s.title)}`);
    link.href = s.url; link.target = "_blank"; link.rel = "noopener";
    link.title = s.closed ? "Closed on GitHub" : "Open the issue on GitHub";
    r.appendChild(link);
    if (got.started.has(s.number)) r.appendChild(el("span", "chat-epic-child-state", "starting…"));
    else if (s.startable) {
      const go = el("button", "chat-epic-sub-start", "Start");
      go.title = `Start #${s.number} as an item inside ${epic.title}`;
      go.onclick = () => issueStartModal(s.number, epic.project, { epic: epic.slug });
      r.appendChild(go);
    }
    sec.appendChild(r);
  });
}
