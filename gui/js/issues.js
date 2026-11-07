"use strict";

/* ------- issues pane: the item's issue drafts (IssueDrafts), in the diff's slot ------- */
/* The /draft-issues skill writes one markdown file per issue under
   issues/<slug>/; the pane shows them one tab per issue, as the skill's own
   artifact page did. It shares the slot beside the terminal with the diff:
   opening one closes the other. The full set comes from /api/issues/<slug>
   when the pane opens and whenever the state's summary of the item's files
   (items[].issues) moves; the summary alone drives the toolbar button and
   the "revised" toast. */
let issuesOpen = false; // per chat, like the diff (adoptSidePane)
let issuesView = { slug: null, key: null, data: null, loading: false, error: null };
const issuesPick = {}; // slug → the file whose tab is shown

const itemIssues = (it) => (it && it.issues && it.issues.count ? it.issues : null);
const issuesKey = (slug) => `${slug}|${JSON.stringify(itemIssues(items.find(i => i.slug === slug)))}`;

/* The chat toolbar's "Issues · N" beside Diff, only while the item has drafts. */
function issuesButton(it) {
  const s = itemIssues(it);
  const b = action("issues", "issues-toggle", `Issues · ${s.count}`, "");
  b.title = s.open === s.count ? `${plural(s.count, "issue draft")} — review them beside the chat`
    : `${plural(s.count, "issue draft")}, ${s.open} still to create on GitHub`;
  b.setAttribute("aria-pressed", String(issuesShown()));
  b.tabIndex = -1;
  return b;
}

function issuesShown() {
  return issuesOpen && mode === "chat" && !!chatSlug && !!itemIssues(items.find(i => i.slug === chatSlug));
}

function toggleIssues() {
  setIssuesOpen(!issuesOpen);
}

function setIssuesOpen(on) {
  issuesOpen = on;
  rememberSidePane();
  if (on) { issuesView.key = null; if (diffOpen) toggleDiff(); }
  syncIssuesPane();
  renderDiffTray();
}

/* The detail sheet's Issues row — the item's chat view (live
   chat or not) with the pane open, the terminal left alone. The Issues view
   passes the row's file: the pane opens on that issue's tab. */
function openIssuesFor(it, file = null) {
  closeDetail();
  if (file) issuesPick[it.slug] = file;
  chatSlug = it.slug;
  if (mode !== "chat") setMode("chat");
  selectChat(it.slug);
  if (!issuesOpen) setIssuesOpen(true);
  else if (file && issuesView.slug === it.slug && issuesView.data) renderIssuesPane();
}

function applyIssuesLayout() {
  const shown = issuesShown();
  $("#issues-pane").hidden = !shown;
  document.body.classList.toggle("issues-open", shown);
  document.querySelectorAll("#chat-main .act.issues-toggle").forEach(b => b.setAttribute("aria-pressed", String(shown)));
}

/* Called after every chat render: refetch only when the item's files moved. */
function syncIssuesPane() {
  applyIssuesLayout();
  if (!issuesShown()) return;
  if (issuesKey(chatSlug) !== issuesView.key) loadIssues();
  syncIssueCreateButtons();
}

async function loadIssues() {
  const slug = chatSlug;
  const key = issuesKey(slug);
  if (issuesView.slug !== slug) issuesView.data = null;
  Object.assign(issuesView, { slug, key, loading: true, error: null });
  renderIssuesPane();
  let res;
  try {
    res = await (await fetch(`/api/issues/${encodeURIComponent(slug)}`)).json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  if (issuesView.key !== key) return; // the pane moved on while this was loading
  issuesView.loading = false;
  if (res.ok) issuesView.data = res; else { issuesView.error = res.error || "reading the issue drafts failed"; issuesView.data = null; }
  renderIssuesPane();
}

/* Every entry in tab order: open drafts, created ones, then files that
   don't parse. `n` is the tab's number. */
function issueEntries(d) {
  const open = d.issues.filter(i => !i.created);
  const created = d.issues.filter(i => i.created);
  return open.concat(created).map(i => ({ file: i.file, issue: i }))
    .concat(d.errors.map(e => ({ file: e.file, error: e.error })))
    .map((entry, i) => ({ ...entry, n: i + 1 }));
}

/* Rebuilt on a load, a tab switch and whenever the item's issue comments
   move (draftsChanged): an editor that was open comes back with what was
   typed in it, and its focus and caret, when its block is still shown. */
function renderIssuesPane() {
  renderIssuesBar();
  const body = $("#issues-body");
  const sameIssue = body.dataset.file && body.dataset.file === issuesPick[issuesView.slug];
  const editing = openIssueEditors(body);
  issuesView.drafts = issueDraftsShown();
  if (keepScroll(body, () => {
    body.innerHTML = "";
    if (issuesView.error) { body.appendChild(el("div", "diff-empty", esc(issuesView.error))); return false; }
    const d = issuesView.data;
    if (!d) { body.appendChild(el("div", "diff-empty", "loading issue drafts…")); return false; }
    const entries = issueEntries(d);
    if (!entries.length) { body.appendChild(el("div", "diff-empty", "No issue drafts.")); return false; }
    if (issuesView.reveal && !entries.some(e => e.file === issuesView.reveal.file)) {
      toast(`${issuesView.reveal.file} is not among the issue drafts any more`, false);
      issuesView.reveal = null;
    }
    let current = entries.find(e => e.file === issuesPick[d.slug]) || entries[0];
    issuesPick[d.slug] = current.file;
    body.dataset.file = current.file;
    body.append(renderIssuesNav(entries, current), renderIssue(current, d, sameIssue ? editing : new Map()));
  }, !!sameIssue) === false) return;
  syncIssueCreateButtons();
  const reveal = issuesView.reveal;
  if (reveal && reveal.file === body.dataset.file) {
    issuesView.reveal = null;
    const row = issueCommentRowAt(body.querySelector(".iss-main"), issueKey(reveal.file, reveal.block));
    if (row) flashDiffTarget(row, "center");
  }
}

function renderIssuesBar() {
  const bar = $("#issues-bar");
  bar.innerHTML = "";
  bar.appendChild(el("span", "tag", "ISSUES"));
  const d = issuesView.data;
  const info = el("span", "grow", "");
  if (d) {
    const created = d.issues.filter(i => i.created).length;
    info.textContent = [plural(d.issues.length + d.errors.length, "draft"),
      created && `${created} created`, d.errors.length && `${d.errors.length} unreadable`].filter(Boolean).join(" · ");
  }
  if (issuesView.loading) info.innerHTML += ' <span class="d-busy">loading…</span>';
  bar.appendChild(info);
  const uncreated = d ? d.issues.filter(i => !i.created).length : 0;
  if (uncreated > 1) bar.appendChild(createButton(`Create all ${uncreated} on GitHub`, null,
    `Ask the chat to create the ${uncreated} drafts not on GitHub yet`));
  if (d && d.issues.some(i => i.created)) {
    const clear = el("button", "", "Clear created");
    clear.title = "Delete the drafts already created on GitHub (they have their number)";
    clear.onclick = () => clearCreatedIssues(d);
    bar.appendChild(clear);
  }
  const reload = el("button", "", "↻");
  reload.title = "Reread the issue files";
  reload.onclick = () => loadIssues();
  const close = el("button", "", "✕");
  close.title = "Close the issues";
  close.onclick = () => setIssuesOpen(false);
  bar.append(reload, close);
}

async function clearCreatedIssues(d) {
  const created = d.issues.filter(i => i.created);
  if (!confirm(`Delete ${plural(created.length, "created issue draft")}? They stay on GitHub.`)) return;
  const res = await act("issues-clear-created", { slug: d.slug });
  if (res.ok) toast(`${plural((res.cleared || []).length, "created issue draft")} cleared`);
}

/* Mark seen: the server keeps it (IssueDrafts#acknowledge), so it survives a
   reload; its snapshot write doesn't move the pulse, hence the reread. */
async function acknowledgeIssue(slug, file, button) {
  button.disabled = true;
  const res = await act("issue-acknowledge", { slug, args: { file } });
  if (res.ok) loadIssues(); else button.disabled = false;
}

/* Create on GitHub: the chat is asked to create them — qm never
   runs gh. Refused like Send, so disabled with Send's reason, which is also
   what the pane opened from the detail sheet without a chat shows. */
function createButton(label, files, why) {
  const b = el("button", "iss-create", esc(label));
  b.dataset.why = why;
  b.onclick = () => createIssues(files);
  return b;
}

function syncIssueCreateButtons() {
  const blocker = diffSendBlocker();
  document.querySelectorAll("#issues-pane .iss-create").forEach(b => {
    b.disabled = !!blocker;
    b.title = blocker || b.dataset.why;
  });
}

async function createIssues(files) {
  const slug = chatSlug;
  if (diffSendBlocker()) return;
  const res = await act("issues-create", { slug, args: files ? { files } : {} });
  if (res.ok) toast(`Asked the chat to create ${plural((res.requested || []).length, "issue")} on GitHub`);
}

/* The group nav: open drafts under their group (first-seen order, headed
   only when there are several), then "Created on GitHub", then unreadable files. */
function renderIssuesNav(entries, current) {
  const nav = el("nav", "iss-nav");
  nav.setAttribute("aria-label", "Issue drafts");
  const sections = [];
  const section = (label, cls = "") => {
    let s = sections.find(x => x.label === label);
    if (!s) sections.push(s = { label, cls, entries: [] });
    return s;
  };
  entries.forEach(e => {
    if (e.error) section("Unreadable", "bad").entries.push(e);
    else if (e.issue.created) section("Created on GitHub").entries.push(e);
    else section(e.issue.group || "Issues").entries.push(e);
  });
  sections.forEach(s => {
    if (sections.length > 1) nav.appendChild(el("div", `iss-group ${s.cls}`, esc(s.label)));
    s.entries.forEach(e => nav.appendChild(issueTab(e, e.file === current.file)));
  });
  return nav;
}

function issueTab(e, selected) {
  const i = e.issue;
  const tab = el("button", "iss-tab" + (e.error ? " broken" : "") + (i && i.created ? " created" : ""));
  tab.type = "button";
  tab.dataset.file = e.file;
  tab.setAttribute("aria-current", String(selected));
  tab.appendChild(el("span", "num", String(e.n)));
  tab.appendChild(el("span", "t", esc(i ? i.title : e.file)));
  const meta = el("span", "iss-tab-meta");
  if (e.error) meta.appendChild(el("span", "iss-pill bug", "unreadable"));
  else {
    meta.appendChild(kindPill(i.kind));
    if (i.created) meta.appendChild(el("span", "iss-pill created", `#${i.number}`));
    else if (i.change && !i.acknowledged) { const dot = el("span", "iss-dot"); dot.title = "Changed in the last revision"; meta.appendChild(dot); }
  }
  tab.appendChild(meta);
  tab.onclick = () => { issuesPick[issuesView.slug] = e.file; renderIssuesPane(); };
  return tab;
}

const kindPill = (kind) => el("span", kind === "bug" ? "iss-pill bug" : "iss-pill", esc(kind));

/* One issue. A click on the title (.iss-title[data-issue-target]) or on a
   rendered block (.iss-block[data-src], its source text) opens a comment
   editor there; a created issue (data-readonly) takes no new comments.
   `editing` holds the editors open before a rebuild. */
function renderIssue(e, d, editing = new Map()) {
  const main = el("div", "iss-main");
  main.dataset.file = e.file;
  if (e.error) {
    main.appendChild(el("div", "iss-head", `<div class="iss-title">${esc(e.file)}</div>`));
    main.appendChild(el("div", "iss-error", `<b>This file doesn't read as an issue draft:</b> ${esc(e.error)}`));
    return main;
  }
  const i = e.issue;
  const prev = i.created ? null : i.previous;
  if (i.created) main.dataset.readonly = "1";
  main.dataset.title = i.title;
  const head = el("div", "iss-head");
  const title = el("div", "iss-title" + (prev && prev.title !== i.title ? " changed" : ""), esc(i.title));
  title.dataset.issueTarget = i.file;
  if (prev && prev.title !== i.title) title.title = `Was: ${prev.title}`;
  const acts = el("div", "iss-acts");
  const copy = el("button", "", "Copy markdown");
  copy.title = "Copy the issue body";
  copy.onclick = () => copyText(i.body + "\n", copy);
  acts.appendChild(copy);
  if (!i.created) acts.appendChild(createButton("Create on GitHub", [i.file], "Ask the chat to create this issue on GitHub"));
  else if (i.number) acts.appendChild(draftStartControl(d.slug, i, d.repo));
  head.append(title, acts);
  main.appendChild(head);

  const meta = el("div", "iss-meta");
  meta.appendChild(kindPill(i.kind));
  if (i.created) meta.appendChild(createdLink(i, d.repo));
  if (i.parent) meta.appendChild(el("span", "", `Parent: #${esc(i.parent.replace(/^#/, ""))}`));
  meta.appendChild(el("span", "", `Depends on: ${i.deps.length ? esc(i.deps.join(", ")) : "—"}`));
  main.appendChild(meta);
  main.append(el("div", "iss-cmts"), el("div", "iss-stale"));

  if (i.created) main.appendChild(el("div", "iss-note", "Created on GitHub — read-only here. Clear created removes the draft."));
  else if (i.change && !i.acknowledged) main.appendChild(el("div", "iss-change", `<span><b>Changed in the last revision:</b> ${esc(i.change)}</span>`));
  const body = renderIssueBody(i.body, prev ? issueBlockSources(prev.body) : null);
  const marked = prev && (prev.title !== i.title || body.querySelector(".iss-block.changed"));
  if (marked) {
    main.appendChild(el("div", "iss-legend", '<span class="iss-swatch"></span>new or reworded since the version before'));
  }
  if (!i.created && (marked || (i.change && !i.acknowledged))) {
    const seen = el("button", "iss-seen", "Mark seen");
    seen.title = "Acknowledge this revision: its highlights go until the next one";
    seen.onclick = () => acknowledgeIssue(d.slug, i.file, seen);
    (main.querySelector(".iss-legend") || main.querySelector(".iss-change")).appendChild(seen);
  }
  main.appendChild(body);
  issueCommentsOn(d.slug, i.file).forEach(c => placeIssueComment(main, c.block, editing.get(issueKey(i.file, c.block))));
  editing.forEach((open, key) => {
    if (!issueCommentRowAt(main, key) && open.file === i.file && issueBlockAt(main, open.block)) placeIssueComment(main, open.block, open);
  });
  return main;
}

function createdLink(i, repo) {
  if (!repo) return el("span", "iss-pill created", `#${i.number}`);
  const a = el("a", "iss-pill created", `${esc(repo)}#${i.number} ↗`);
  a.href = `https://github.com/${repo}/issues/${i.number}`;
  a.target = "_blank"; a.rel = "noopener";
  return a;
}

/* ------- the body as blocks ------- */
/* A block is a heading, paragraph, code block, quote, each list item and each
   table row, named by its source text, trimmed. The same split marks changed
   blocks (a source not among the previous version's) and anchors comments, so
   the two can't disagree. Raw HTML in a body is shown as text, never run. */
let issueMarked = null;
function issueMarkdown() {
  if (issueMarked || !window.marked || !window.marked.Marked) return issueMarked;
  issueMarked = new window.marked.Marked({ gfm: true });
  issueMarked.use({ renderer: { html: (x) => esc(typeof x === "string" ? x : x.text) } });
  return issueMarked;
}

const tableLines = (tok) => tok.raw.split("\n").filter(l => l.trim()).filter((_, n) => n !== 1);

/* A top-level token's block sources, in the order its elements render. */
function tokenSources(tok) {
  if (tok.type === "list") return tok.items.map(item => item.raw.trim());
  if (tok.type === "table") return tableLines(tok).map(l => l.trim());
  return [tok.raw.trim()];
}

function issueBlockSources(md) {
  const m = issueMarkdown();
  if (!m) return [];
  return m.lexer(md).filter(t => t.type !== "space" && t.type !== "def").flatMap(tokenSources).filter(Boolean);
}

/* The rendered body; `previous` (sources, or null) marks what changed. */
function renderIssueBody(md, previous) {
  const box = el("div", "iss-md");
  const m = issueMarkdown();
  if (!m) { box.appendChild(el("pre", "iss-raw", esc(md))); return box; }
  const seen = previous && new Set(previous);
  const mark = (node, src) => {
    if (!node || !src) return;
    node.classList.add("iss-block");
    node.dataset.src = src;
    if (seen && !seen.has(src)) node.classList.add("changed");
  };
  m.lexer(md).filter(t => t.type !== "space" && t.type !== "def").forEach(tok => {
    const holder = document.createElement("div");
    holder.innerHTML = m.parser([tok]);
    const sources = tokenSources(tok);
    if (tok.type === "list") {
      const list = holder.querySelector("ul, ol");
      [...(list ? list.children : [])].forEach((li, n) => mark(li, sources[n]));
    } else if (tok.type === "table") {
      holder.querySelectorAll("tr").forEach((tr, n) => mark(tr, sources[n]));
      const table = holder.querySelector("table");
      if (table) { const wrap = el("div", "table-scroll"); table.replaceWith(wrap); wrap.appendChild(table); }
    } else if (holder.children.length === 1) {
      mark(holder.firstElementChild, sources[0]);
    } else {
      const wrap = el("div", "");
      wrap.append(...holder.childNodes);
      holder.appendChild(wrap);
      mark(wrap, sources[0]);
    }
    box.append(...holder.childNodes);
  });
  box.querySelectorAll("a").forEach(a => {
    if (!/^(https?:|mailto:|#)/i.test(a.getAttribute("href") || "")) a.removeAttribute("href");
    a.target = "_blank"; a.rel = "noopener";
  });
  box.querySelectorAll('input[type="checkbox"]').forEach(c => { c.disabled = true; });
  return box;
}

/* ------- comments on blocks ------- */
/* An issue-comment draft is addressed by its issue's file and a block's
   source text ("" for the whole issue), and shows as a row under the first
   block with exactly that text, under the title for the whole issue, or —
   its block reworded or gone — at the issue's top, quoting the text it was
   made on. Never re-anchored, never dropped. */
const issueKey = (file, block) => `${file}\n${block || ""}`;
const issueDraftsShown = () => itemDrafts().filter(isIssueComment).map(d => `${issueKey(d.file, d.block)}\n${d.comment}`).sort().join("\0");
const issueCommentsOn = (slug, file) => itemDrafts(slug).filter(d => isIssueComment(d) && d.file === file);

function issueCommentAt(file, block) {
  return itemDrafts().find(d => isIssueComment(d) && issueKey(d.file, d.block) === issueKey(file, block)) || null;
}

function issueBlockSnippet(block) {
  const line = String(block || "").split("\n")[0].replace(/\s+/g, " ").trim();
  return line.length > 80 ? line.slice(0, 79) + "…" : line;
}

/* The element a comment on `block` sits under, or null when no block shown has that text. */
function issueBlockAt(main, block) {
  if (!block) return main.querySelector(".iss-title");
  return [...main.querySelectorAll(".iss-block")].find(b => b.dataset.src === block) || null;
}

function issueCommentRowAt(main, key) {
  return main ? [...main.querySelectorAll(".iss-cmt")].find(r => r.dataset.key === key) || null : null;
}

/* The comment row for `block` (`open`: its editor, with what was typed),
   put where it belongs. A table row's comment gets a row of its own, a list
   item's goes inside the item. */
function placeIssueComment(main, block, open = null) {
  const anchor = block ? issueBlockAt(main, block) : null;
  const row = issueCommentRow(main, block, { open, stale: !!block && !anchor });
  if (!block) main.querySelector(".iss-cmts").appendChild(row);
  else if (!anchor) main.querySelector(".iss-stale").appendChild(row);
  else if (anchor.tagName === "TR") {
    const tr = el("tr", "iss-cmt-tr");
    const td = el("td");
    td.colSpan = anchor.children.length || 1;
    td.appendChild(row);
    tr.appendChild(td);
    anchor.after(tr);
  } else if (anchor.tagName === "LI") anchor.appendChild(row);
  else anchor.after(row);
  return row;
}

function removeIssueCommentRow(row) {
  (row.closest(".iss-cmt-tr") || row).remove();
}

/* One comment: what it is on, the comment (a click edits it), ✎ and ✕; or
   its editor while open. */
function issueCommentRow(main, block, { open = null, stale = false } = {}) {
  const file = main.dataset.file;
  const draft = issueCommentAt(file, block);
  const row = el("div", "iss-cmt" + (stale ? " stale" : ""));
  row.dataset.key = issueKey(file, block);
  const top = el("div", "iss-cmt-top");
  top.appendChild(el("span", "iss-cmt-tag", !block ? "on the whole issue" : stale ? "on a block that changed" : "comment"));
  top.appendChild(el("span", "grow"));
  row.appendChild(top);
  if (stale) row.appendChild(el("blockquote", "iss-cmt-quote", esc(block)));
  const edit = () => row.replaceWith(issueCommentRow(main, block, { open: { value: draft ? draft.comment : "", focus: true }, stale }));
  if (!open && draft) {
    const pen = el("button", "dt-x", "✎");
    pen.title = "Edit the comment";
    pen.onclick = edit;
    const del = el("button", "dt-x del", "✕");
    del.title = "Delete this comment";
    del.onclick = () => { putIssueComment(main, block, ""); removeIssueCommentRow(row); };
    top.append(pen, del);
    const text = el("div", "d-comment-text", esc(draft.comment));
    text.title = "Edit the comment";
    text.onclick = edit;
    row.appendChild(text);
    return row;
  }
  const box = el("textarea", "d-comment-input");
  box.rows = 3;
  box.placeholder = `Comment on ${block ? "this block" : "the whole issue"} — ⌘⏎ saves, Esc cancels`;
  box.value = open ? open.value : draft ? draft.comment : "";
  const close = () => {
    const fresh = issueCommentAt(file, block);
    if (fresh) row.replaceWith(issueCommentRow(main, block, { stale }));
    else removeIssueCommentRow(row);
  };
  const save = () => { putIssueComment(main, block, box.value); close(); };
  box.addEventListener("keydown", e => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
  });
  const acts = el("div", "d-comment-acts");
  const ok = el("button", "primary", "Save");
  ok.onclick = save;
  const no = el("button", "", "Cancel");
  no.onclick = close;
  acts.append(ok, no);
  if (draft) {
    const del = el("button", "danger", "Delete");
    del.onclick = () => { putIssueComment(main, block, ""); close(); };
    acts.appendChild(del);
  }
  row.append(box, acts);
  if (!open || open.focus) setTimeout(() => {
    box.focus();
    if (open && open.caret) box.setSelectionRange(open.caret[0], open.caret[1]);
  }, 0);
  return row;
}

/* Put by address, like a diff comment: a blank comment removes it. Shown at
   once — the caller swaps the row, the tray follows — and the action's
   refresh confirms it. */
function putIssueComment(main, block, comment) {
  const slug = chatSlug;
  const address = { file: main.dataset.file, block: block || "", title: main.dataset.title || "" };
  const key = issueKey(address.file, address.block);
  patchLocalDrafts(slug, drafts => {
    const old = drafts.find(d => isIssueComment(d) && issueKey(d.file, d.block) === key);
    const rest = drafts.filter(d => d !== old);
    return comment.trim() ? rest.concat([{ id: `pending:${key}`, ...(old || {}), kind: "issue-comment", ...address, comment }]) : rest;
  });
  issuesView.drafts = issueDraftsShown();
  draftsChanged();
  return draftAction("issue-comment-put", slug, { ...address, comment });
}

/* The editors open in the pane, for a rebuild to bring back. */
function openIssueEditors(body) {
  const open = new Map();
  body.querySelectorAll(".iss-cmt textarea").forEach(box => {
    const key = box.closest(".iss-cmt").dataset.key;
    const at = key.indexOf("\n");
    const focus = document.activeElement === box;
    open.set(key, { file: key.slice(0, at), block: key.slice(at + 1), value: box.value, focus,
      caret: focus ? [box.selectionStart, box.selectionEnd] : null });
  });
  return open;
}

/* A click on a block or the title opens its comment (or focuses the open
   editor) — unless it ended a text selection, which is someone copying. */
$("#issues-body").addEventListener("click", e => {
  if (e.target.closest(".iss-cmt, .iss-cmt-tr, a, button, input, textarea")) return;
  const main = e.target.closest(".iss-main");
  if (!main || main.dataset.readonly || !main.dataset.title) return;
  const target = e.target.closest(".iss-block, .iss-title[data-issue-target]");
  if (!target || !main.contains(target)) return;
  const sel = window.getSelection();
  if (sel && !sel.isCollapsed && target.contains(sel.anchorNode)) return;
  const block = target.classList.contains("iss-block") ? target.dataset.src : "";
  const row = issueCommentRowAt(main, issueKey(main.dataset.file, block));
  if (!row) { placeIssueComment(main, block, { value: "", focus: true }); return; }
  const box = row.querySelector("textarea");
  if (box) box.focus();
  else row.replaceWith(issueCommentRow(main, block, { open: { value: issueCommentAt(main.dataset.file, block)?.comment || "", focus: true } }));
});

/* From the tray: the Issues pane at that issue, the comment flashed. */
function revealIssueComment(d) {
  issuesPick[chatSlug] = d.file;
  issuesView.reveal = { file: d.file, block: d.block || "" };
  if (!issuesShown()) setIssuesOpen(true);
  else renderIssuesPane();
}

function copyText(text, button) {
  const label = button.textContent;
  const done = (msg) => { button.textContent = msg; setTimeout(() => { button.textContent = label; }, 1500); };
  if (!navigator.clipboard) { done("Copy failed"); return; }
  navigator.clipboard.writeText(text).then(() => done("Copied"), () => done("Copy failed"));
}

/* ------- revisions: a toast, never a view switch ------- */
/* From each state, a file whose version moved since the last state is
   revised. Claude revises in several Edits, so the toast waits until an
   item's files have been still for a few seconds and counts each file once. */
const issuesSeen = { versions: null, pending: {}, timers: {} }; // versions: slug → { file → version }, null before the first state
const ISSUES_QUIET_MS = 4000;

function noticeIssuesInState(list) {
  const first = issuesSeen.versions === null;
  const before = issuesSeen.versions || {};
  const now = {};
  (list || []).forEach(it => {
    const versions = (itemIssues(it) || {}).versions || {};
    now[it.slug] = versions;
    const old = before[it.slug] || {};
    const revised = first ? [] : Object.keys(versions).filter(f => old[f] && old[f] !== versions[f]);
    if (!revised.length) return;
    const pending = issuesSeen.pending[it.slug] = issuesSeen.pending[it.slug] || new Set();
    revised.forEach(f => pending.add(f));
    clearTimeout(issuesSeen.timers[it.slug]);
    issuesSeen.timers[it.slug] = setTimeout(() => toastIssuesRevised(it.slug), ISSUES_QUIET_MS);
  });
  issuesSeen.versions = now;
}

function toastIssuesRevised(slug) {
  const n = (issuesSeen.pending[slug] || new Set()).size;
  delete issuesSeen.pending[slug];
  delete issuesSeen.timers[slug];
  if (!n) return;
  const here = mode === "chat" && chatSlug === slug;
  toast(`${plural(n, "issue")} revised${here ? "" : ` for ${slug}`}`);
}
