"use strict";

/* ------- PR scope: the pull request's review threads, under their lines ------- */
/* Fetched from GitHub (ReviewThreads, /api/pr-threads) once the PR scope's
   diff is shown, keyed by repo#n@head, so the diff never waits on them and a
   push brings fresh ones; ↻ asks past the server's brief cache. Read-only
   apart from three things: Reply makes a thread-reply draft (the tray holds
   it until the pending review is posted), and Resolve/Unresolve act on
   GitHub at once. A thread sits under its line when the diff shows that line
   on its side; anything else (outdated, on a line GitHub's own UI let
   someone comment on outside the hunks, or under a commit selection, whose
   numbers aren't the PR's) folds into a group at the top of its file. */
let prThreads = { key: null, data: null, error: null, loading: false };
const prThreadsShown = new Set(); // resolved threads unfolded by hand
const prReplyEditing = new Map(); // thread id → what its open reply editor holds

const isThreadReply = d => d.kind === "thread-reply";

function prThreadsKey(d) {
  return d && d.scope === "pr" && d.pr ? `${d.pr.repo}#${d.pr.number}@${d.pr.headSha}` : null;
}

async function loadPrThreads(fresh = false) {
  const d = diffView.data;
  const key = prThreadsKey(d);
  if (!key) return;
  if (!fresh && prThreads.key === key && (prThreads.data || prThreads.loading)) return;
  prThreads = { key, data: prThreads.key === key ? prThreads.data : null, error: null, loading: true };
  const params = new URLSearchParams({ repo: d.pr.repo, number: d.pr.number, head: d.pr.headSha });
  if (fresh) params.set("fresh", "1");
  let res;
  try {
    res = await (await fetch(`/api/pr-threads?${params}`)).json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  if (prThreads.key !== key) return; // another PR or head took over meanwhile
  prThreads.loading = false;
  if (res.ok) prThreads.data = res; else prThreads.error = res.error || "fetching the review threads failed";
  if (prThreadsKey(diffView.data) === key) renderDiffPane();
}

/* The threads of what the pane shows now, or null outside the PR scope. */
function prThreadList(d = diffView.data) {
  return prThreadsKey(d) === prThreads.key && prThreads.data ? prThreads.data.threads : null;
}

/* The bar's word on them: a count, loading, or why they are missing. */
function prThreadsNote(d) {
  if (!prThreadsKey(d) || prThreads.key !== prThreadsKey(d)) return "";
  if (prThreads.error) return ` · <span class="d-busy" title="${esc(prThreads.error)}">threads unavailable</span>`;
  const list = prThreadList(d);
  if (!list) return prThreads.loading ? ' · <span class="d-busy">loading threads…</span>' : "";
  const open = list.filter(t => !t.resolved).length;
  return list.length ? ` · <span class="pt-count" title="${plural(list.length, "review thread")}, ${open} unresolved">💬 ${open}/${list.length}</span>` : "";
}

/* Where each thread of a file shows: rows keyed side:line, and the rest. */
function prThreadPlacement(f) {
  const list = prThreadList();
  if (!list) return null;
  const mine = list.filter(t => t.path === f.path || (f.oldPath && t.path === f.oldPath && t.side === "old"));
  if (!mine.length) return null;
  const shown = new Set();
  f.hunks.forEach(h => h.lines.forEach(l => prLineKeys(l).forEach(k => shown.add(k))));
  const ranged = !!diffView.data.range;
  const rows = new Map();
  const off = [];
  const onFile = [];
  mine.forEach(t => {
    if (t.file) { onFile.push(t); return; }
    const k = `${t.side}:${t.line}`;
    if (!ranged && t.line != null && shown.has(k)) rows.set(k, (rows.get(k) || []).concat([t]));
    else off.push(t);
  });
  return { rows, off, onFile, count: mine.length, open: mine.filter(t => !t.resolved).length };
}

/* A removed line is GitHub's LEFT side, an added one RIGHT; a context line
   is both, RIGHT by its new number and LEFT by its old one. */
function prLineKeys(line) {
  if (line.t === "-") return [`old:${line.o}`];
  if (line.t === "+") return [`new:${line.n}`];
  return [`new:${line.n}`, `old:${line.o}`];
}

/* The file header's "💬 open/all". */
function prThreadBadge(placement) {
  const badge = el("span", "pt-badge" + (placement.open ? "" : " done"), `💬 ${placement.open}/${placement.count}`);
  badge.title = `${plural(placement.count, "review thread")} on this file, ${placement.open} unresolved`;
  return badge;
}

/* The top of a file: comments on the whole file, open, then the threads not
   on a line shown here, folded. */
function prThreadsAtTop(placement) {
  const box = el("div", "pt-top");
  placement.onFile.forEach(t => box.appendChild(prThreadWithQuote(t, "on the file")));
  if (placement.off.length) {
    const group = el("details", "pt-off");
    const label = diffView.data.range
      ? `${plural(placement.off.length, "thread")} — numbered on the whole PR; Show all commits to see them on their lines`
      : `${plural(placement.off.length, "thread")} on unchanged lines`;
    group.appendChild(el("summary", "", esc(label)));
    placement.off.forEach(t => group.appendChild(prThreadWithQuote(t)));
    box.appendChild(group);
  }
  return box;
}

/* Threads on files this diff doesn't show at all, folded above the files. */
function prThreadsElsewhere(d) {
  const list = prThreadList(d);
  if (!list) return null;
  const paths = new Set(d.files.flatMap(f => [f.path, f.oldPath]));
  const stray = list.filter(t => !paths.has(t.path));
  if (!stray.length) return null;
  const group = el("details", "pt-off pt-elsewhere");
  group.appendChild(el("summary", "", esc(`${plural(stray.length, "thread")} on files not in this diff`)));
  stray.forEach(t => group.appendChild(prThreadWithQuote(t, t.path)));
  return group;
}

/* An off-line thread: its line number and the line as GitHub quotes it. */
function prThreadWithQuote(t, where = null) {
  const wrap = el("div", "pt-quoted");
  const line = t.line != null ? t.line : t.originalLine;
  const at = where || (line != null ? `line ${line}${t.side === "old" ? " (removed side)" : ""}` : "");
  const head = el("div", "pt-where", `${esc(at)}${t.line == null && line != null && !t.file ? " · was there" : ""}`);
  wrap.appendChild(head);
  if (t.quote && !t.file) wrap.appendChild(el("pre", "pt-quote", esc(t.quote)));
  wrap.appendChild(renderPrThread(t));
  return wrap;
}

/* The row under a line holding its threads. */
function prThreadRow(threads) {
  const tr = el("tr", "d-thread");
  tr.appendChild(el("td", "d-num", ""));
  tr.appendChild(el("td", "d-num", ""));
  const td = el("td", "d-thread-cell");
  threads.forEach(t => td.appendChild(renderPrThread(t)));
  tr.appendChild(td);
  return tr;
}

/* One thread: its state, its comments (read-only), the reply draft, and
   Reply / Resolve / Unresolve. A resolved one folds to one line, as on
   GitHub, until unfolded. */
function renderPrThread(t) {
  const allPending = t.comments.length && t.comments.every(c => c.pending);
  const box = el("div", `pr-thread${t.resolved ? " resolved" : ""}${allPending ? " pending" : ""}`);
  box.dataset.thread = t.id;
  const head = el("div", "pt-head");
  if (t.resolved) head.appendChild(el("span", "pt-chip good", `resolved${t.resolvedBy ? ` by ${esc(t.resolvedBy)}` : ""}`));
  if (t.outdated) head.appendChild(el("span", "pt-chip warn", "outdated"));
  if (allPending) head.appendChild(el("span", "pt-chip pend", "pending (yours)"));
  const first = t.comments[0];
  const folded = t.resolved && !prThreadsShown.has(t.id);
  if (folded && first) {
    const peek = el("span", "pt-peek", `<b>${esc(first.author)}</b> ${esc(first.body.split("\n")[0])}`);
    peek.title = "Show the resolved thread";
    peek.onclick = () => { prThreadsShown.add(t.id); rerenderPrThread(t); };
    head.appendChild(peek);
  } else {
    head.appendChild(el("span", "grow", ""));
  }
  if (t.resolved && !folded) {
    const fold = el("button", "pt-btn", "Fold");
    fold.onclick = () => { prThreadsShown.delete(t.id); rerenderPrThread(t); };
    head.appendChild(fold);
  }
  const reply = prReplyDraft(t);
  if (t.canReply && !reply && !prReplyEditing.has(t.id)) {
    const b = el("button", "pt-btn", "Reply");
    b.title = "Draft a reply — it posts with your pending review";
    b.onclick = () => { prThreadsShown.add(t.id); prReplyEditing.set(t.id, ""); rerenderPrThread(t, true); };
    head.appendChild(b);
  }
  if (t.resolved ? t.canUnresolve : t.canResolve) {
    const b = el("button", "pt-btn", t.resolved ? "Unresolve" : "Resolve");
    b.title = t.resolved ? "Reopen the thread on GitHub now" : "Resolve the thread on GitHub now";
    b.onclick = () => setPrThreadResolved(t, !t.resolved, b);
    head.appendChild(b);
  }
  if (first && first.url) {
    const link = el("a", "pt-link", "↗");
    link.href = first.url;
    link.target = "_blank";
    link.rel = "noopener";
    link.title = "Open the thread on GitHub";
    head.appendChild(link);
  }
  box.appendChild(head);
  if (folded) return box;
  t.comments.forEach(c => {
    const comment = el("div", "pt-comment" + (c.pending ? " pending" : ""));
    comment.appendChild(el("div", "pt-meta", `<b>${esc(c.author)}</b> · ${esc(agoText(c.createdAt))}` +
      (c.pending && !allPending ? ' <span class="pt-chip pend">pending (yours)</span>' : "")));
    comment.lastChild.title = c.createdAt || "";
    comment.appendChild(el("div", "pt-body", esc(c.body)));
    box.appendChild(comment);
  });
  if (prReplyEditing.has(t.id)) box.appendChild(prReplyEditor(t, reply));
  else if (reply) {
    const mine = el("div", "pt-reply");
    mine.appendChild(el("div", "pt-meta", "your reply · draft, posts with the pending review"));
    const text = el("div", "pt-body", esc(reply.comment));
    text.title = "Edit the reply";
    text.onclick = () => { prReplyEditing.set(t.id, reply.comment); rerenderPrThread(t, true); };
    mine.appendChild(text);
    box.appendChild(mine);
  }
  return box;
}

function prReplyEditor(t, reply) {
  const wrap = el("div", "pt-reply editing");
  const input = el("textarea", "d-comment-input");
  input.rows = 3;
  input.placeholder = "Reply — ⌘⏎ saves a draft (it posts with your pending review), Esc cancels";
  input.value = prReplyEditing.get(t.id) || "";
  input.addEventListener("input", () => prReplyEditing.set(t.id, input.value));
  const save = () => { prReplyEditing.delete(t.id); putPrReply(t, input.value); rerenderPrThread(t); };
  const cancel = () => { prReplyEditing.delete(t.id); rerenderPrThread(t); };
  input.addEventListener("keydown", e => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancel(); }
  });
  const acts = el("div", "d-comment-acts");
  const ok = el("button", "primary", "Save reply");
  ok.onclick = save;
  const no = el("button", "", "Cancel");
  no.onclick = cancel;
  acts.append(ok, no);
  if (reply) {
    const del = el("button", "danger", "Delete");
    del.onclick = () => { prReplyEditing.delete(t.id); putPrReply(t, ""); rerenderPrThread(t); };
    acts.appendChild(del);
  }
  wrap.append(input, acts);
  return wrap;
}

const prReplyDraft = t => itemDrafts().find(d => isThreadReply(d) && d.thread === t.id) || null;

/* Saved at once on the page, confirmed by the action's refresh. */
function putPrReply(t, comment) {
  const slug = chatSlug;
  const pr = diffView.data.pr;
  const fields = { thread: t.id, repo: pr.repo, number: pr.number, url: pr.url, path: t.path,
                   line: t.line != null ? t.line : t.originalLine };
  patchLocalDrafts(slug, drafts => {
    const old = drafts.find(d => isThreadReply(d) && d.thread === t.id);
    const rest = drafts.filter(d => d !== old);
    return comment.trim() ? rest.concat([{ id: `pending:${t.id}`, ...(old || {}), kind: "thread-reply", ...fields, comment }]) : rest;
  });
  return draftAction("thread-reply-put", slug, { ...fields, comment });
}

/* Swaps one thread's box in place, wherever it shows. */
function rerenderPrThread(t, focus = false) {
  document.querySelectorAll(`#diff-body .pr-thread[data-thread="${CSS.escape(t.id)}"]`).forEach(box => {
    const fresh = renderPrThread(t);
    box.replaceWith(fresh);
    const input = focus && fresh.querySelector("textarea");
    if (input) setTimeout(() => input.focus(), 0);
  });
  diffView.drafts = diffDraftsShown();
  draftsChanged();
}

async function setPrThreadResolved(t, resolve, button) {
  const pr = diffView.data && diffView.data.pr;
  if (!pr) return;
  button.disabled = true;
  button.textContent = resolve ? "resolving…" : "reopening…";
  const res = await act("pr-thread-resolve", { slug: chatSlug, args: { repo: pr.repo, number: pr.number, thread: t.id, resolve } });
  if (res.ok) {
    t.resolved = res.resolved;
    if (resolve) prThreadsShown.delete(t.id);
    rerenderPrThread(t);
    loadPrThreads(true);
  } else {
    rerenderPrThread(t);
  }
}

/* From the tray: the reply's thread, unfolded and flashed. */
function revealPrThread(d) {
  const box = document.querySelector(`#diff-body .pr-thread[data-thread="${CSS.escape(d.thread)}"]`);
  if (!box) {
    toast(`That thread is on ${d.repo.split("/").pop()}#${d.number} — open the PR scope (all commits) to see it`, false);
    return;
  }
  const file = box.closest("details.diff-file");
  if (file) file.open = true;
  const group = box.closest("details.pt-off");
  if (group) group.open = true;
  const row = box.closest("tr.d-thread");
  if (row) showDiffRow(row);
  flashDiffTarget(box, "center");
}
