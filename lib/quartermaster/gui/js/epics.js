"use strict";

/* ------- epics -------
   An epic is an item of kind "epic"; a child names it in `epic`. Children,
   rollups and the resolve suggestion are derived here from `items` and
   `todos`; a child whose epic slug dangles (or isn't an epic) has no epic. */
const isEpic = it => !!it && it.kind === "epic";
function epicOf(it) {
  const e = it && it.epic && items.find(i => i.slug === it.epic);
  return isEpic(e) ? e : null;
}
const epicChildren = e => items.filter(i => i.epic === e.slug && !isEpic(i) && i.kind !== "automation");
const openTodosOn = slug => todos.filter(t => !t.done_at && t.item === slug);
function epicOpenTodos(e) {
  const slugs = new Set([e.slug, ...epicChildren(e).map(c => c.slug)]);
  return todos.filter(t => !t.done_at && slugs.has(t.item));
}
/* Suggest-only: nothing resolves an epic but the user's click. */
function epicResolvable(e) {
  const kids = epicChildren(e);
  return e.state !== "resolved" && kids.length > 0 && kids.every(c => c.state === "resolved") && !epicOpenTodos(e).length;
}
function epicRollup(e) {
  const kids = epicChildren(e);
  const open = kids.filter(c => c.state !== "resolved").length;
  const t = epicOpenTodos(e).length;
  return `${kids.length} item${kids.length === 1 ? "" : "s"}${kids.length ? ` · ${open} open` : ""} · ${t} todo${t === 1 ? "" : "s"}`;
}
/* One small chip per link: the label's first letter, the label as its title. */
function linkChips(it) {
  const box = el("span", "epic-links");
  (it.links || []).filter(l => /^https?:\/\//i.test(l.url || "")).forEach(l => {
    const a = el("a", "epic-link", esc((l.label || "?").trim().charAt(0).toUpperCase() || "?"));
    a.href = l.url; a.target = "_blank"; a.rel = "noreferrer";
    a.title = `${l.label} — ${l.url}`;
    box.appendChild(a);
  });
  return box;
}
function resolveSuggestion(e) {
  if (!epicResolvable(e)) return null;
  const b = el("button", "epic-suggest", "✓ all done — resolve epic?");
  b.title = "Every item is resolved and no todo is open: resolve the epic";
  b.onclick = ev => { ev.stopPropagation(); changeState(e, "resolved"); };
  return b;
}
function firstLine(text) {
  const line = String(text || "").split("\n").map(s => s.trim()).find(Boolean) || "";
  return line === "_TODO_" ? "" : line;
}

/* Folded epic cards, remembered per browser. */
let epicsFolded = new Set();
try { epicsFolded = new Set(JSON.parse(localStorage.getItem("qm-epics-folded") || "[]")); } catch (e) { /* storage blocked: all open */ }
function toggleEpicFold(slug) {
  if (epicsFolded.has(slug)) epicsFolded.delete(slug); else epicsFolded.add(slug);
  try { localStorage.setItem("qm-epics-folded", JSON.stringify([...epicsFolded])); } catch (e) { /* this page only */ }
  render();
}

/* The board's nesting: an epic shown in its column holds its children, which
   leave their own columns; an epic filtered out by state leaves them as
   normal cards. An epic matches a search when it or any child does. Returns
   the slugs that are nested. */
function nestEpics(boardItems, shown, results) {
  const nested = new Set();
  boardItems.filter(e => isEpic(e) && shown.includes(e.state)).forEach(e => {
    const kids = epicChildren(e);
    kids.forEach(c => nested.add(c.slug));
    if (results.has(e.slug)) return;
    const best = kids.map(c => results.get(c.slug)).filter(Boolean).sort((a, b) => b.score - a.score)[0];
    if (best) results.set(e.slug, { score: best.score });
  });
  return nested;
}

function epicCard(e, results) {
  const folded = epicsFolded.has(e.slug);
  const c = el("div", "card epic-card");
  c.dataset.slug = e.slug;
  c.tabIndex = 0;

  const head = el("div", "epic-head");
  head.title = folded ? "Unfold" : "Fold";
  head.appendChild(el("span", "epic-chev", folded ? "▸" : "▾"));
  head.appendChild(el("span", "epic-kind", "EPIC"));
  head.appendChild(el("span", "status-dot dot-" + e.state));
  head.appendChild(el("span", "epic-title", esc(e.title)));
  head.appendChild(el("span", "epic-roll", esc(epicRollup(e))));
  head.appendChild(linkChips(e));
  const suggest = resolveSuggestion(e);
  if (suggest) head.appendChild(suggest);
  const acts = el("span", "epic-acts");
  acts.appendChild(action("state", "", "State ▾", ""));
  acts.appendChild(action("more", "", "⋯", ""));
  acts.querySelectorAll("button").forEach(b => b.tabIndex = -1);
  head.appendChild(acts);
  c.appendChild(head);

  if (!folded) {
    const desc = firstLine(e.description);
    if (desc) c.appendChild(el("div", "epic-desc", esc(desc)));
    const kids = epicChildren(e);
    const searching = terms.some(t => !t.neg);
    kids.filter(k => k.state !== "resolved").forEach(k => c.appendChild(epicChildRow(k, searching && results.has(k.slug))));
    const done = kids.length - kids.filter(k => k.state !== "resolved").length;
    if (done) c.appendChild(el("div", "epic-sub", `${done} resolved`));
    openTodosOn(e.slug).forEach(t => c.appendChild(epicTodoRow(t)));
  }

  // The header folds and the rows open their own item; elsewhere (and the
  // State/⋯ buttons) falls through to the board's card click.
  c.addEventListener("click", ev => {
    if (ev.target.closest(".act")) return;
    const row = ev.target.closest(".epic-row");
    if (row) { ev.stopPropagation(); const it = items.find(i => i.slug === row.dataset.child); if (it) openChat(it); return; }
    if (ev.target.closest("a, .epic-todo")) { ev.stopPropagation(); return; }
    if (ev.target.closest(".epic-head")) { ev.stopPropagation(); toggleEpicFold(e.slug); }
  });
  return c;
}
function epicChildRow(it, hit) {
  const r = el("div", "epic-row" + (hit ? " hit-row" : ""));
  r.dataset.child = it.slug;
  r.title = `${it.slug} — open its chat`;
  r.appendChild(el("span", "status-dot dot-" + it.state));
  r.appendChild(el("span", "epic-row-title", esc(it.title)));
  if (it.live) r.appendChild(el("span", "live-dot", "live"));
  if (it.served) r.appendChild(servedMark());
  r.appendChild(el("span", "sess", (it.sessions || 0) + " sess"));
  const n = openTodosOn(it.slug).length;
  if (n) r.appendChild(el("span", "epic-roll", `☐ ${n}`));
  return r;
}
function epicTodoRow(t) {
  const row = el("label", "epic-todo");
  const box = el("input");
  box.type = "checkbox";
  box.onchange = () => act("todo-done", { args: { id: t.id, done: true } });
  row.append(box, el("span", "", esc(t.text)));
  return row;
}

/* Epic…: put an item in an epic, move it to another, or take it out. */
function epicMenu(anchor, it) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Epic of " + it.slug));
    const epics = items.filter(i => isEpic(i) && (i.state !== "resolved" || i.slug === it.epic));
    if (!epics.length) p.appendChild(el("div", "pop-label", "no epics yet — New item makes one"));
    const set = (epic, msg) => { closePop(); act("epic-set", { slug: it.slug, args: { epic } }).then(r => { if (r.ok) toast(msg); }); };
    epics.forEach(e => {
      const b = el("button", "", "");
      b.appendChild(el("span", "pdot dot-" + e.state));
      b.appendChild(el("span", "", esc(e.title)));
      if (e.slug === it.epic) b.appendChild(el("span", "tick", "●"));
      b.onclick = () => set(e.slug, `${it.slug} → ◆ ${e.title}`);
      p.appendChild(b);
    });
    if (it.epic) {
      p.appendChild(el("div", "sep"));
      const b = el("button", "", "No epic");
      b.onclick = () => set("", `${it.slug} → no epic`);
      p.appendChild(b);
    }
  });
}

/* The detail sheet's Links section: each link with ✕, then label + url to add
   one (a label already there gets the new url). The sheet is rebuilt on every
   refresh, so the half-typed link and its focus live in linkDraft. */
let linkDraft = { slug: null, label: "", url: "", focus: null };
function linkField(it, key, placeholder, type) {
  const input = el("input");
  input.type = type; input.placeholder = placeholder;
  input.value = linkDraft[key];
  input.oninput = () => { linkDraft[key] = input.value; };
  input.onfocus = () => { linkDraft.focus = key; };
  // A rebuild removes the input: only a blur that leaves it in the page is the user's.
  input.onblur = () => setTimeout(() => { if (input.isConnected && linkDraft.focus === key) linkDraft.focus = null; });
  if (linkDraft.focus === key) setTimeout(() => input.focus({ preventScroll: true }));
  return input;
}
function linksEditor(it) {
  if (linkDraft.slug !== it.slug) linkDraft = { slug: it.slug, label: "", url: "", focus: null };
  const box = el("div", "links-editor");
  (it.links || []).forEach(l => {
    const row = el("div", "link-row");
    const a = el("a", "", `<b>${esc(l.label)}</b> <span>${esc(l.url)}</span>`);
    if (/^https?:\/\//i.test(l.url || "")) { a.href = l.url; a.target = "_blank"; a.rel = "noreferrer"; }
    const rm = el("button", "act", "✕");
    rm.title = `Remove ${l.label}`;
    rm.onclick = () => act("link-remove", { slug: it.slug, args: { label: l.label } }).then(r => { if (r.ok) toast(`removed ${l.label}`); });
    row.append(a, rm);
    box.appendChild(row);
  });
  if (!(it.links || []).length) box.appendChild(el("div", "desc-text", "No links yet."));
  const add = el("div", "link-add");
  const label = linkField(it, "label", "Label", "text");
  const url = linkField(it, "url", "https://…", "url");
  const go = el("button", "act", "+ Add link");
  go.onclick = () => {
    const l = linkDraft.label.trim(), u = linkDraft.url.trim();
    if (!l) { label.focus(); return; }
    if (!u) { url.focus(); return; }
    // Cleared before the post: act's refresh rebuilds the sheet before it answers.
    const typed = linkDraft;
    linkDraft = { slug: it.slug, label: "", url: "", focus: null };
    act("link-set", { slug: it.slug, args: { label: l, url: u } }).then(r => {
      if (r.ok) toast(`linked ${l}`); else linkDraft = typed;
    });
  };
  url.addEventListener("keydown", ev => { if (ev.key === "Enter") go.click(); });
  add.append(label, url, go);
  box.appendChild(add);
  return box;
}

/* The New item dialog's epic parts: a Work item / Epic toggle, and for a
   work item an Epic picker (picking one also picks the epic's project).
   chosen() is the `new` action's kind/epic args. */
function newItemEpicFields(projectSelect) {
  let kind = "";
  const kindRow = el("div", "segmented new-kind", `<button type="button" data-kind="" aria-pressed="true">Work item</button>` +
    `<button type="button" data-kind="epic" aria-pressed="false">Epic</button>`);
  kindRow.title = "An epic groups work items; it can have its own chat, notes and todos";
  const epics = items.filter(i => isEpic(i) && i.state !== "resolved");
  const epicField = el("div", "field", `<label>Epic <span style="text-transform:none;color:var(--faint)">(optional)</span></label>` +
    `<select><option value="">— none</option>${epics.map(e => `<option value="${esc(e.slug)}">◆ ${esc(e.title)}</option>`).join("")}</select>`);
  const epicSelect = epicField.querySelector("select");
  const showEpic = on => { epicField.style.display = on && epics.length ? "" : "none"; };
  showEpic(true);
  epicSelect.onchange = () => {
    const e = epics.find(x => x.slug === epicSelect.value);
    if (e && PROJECTS.includes(e.project)) projectSelect.value = e.project;
  };
  kindRow.addEventListener("click", ev => {
    const b = ev.target.closest("button"); if (!b) return;
    kind = b.dataset.kind;
    kindRow.querySelectorAll("button").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
    showEpic(!kind);
  });
  const chosen = () => (kind ? { kind } : epicSelect.value ? { epic: epicSelect.value } : {});
  return { kindRow, epicField, chosen };
}
