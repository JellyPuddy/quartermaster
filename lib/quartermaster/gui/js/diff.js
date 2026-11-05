"use strict";

/* ------- diff pane: the chat's branch against its base, beside the terminal ------- */
/* Open/closed is remembered per chat, fullscreen per browser tab like Maximize.
   The diff is fetched when the pane opens, when the chat changes, when the
   chat's turn ends (claude may have just edited files) and on ↻ — never on
   every state refresh. */
let diffOpen = false;
let diffMax = false;
let sidePanes = {};      // slug → "diff" | "issues": what sits beside that chat
let sidePaneSlug = null; // the chat diffOpen and issuesOpen currently describe
const DIFF_VIEW_MODES = [
  ["diff", "Diff", "Both sides: removed and added lines"],
  ["old", "Old", "Only the old code: context and removed lines"],
  ["new", "New", "Only the new code: context and added lines"],
];
let diffViewMode = "diff"; // remembered per tab, like Full
try {
  diffMax = sessionStorage.getItem("qm-diff-max") === "1";
  const mode = sessionStorage.getItem("qm-diff-view");
  if (DIFF_VIEW_MODES.some(([k]) => k === mode)) diffViewMode = mode;
  sidePanes = JSON.parse(sessionStorage.getItem("qm-side-panes") || "{}") || {};
} catch (e) { /* storage blocked or garbled: every pane closed */ }
const diffChoice = {};   // slug → { scope, from, to, anchor, prompt, moved, rebase } picked in the bar and commit list; the branch is the item's selected one (stacks.js)
let diffView = { slug: null, key: null, data: null, loading: false, error: null, turn: null };
const DIFF_FOLD_LINES = 400; // files longer than this start collapsed
const DIFF_FOLD_PATH = /(^|\/)__generated__\//; // generated code starts collapsed too

function remember(key, on) {
  try { sessionStorage.setItem(key, on ? "1" : "0"); } catch (e) { /* not remembered */ }
}

/* On a chat switch, the diff and issues flags take that chat's remembered pane. */
function adoptSidePane() {
  if (chatSlug === sidePaneSlug) return;
  sidePaneSlug = chatSlug;
  diffOpen = sidePanes[chatSlug] === "diff";
  issuesOpen = sidePanes[chatSlug] === "issues";
}

function rememberSidePane() {
  if (!chatSlug) return;
  if (diffOpen) sidePanes[chatSlug] = "diff";
  else if (issuesOpen) sidePanes[chatSlug] = "issues";
  else delete sidePanes[chatSlug];
  try { sessionStorage.setItem("qm-side-panes", JSON.stringify(sidePanes)); } catch (e) { /* not remembered */ }
}

function toggleDiff() {
  diffOpen = !diffOpen;
  rememberSidePane();
  if (diffOpen) { diffView.key = null; diffCache.clear(); diffContextFiles.clear(); } // what was loaded before may be stale by now
  if (diffOpen && issuesOpen) setIssuesOpen(false); // the two share the slot beside the chat
  syncDiffPane();
}

function toggleDiffMax() {
  if (!diffOpen) return;
  diffMax = !diffMax;
  remember("qm-diff-max", diffMax);
  applyDiffLayout();
}

function applyDiffLayout() {
  const shown = diffOpen && mode === "chat" && !!chatSlug;
  $("#diff-pane").hidden = !shown;
  document.body.classList.toggle("diff-open", shown);
  document.body.classList.toggle("diff-max", shown && diffMax);
  document.querySelectorAll("#chat-main .act.diff-toggle").forEach(b => b.setAttribute("aria-pressed", String(shown)));
  const max = $("#diff-max-btn");
  if (max) {
    max.setAttribute("aria-pressed", String(diffMax));
    max.textContent = diffMax ? "⤡ Restore" : "⤢ Full";
  }
}

/* Called after every chat render: refetch only when what the pane shows is
   no longer what it should show. */
function syncDiffPane() {
  applyDiffLayout();
  draftsChanged();
  if (!diffOpen || mode !== "chat" || !chatSlug) return;
  const key = diffKey(chatSlug);
  const a = attention.find(x => x.slug === chatSlug);
  const turn = a ? a.state : "none";
  const turnEnded = diffView.slug === chatSlug && diffView.turn === "working" && turn !== "working";
  diffView.turn = turn;
  if (key !== diffView.key || turnEnded) loadDiff(false, turnEnded);
}

/* What the pane should show for this item: branch (the item's selected
   one, diffBranchFor), scope and, under
   Commits, the selected run of commits (from..to, both inclusive), under
   Since prompt the picked prompt (none: the last one), moved branch
   (none: the chat's folder), whether a rebase's changes show ("show";
   none: hidden), and a stack span's lower end (base, diff-stack.js). */
function diffKey(slug, c = diffChoice[slug] || {}) {
  return `${slug}|${diffBranchFor(slug) || ""}|${c.scope || "branch"}|${c.from || ""}..${c.to || ""}|${c.prompt || ""}|${c.moved || ""}|${c.rebase || ""}|${diffSpanBase(c) || ""}`;
}

/* fresh: ↻ — the PR scope's review threads skip the server's brief cache too.
   refetch: the PR scope looks its PR up and fetches it anew (fresh=1) instead
   of reusing the server's last minute (PrMemo) — on ↻, at a turn's end and
   when the pane comes to the PR scope (opened, another item or scope before,
   or the last load still running); not when only the selected commits or
   branch change within it. A selected commit's diff kept in diffCache (or
   being prefetched) is shown without asking the server again. */
async function loadDiff(fresh = false, refetch = fresh) {
  const slug = chatSlug;
  const choice = diffChoice[slug] || {};
  const key = diffKey(slug);
  if (refetch || diffView.slug !== slug) diffCache.clear(); // ↻, a turn's end, another chat: kept diffs may be stale
  else if (key === diffView.key) diffCache.delete(key); // reloading what is shown (a draft placed, a review posted): ask again
  if (fresh || diffView.slug !== slug) diffContextFiles.clear(); // a file at a sha can't change: kept until ↻ or another chat
  const inPrScope = diffView.slug === slug && diffView.key !== null && !diffView.loading && !!diffView.data && diffView.data.scope === "pr";
  const params = diffParams(slug, choice);
  // No scope chosen: the server may pick PR (a Review item).
  const mayBePr = !choice.scope || choice.scope === "pr";
  if (mayBePr && (refetch || !inPrScope)) params.set("fresh", "1");
  const kept = diffCacheGet(key);
  if (diffView.slug !== slug) diffView.data = null;
  Object.assign(diffView, { slug, key, loading: !(kept && kept.res), error: null });
  if (diffView.loading) showDiffLoading();
  let res;
  if (kept) res = kept.res || await kept.promise;
  else {
    const request = fetchDiff(slug, params);
    if (diffKeepable(choice)) diffCachePut(key, request);
    res = await request;
  }
  if (diffView.key !== key) return; // the pane moved on while this was loading
  diffView.loading = false;
  if (res.ok) diffView.data = res; else { diffView.error = res.error || "diff failed"; diffView.data = null; }
  renderDiffPane();
  if (res.ok) loadPrThreads(fresh);
  if (res.ok) prefetchNextDiff();
  // The PR scope re-anchored drafts a push moved (ReviewPlan): fetch them.
  if (res.ok && Object.values(res.reviewRoutes || {}).some(r => r.moved)) { await refresh(); draftsChanged(); }
}

/* What the server needs to build the diff a choice describes. */
function diffParams(slug, choice) {
  const params = new URLSearchParams();
  const branch = diffBranchFor(slug);
  if (branch) params.set("branch", branch);
  if (choice.scope) params.set("scope", choice.scope);
  if (diffHasCommitList(choice.scope) && choice.from) { params.set("from", choice.from); params.set("to", choice.to); }
  if (diffSpanBase(choice)) params.set("base", diffSpanBase(choice));
  if (choice.scope === "prompt" && choice.prompt) params.set("prompt", choice.prompt);
  if (choice.scope === "prompt" && choice.moved) params.set("moved", choice.moved);
  if (choice.scope === "prompt" && choice.rebase) params.set("rebase", choice.rebase);
  return params;
}

async function fetchDiff(slug, params) {
  try {
    return await (await fetch(`/api/diff/${encodeURIComponent(slug)}?${params}`)).json();
  } catch (e) { return { ok: false, error: "could not reach qm" }; }
}

/* While a load runs the old diff stays put, dimmed, and only the bar says
   loading…: rebuilding every row of a long diff just to say so cost as
   much as showing the new one. Nothing shown yet, or an error: the body
   says loading. */
function showDiffLoading() {
  if (!diffView.data || diffView.rendered !== diffView.data) { renderDiffPane(); return; }
  renderDiffBar();
  $("#diff-body").classList.add("d-stale");
}

function renderDiffPane() {
  renderDiffBar();
  renderDiffTray();
  renderDiffNav();
  const body = $("#diff-body");
  body.classList.toggle("d-stale", diffView.loading && !!diffView.data);
  const editing = [...body.querySelectorAll("tr.d-comment textarea")].map(t => [t.closest("tr").dataset.key, t.value, t.closest("tr").diffAddress]);
  const annotEditing = [...body.querySelectorAll("tr.d-annot textarea")].map(t => [t.closest("tr").dataset.id, t.value]);
  diffView.drafts = diffDraftsShown();
  const d = diffView.data;
  // Re-rendering the same diff (a draft saved) keeps each file folded or
  // opened as it was: a viewed file opened to comment on must stay open.
  const folds = diffView.rendered === d
    ? new Map([...body.querySelectorAll("details.diff-file")].map(box => [box.dataset.path, box.open])) : new Map();
  diffView.rendered = d;
  keepScroll(body, () => {
    body.innerHTML = "";
    if (diffView.error) {
      body.appendChild(el("div", "diff-empty", esc(diffView.error)));
      // A selected commit can leave the branch (rebase, amend): offer the way back.
      if ((diffChoice[chatSlug] || {}).from) {
        const all = el("button", "diff-clear", "Show all commits");
        all.onclick = () => selectDiffCommits(null);
        body.lastChild.appendChild(el("div", "", "")).appendChild(all);
      }
      return;
    }
    if (!d) { body.appendChild(el("div", "diff-empty", "loading diff…")); return; }
    const stacked = d.layers && d.layers.length && items.find(i => i.slug === diffView.slug);
    if (diffHasCommitList(d.scope)) body.appendChild(stacked ? renderLayeredCommits(d, stacked) : renderDiffCommits(d));
    if (diffHasCommitList(d.scope) && (d.messages || []).length) body.appendChild(renderDiffMessages(d.messages));
    if (d.notice) { body.appendChild(el("div", "diff-empty", esc(d.notice))); return; }
    if (d.rebaseNotice) body.appendChild(el("div", "diff-note", esc(d.rebaseNotice)));
    if (!d.files.length) {
      const empty = d.scope === "uncommitted" ? "Nothing uncommitted."
        : d.scope === "prompt" ? "Nothing changed since this prompt."
        : d.scope === "commits" && !d.commits.length ? "No commits on this branch yet."
        : d.scope === "pr" && !d.range ? "This pull request changes no files."
        : d.range ? "These commits change no files." : "No changes against the base.";
      body.appendChild(el("div", "diff-empty", empty));
      const next = renderDiffNextCommit(d);
      if (next) body.appendChild(next);
      return;
    }
    if (d.truncated) body.appendChild(el("div", "diff-note", `The diff is long: lines past the first ${d.lineLimit.toLocaleString()} are left out (stats still count).`));
    const elsewhere = prThreadsElsewhere(d);
    if (elsewhere) body.appendChild(elsewhere);
    const anchors = diffAnchors();
    d.files.forEach((f, i) => {
      const box = body.appendChild(renderDiffFile(f, i, anchors));
      if (!folds.has(f.path)) return;
      box.open = folds.get(f.path);
      if (box.open && box.fillRows) box.fillRows(); // now, so a comment being written finds its row
    });
    const next = renderDiffNextCommit(d);
    if (next) body.appendChild(next);
    editing.forEach(([key, value, address]) => reopenDiffComment(key, value, address));
    annotEditing.forEach(([id, value]) => reopenDiffAnnotation(id, value));
  });
}

function diffTotals(files) {
  return files.reduce((t, f) => ({ add: t.add + f.additions, del: t.del + f.deletions }), { add: 0, del: 0 });
}

function diffStat(add, del) {
  return `<span class="d-add">+${add}</span> <span class="d-del">−${del}</span>`;
}

/* Two rows, so a narrow pane wraps by purpose rather than wherever it runs
   out: what is reviewed (branch, prompt, file) with the pane's own buttons
   top right, then how (scope, view mode) and the summary. */
function renderDiffBar() {
  const bar = $("#diff-bar");
  bar.innerHTML = "";
  const top = el("div", "diff-bar-row");
  const how = el("div", "diff-bar-row");
  bar.append(top, how);
  top.appendChild(el("span", "tag", "DIFF"));
  const d = diffView.data;
  const choice = diffChoice[chatSlug] || {};
  const stacked = items.find(i => i.slug === chatSlug);
  if (itemChains(stacked).length) top.appendChild(renderDiffStrip(d, stacked));
  else if (d && d.branches.length) {
    const pick = el("select", "diff-branch");
    pick.title = "Which of the item's branches to review — one not checked out anywhere shows only its commits";
    d.branches.forEach(b => {
      const o = el("option", "", esc((b.branch || "detached HEAD") + (b.chat ? " · chat" : b.checkout === false ? " · not checked out" : "")));
      o.value = b.branch || "";
      o.selected = b.branch === d.branch;
      pick.appendChild(o);
    });
    // The item's one selected branch: the side panel's rails follow.
    pick.onchange = () => setSelectedBranch(chatSlug, pick.value || null);
    top.appendChild(pick);
  }
  if (d && d.scope === "prompt" && d.prompts.length) top.appendChild(renderDiffPrompts(d));
  if (d && d.scope === "prompt" && d.movedBranches.length) top.appendChild(renderDiffMoved(d));
  if (d && d.scope === "prompt" && d.rebase) top.appendChild(renderDiffRebase(d));
  if (d && d.files.length) top.appendChild(renderDiffJump(d));
  const scope = el("div", "diff-scope");
  // The server picks the scope when none is chosen (a Review item opens on PR).
  const current = choice.scope || (d && d.scope) || "branch";
  // PR only when the branch has an open PR (or a Review item's own PR).
  const offerPr = current === "pr" || (d && d.prAvailable);
  DIFF_SCOPES.filter(([k]) => k !== "pr" || offerPr).forEach(([k, label, title]) => {
    const b = el("button", "", label);
    b.setAttribute("aria-pressed", String(current === k));
    b.title = title;
    if (d && d.checkout === false && k === "branch") b.title = `Committed work since the base — ${d.branch} is not checked out anywhere, so nothing uncommitted`;
    if (d && d.checkout === false && diffNeedsCheckout(k)) {
      b.disabled = true;
      b.title = `${d.branch} is not checked out anywhere — needs a checkout`;
    }
    // A stack span holds across Branch and Commits; no other scope can show one.
    b.onclick = () => { diffChoice[chatSlug] = { scope: k, rebase: choice.rebase, base: choice.base }; loadDiff(); };
    scope.appendChild(b);
  });
  how.appendChild(scope);
  how.appendChild(renderDiffViewModes());
  const info = el("span", "grow", "");
  if (d) {
    const base = d.scope === "uncommitted" ? "vs HEAD"
      : d.scope === "prompt" ? (d.movedBranch ? `${esc(d.movedBranch)} since prompt` : "since prompt")
      : d.range ? `${d.range.from === d.range.to ? "commit" : "commits"} ${esc(d.range.label)}`
      : `vs ${esc(d.base.ref)}${d.base.kind === "stack" ? " (stack parent)" : d.base.kind === "stack-span" ? " (stack span)" : ""}`;
    const pr = d.scope === "pr" && d.pr
      ? `<a href="${esc(d.pr.url)}" target="_blank" rel="noopener" title="${esc(d.pr.title || "")}">${esc(diffPrLabel(d.pr))}</a> · ` : "";
    const t = diffTotals(d.files);
    info.innerHTML = `${pr}${base} · ${d.files.length} file${d.files.length === 1 ? "" : "s"} ${diffStat(t.add, t.del)}${prThreadsNote(d)}`;
    if (d.files.length) info.innerHTML += ` · <span class="d-viewed-count">${diffViewedCount(d.files)}</span>`;
    info.title = d.checkout === false ? `${diffBranchEntry(d, d.branch).ref || d.branch} — not checked out anywhere` : d.short || "";
  }
  if (diffView.loading) info.innerHTML += ' <span class="d-busy">loading…</span>';
  how.appendChild(info);
  if (d && d.scope === "branch" && d.checkout !== false && diffHasUncommittedLines(d)) {
    const legend = el("span", "d-unc-legend", '<span class="d-unc-swatch"></span>uncommitted');
    legend.title = "Lines with this bar in their gutter are not committed yet";
    how.appendChild(legend);
  }
  const reload = el("button", "", "↻");
  reload.title = "Reload the diff";
  reload.onclick = () => loadDiff(true);
  const max = el("button", "max-btn", "");
  max.id = "diff-max-btn";
  max.title = "Fill the page with the diff (⇧D)";
  max.onclick = toggleDiffMax;
  const close = el("button", "", "✕");
  close.title = "Close the diff (d)";
  close.onclick = toggleDiff;
  const pane = el("span", "diff-bar-pane");
  const branch = d && d.branch;
  const stats = branchStatsButton(diffView.slug, branch);
  if (stats) pane.appendChild(stats);
  const bench = benchmarkButton(items.find(i => i.slug === diffView.slug), branch);
  if (bench) pane.appendChild(bench);
  pane.append(reload, max, close);
  top.appendChild(pane);
  applyDiffLayout();
}

/* Diff / Old / New: a class on the body and CSS hide the other side's
   lines, so a switch neither refetches nor rebuilds a row. Rows under a
   line (comments, annotations, threads) hide with it by their data-side. */
function renderDiffViewModes() {
  const group = el("div", "diff-scope diff-view");
  DIFF_VIEW_MODES.forEach(([k, label, title]) => {
    const b = el("button", "", label);
    b.setAttribute("aria-pressed", String(diffViewMode === k));
    b.title = title;
    b.onclick = () => setDiffViewMode(k);
    group.appendChild(b);
  });
  applyDiffViewMode();
  return group;
}

function setDiffViewMode(mode) {
  diffViewMode = mode;
  try { sessionStorage.setItem("qm-diff-view", mode); } catch (e) { /* not remembered */ }
  document.querySelectorAll("#diff-bar .diff-view button").forEach((b, i) =>
    b.setAttribute("aria-pressed", String(DIFF_VIEW_MODES[i][0] === mode)));
  applyDiffViewMode();
}

function applyDiffViewMode() {
  const body = $("#diff-body");
  body.classList.toggle("d-only-old", diffViewMode === "old");
  body.classList.toggle("d-only-new", diffViewMode === "new");
  body.querySelectorAll(".diff-table > tbody").forEach(markDiffRowSides);
}

/* Each row under a line takes the side its line is on: "old" under a
   removed line, "new" under an added one, none under context. Walked on a
   mode switch too, so an editor opened since is marked before it hides. */
function markDiffRowSides(tbody) {
  let side = "";
  for (const tr of tbody.children) {
    if (tr.classList.contains("d-line")) side = tr.dataset.kind === "del" ? "old" : tr.dataset.kind === "add" ? "new" : "";
    else if (tr.classList.contains("d-hunk") || tr.classList.contains("d-expand")) side = "";
    else if (side) tr.dataset.side = side;
    else delete tr.dataset.side;
  }
}

/* A comment the view mode hides is revealed in Diff. */
function showDiffRow(row) {
  if (row.dataset.side && diffViewMode !== "diff" && row.dataset.side !== diffViewMode) setDiffViewMode("diff");
}
