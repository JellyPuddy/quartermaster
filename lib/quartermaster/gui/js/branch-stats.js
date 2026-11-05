"use strict";

/* ------- branch stats (the diff pane's 📊) -------
   Lines the diff's branch changes since its base, from the server's run of
   the branch-stats skill's script (GET /api/branch-stats/<slug>): totals, a
   category share bar, the largest files and one row per commit. The server
   caches an answer per branch head; ↻ refresh asks it to recompute.
   ✨ What stands out starts a background job (haiku); its finish arrives
   through jobFinished, and an open modal for that branch fetches again. */
let branchStats = null; // the open modal: { slug, branch, data, loading, asking }

/* 📊 for item slug's branch, on the diff bar and the rail's selected node:
   only for a branch. */
function branchStatsButton(slug, branch) {
  if (!slug || !branch) return null;
  const b = el("button", "", "📊");
  b.title = `Branch stats: lines ${branch} changes, by category and commit`;
  b.onclick = () => openBranchStats(slug, branch);
  return b;
}

function openBranchStats(slug, branch) {
  branchStats = { slug, branch, data: null, loading: true, asking: false };
  modal(m => { m.className = "modal branch-stats"; });
  const view = branchStats;
  openModal.onClose = () => { if (branchStats === view) branchStats = null; };
  renderBranchStats();
  loadBranchStats(false);
}

async function loadBranchStats(refresh) {
  const view = branchStats;
  if (!view) return;
  view.loading = true;
  renderBranchStats();
  const params = new URLSearchParams({ branch: view.branch });
  if (refresh) params.set("refresh", "1");
  let res;
  try {
    res = await (await fetch(`/api/branch-stats/${encodeURIComponent(view.slug)}?${params}`)).json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  if (branchStats !== view) return; // closed, or another branch's opened meanwhile
  Object.assign(view, { data: res, loading: false, asking: false });
  renderBranchStats();
}

/* From jobFinished: the commentary job of the shown branch is done. */
function branchStatsJobFinished(r) {
  if (branchStats && branchStats.data && r.key === branchStats.data.jobKey) loadBranchStats(false);
}

function askBranchStats() {
  const view = branchStats;
  view.asking = true;
  renderBranchStats();
  act("branch-stats-commentary", { slug: view.slug, args: { branch: view.branch } }).then(r => {
    if (!r.ok && branchStats === view) { view.asking = false; renderBranchStats(); }
  });
}

function branchStatsThinking(view) {
  const d = view.data;
  return view.asking || !!(d && (d.commentaryRunning || jobFor(d.jobKey)));
}

function renderBranchStats() {
  const view = branchStats;
  const m = view && openModal && openModal.querySelector(".modal.branch-stats");
  if (!m) return;
  const d = view.data && view.data.ok ? view.data : null;
  m.innerHTML = "";
  const vs = d ? `${d.branch} vs ${d.base}` : view.branch;
  m.appendChild(el("h2", "", `Branch stats <span class="bs-vs">${esc(vs)}</span>`));
  m.appendChild(el("p", "sub", branchStatsMeta(view, d)));
  const body = el("div", "bs-body" + (view.loading && d ? " bs-stale" : ""));
  m.appendChild(body);
  if (!view.data) body.appendChild(el("p", "bs-wait", "running the branch-stats script…"));
  else if (!d || d.error) body.appendChild(el("pre", "bs-error", esc((d ? d.error : view.data.error) || "branch stats failed")));
  else if (!d.stats) {
    const callout = branchStatsCallout(view, d);
    if (callout) body.appendChild(callout);
    body.insertAdjacentHTML("beforeend", branchStatsMarkdown(d.markdown));
  } else renderBranchStatsPicture(body, view, d);
  m.appendChild(branchStatsActions(view, d));
}

function branchStatsMeta(view, d) {
  if (!d || !d.head) return view.loading ? "computing…" : "";
  const at = `at <code>${esc(d.head.slice(0, 7))}</code> · merge base <code>${esc((d.mergeBase || "").slice(0, 7))}</code>`;
  if (view.loading) return `${at} · recomputing…`;
  return d.computedAt ? `${at} · computed ${esc(agoText(d.computedAt))}` : at;
}

/* Markdown the page didn't parse, or the commentary: raw HTML escaped. */
function branchStatsMarkdown(md) {
  const marked = issueMarkdown();
  return marked ? marked.parse(md || "") : `<pre>${esc(md)}</pre>`;
}

const branchStatsCat = name => `bs-c bs-c-${String(name).replace(/[^a-z]/g, "")}`;
const branchStatsLines = (add, del) => `+${add} <em>−${del}</em>`;

function renderBranchStatsPicture(body, view, d) {
  const s = d.stats;
  body.insertAdjacentHTML("beforeend", `<div class="bs-totals">
    <div><b>${s.totals.files}</b><small>files</small></div>
    <div class="bs-add"><b>+${s.totals.add}</b><small>added</small></div>
    <div class="bs-del"><b>−${s.totals.del}</b><small>removed</small></div></div>`);
  body.insertAdjacentHTML("beforeend", `<div class="bs-share">${s.categories.filter(c => c.add).map(c =>
    `<span class="${branchStatsCat(c.name)}" style="flex:${c.add}" title="${esc(c.name)} +${c.add} (${c.share}%)"></span>`).join("")}</div>`);
  body.insertAdjacentHTML("beforeend", `<div class="bs-legend">${s.categories.map(c =>
    `<span><i class="${branchStatsCat(c.name)}"></i>${esc(c.name)} <b>+${c.add}</b> <em>−${c.del}</em> · ${c.files}f</span>`).join("")}</div>`);
  const callout = branchStatsCallout(view, d);
  if (callout) body.appendChild(callout);
  else { const row = el("div", "bs-ask-row"); row.appendChild(branchStatsAskButton(view, d)); body.appendChild(row); }
  const max = Math.max(1, ...s.largest.map(f => f.add));
  body.insertAdjacentHTML("beforeend", `<h3>Largest files</h3><div>${s.largest.map(f =>
    `<div class="bs-row bs-file"><span class="bs-name" title="${esc(f.path)}">${esc(f.path)}</span>
      <span class="bs-n">${branchStatsLines(f.add, f.del)}</span>${branchStatsBar(f.add, max)}</div>`).join("")}</div>`);
  const cmax = Math.max(1, ...s.commits.map(c => c.add));
  body.insertAdjacentHTML("beforeend", `<h3>Per commit</h3><div>${s.commits.map(c =>
    `<div class="bs-row bs-commit"><code>${esc(c.sha)}</code><span class="bs-name" title="${esc(c.subject)}">${esc(c.subject)}</span>
      <span class="bs-n">${branchStatsLines(c.add, c.del)}</span>${branchStatsBar(c.add, cmax)}</div>`).join("")}</div>`);
}

/* The commentary, or that haiku is still writing it; null when neither. */
function branchStatsCallout(view, d) {
  if (branchStatsThinking(view)) return el("div", "bs-callout", "<em>Haiku is reading the tables…</em>");
  return d.commentary ? el("div", "bs-callout", branchStatsMarkdown(d.commentary)) : null;
}

const branchStatsBar = (add, max) => `<span class="bs-bar"><span style="width:${(100 * add / max).toFixed(1)}%"></span></span>`;

function branchStatsAskButton(view, d) {
  const thinking = branchStatsThinking(view);
  const b = el("button", "btn", thinking ? "✨ thinking…" : d.commentary ? "✨ ask again" : "✨ What stands out");
  b.disabled = thinking || view.loading;
  b.title = "Haiku reads the tables and writes two or three sentences on what stands out";
  b.onclick = askBranchStats;
  return b;
}

function branchStatsActions(view, d) {
  const bar = el("div", "modal-actions");
  const refresh = el("button", "btn", "↻ refresh");
  refresh.title = "Run the script again, ignoring the cached answer (drops the commentary)";
  refresh.disabled = view.loading;
  refresh.onclick = () => loadBranchStats(true);
  bar.appendChild(refresh);
  if (d && !d.error && d.markdown) bar.appendChild(branchStatsAskButton(view, d));
  const close = el("button", "btn", "Close");
  close.onclick = closeModal;
  bar.appendChild(close);
  return bar;
}
