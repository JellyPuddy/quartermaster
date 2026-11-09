"use strict";

/* ------- benchmark (the diff pane's 🏁) -------
   Measures a branch against main on its project's benchmark database
   (docs/areas/benchmarks.md). The modal reads GET /api/benchmark/<slug>:
   a start view (what to benchmark, model) and a run view (verdict, the
   live table, the plan). It polls every 2 s while open and the run isn't
   final; closing never stops a run, reopening shows the newest one. */
let bench = null; // the open modal: { slug, branch, run, mode, data, form, starting, plan, foldOpen, logsOpen, log, timer }
let benchmarkDoneSeen = "null"; // the diff branch's finished run as noticeBenchmarkBusy last saw it

const BENCH_FINAL = ["done", "failed", "cancelled"];
const BENCH_GREY_PCT = 40; // timings move 20–40% between runs: a smaller Δ is noise
const BENCH_TIMEOUT_MS = 60000;
const BENCH_STEPS = { planning: "planning the cases", measuring: "measuring", verdict: "writing the verdict" };

/* 🏁 for item it's branch, on the diff bar and the rail's selected node: a
   benchmarkable item only (its project configures benchmarks). A live run of the branch
   pulses, another live run dims it; otherwise a dot marks a finished run
   (the state's benchmarked). */
function benchmarkButton(it, branch) {
  if (!it || !it.benchmarkable || !branch) return null;
  const busy = benchmarkBusy;
  const mine = busy && busy.slug === it.slug && busy.branch === branch;
  const done = !mine && (it.benchmarked || {})[branch];
  const b = el("button", busy ? (mine ? "bm-btn-running" : "bm-btn-busy") : "", "🏁");
  if (done) b.classList.add("bm-btn-done");
  b.title = mine ? `Benchmark of ${branch}: ${BENCH_STEPS[busy.state] || busy.state}…`
    : busy ? `Benchmark ${branch} against main (busy: ${busy.branch})`
    : done ? `Benchmarked ${agoText(done.finishedAt) || "earlier"} — open for the results`
    : `Benchmark ${branch} against main on the benchmark database`;
  b.onclick = () => openBenchmark(it.slug, branch);
  return b;
}

/* The state's busy run and the diff's branch's finished run; a refresh
   doesn't rebuild the diff bar, so a change (started, next step, finished)
   does, for 🏁's pulse, dimming, dot and title. The rail is rebuilt by every
   state render. */
function noticeBenchmarkBusy(busy) {
  const it = diffView.slug && items.find(i => i.slug === diffView.slug);
  const branch = diffView.data && diffView.data.branch;
  const done = JSON.stringify(it && branch ? (it.benchmarked || {})[branch] || null : null);
  const changed = JSON.stringify(busy) !== JSON.stringify(benchmarkBusy) || done !== benchmarkDoneSeen;
  benchmarkBusy = busy;
  benchmarkDoneSeen = done;
  if (changed && diffOpen && diffView.data) renderDiffBar();
}

/* run: a run id to show (the busy link, the picker); else the newest. */
function openBenchmark(slug, branch, run = null) {
  modal(m => { m.className = "modal benchmark"; });
  const view = bench = { slug, branch, run, mode: null, data: null, form: { request: "", model: "opus" },
    starting: false, plan: null, foldOpen: false, logsOpen: null, log: null, timer: null };
  openModal.onClose = () => { clearTimeout(view.timer); if (bench === view) bench = null; };
  renderBenchmark();
  loadBenchmark();
}

async function loadBenchmark() {
  const view = bench;
  if (!view) return;
  clearTimeout(view.timer);
  const params = new URLSearchParams({ branch: view.branch });
  if (view.run) params.set("run", view.run);
  let res;
  try {
    res = await (await fetch(`/api/benchmark/${encodeURIComponent(view.slug)}?${params}`)).json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  if (bench !== view) return; // closed, or another opened meanwhile
  view.data = res;
  if (!view.mode) view.mode = res.ok && res.run ? "run" : "start";
  renderBenchmark();
  const run = res.ok && res.run;
  if (view.mode === "run" && (!res.ok || (run && !BENCH_FINAL.includes(run.state)))) view.timer = setTimeout(loadBenchmark, 2000);
}

function showBenchmarkRun(id) {
  Object.assign(bench, { run: id, mode: "run", plan: null, logsOpen: null });
  loadBenchmark();
}

function renderBenchmark() {
  const view = bench;
  const m = view && openModal && openModal.querySelector(".modal.benchmark");
  if (!m) return;
  const scroll = (m.querySelector(".bs-body") || {}).scrollTop || 0;
  const logScroll = (m.querySelector(".bm-log") || {}).scrollTop || 0;
  const tableScroll = (m.querySelector(".bm-table-wrap") || {}).scrollLeft || 0;
  const d = view.data && view.data.ok ? view.data : null;
  const run = d && view.mode === "run" ? d.run : null;
  m.innerHTML = "";
  const state = run ? ` <span class="bm-state bm-state-${esc(run.state)}">${esc(run.state)}</span>` : "";
  const branch = run ? run.branch : view.branch;
  m.appendChild(el("h2", "", `Benchmark <span class="bs-vs">${esc(branch)}</span>${state}`));
  m.appendChild(el("p", "sub", run ? benchmarkMeta(run) : "this branch vs main · the benchmark database"));
  const body = el("div", "bs-body");
  m.appendChild(body);
  if (!view.data) body.appendChild(el("p", "bs-wait", "loading…"));
  else if (!d) body.appendChild(el("pre", "bs-error", esc(view.data.error || "benchmark failed")));
  else if (run) renderBenchmarkRun(body, view, d, run);
  else renderBenchmarkStart(body, view, d);
  if (view.plan) m.appendChild(benchmarkPlanOverlay(view));
  m.appendChild(benchmarkActions(view, d, run));
  const pre = m.querySelector(".bm-log");
  if (pre) pre.scrollTop = logScroll;
  const wrap = m.querySelector(".bm-table-wrap");
  if (wrap) wrap.scrollLeft = tableScroll;
  body.scrollTop = scroll;
}

/* ---- start view ---- */

function renderBenchmarkStart(body, view, d) {
  if (!d.enabled) body.appendChild(el("p", "bs-error", "Benchmarks are off for this project: give it a benchmark: setting in config.yml."));
  const busy = benchmarkBusyElsewhere(view, d);
  if (busy) body.appendChild(benchmarkBusyLine(busy));
  const field = el("div", "field");
  field.appendChild(el("label", "", "What to benchmark"));
  const text = el("textarea", "");
  text.placeholder = "What to benchmark (empty: work it out from the branch's changes)";
  text.value = view.form.request;
  text.oninput = () => { view.form.request = text.value; };
  text.onkeydown = e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); startBenchmark(); } };
  field.appendChild(text);
  body.appendChild(field);
  const model = el("div", "field");
  model.appendChild(el("label", "", "Model that plans the cases"));
  const pick = el("div", "bm-models");
  [["opus", "Opus"], ["sonnet", "Sonnet"]].forEach(([key, label]) => {
    const b = el("button", "btn", label);
    b.setAttribute("aria-pressed", String(view.form.model === key));
    b.onclick = () => { view.form.model = key; renderBenchmark(); };
    pick.appendChild(b);
  });
  model.appendChild(pick);
  body.appendChild(model);
  setTimeout(() => { if (document.activeElement === document.body) text.focus(); });
}

/* The live run, when it isn't the one this modal shows. */
function benchmarkBusyElsewhere(view, d) {
  const busy = d && d.busy;
  return busy && !(d.run && d.run.id === busy.id && view.mode === "run") ? busy : null;
}

function benchmarkBusyLine(busy) {
  const line = el("p", "bm-busy", `busy: <a href="#">${esc(busy.branch)}</a> <small>(${esc(busy.slug)}, ${esc(BENCH_STEPS[busy.state] || busy.state)})</small> · one run at a time`);
  line.querySelector("a").onclick = e => { e.preventDefault(); openBenchmark(busy.slug, busy.branch, busy.id); };
  return line;
}

async function startBenchmark() {
  const view = bench;
  const d = view && view.data && view.data.ok ? view.data : null;
  if (!d || !d.enabled || view.starting || d.busy) return;
  view.starting = true;
  renderBenchmark();
  const r = await act("benchmark-start", { slug: view.slug, args: { branch: view.branch, request: view.form.request, model: view.form.model } });
  if (bench !== view) return;
  view.starting = false;
  if (r.ok) { view.form.request = ""; showBenchmarkRun(r.run); return; }
  if (r.busy) d.busy = r.busy;
  renderBenchmark();
}

/* ---- run view ---- */

function benchmarkMeta(run) {
  const parts = [`${esc(run.model || "?")}`];
  if (run.durationS != null) parts.push(benchmarkDuration(run.durationS));
  if (run.head) parts.push(`at <code>${esc(run.head.slice(0, 7))}</code>`);
  if (run.startedAt) parts.push(`started ${esc(agoText(run.startedAt))}`);
  if (run.rerunOf) parts.push(`re-run of ${esc(run.rerunOf)}`);
  return parts.join(" · ");
}

function benchmarkDuration(s) {
  const m = Math.floor(s / 60);
  return m ? `${m}m ${String(s % 60).padStart(2, "0")}s` : `${s}s`;
}

function renderBenchmarkRun(body, view, d, run) {
  const live = !BENCH_FINAL.includes(run.state);
  if (run.warning) body.appendChild(el("div", "bm-banner bm-warning", esc(run.warning)));
  if (run.stages && run.stages.length) {
    body.appendChild(el("div", "bm-stages", run.stages.map(s =>
      `<span class="bm-chip" title="${esc(s.ref || "")} @ ${esc(s.sha || "")}">${esc(s.name)} <code>${esc((s.sha || "").slice(0, 7))}</code></span>`).join("")));
  }
  if (run.moved) {
    body.appendChild(el("div", "bm-banner", `measured at <code>${esc(run.head.slice(0, 7))}</code>, branch has moved to <code>${esc((run.currentHead || "").slice(0, 7))}</code>`));
  }
  const busy = benchmarkBusyElsewhere(view, d);
  if (busy && !live) body.appendChild(benchmarkBusyLine(busy));
  if (run.state === "failed") body.appendChild(el("pre", "bs-error", esc(run.error || "the run failed")));
  if (run.state === "cancelled") body.appendChild(el("p", "bm-note", "Cancelled. The cases measured before stay below."));
  if (run.verdict) body.appendChild(el("div", "bs-callout", branchStatsMarkdown(run.verdict)));
  if (live) {
    const what = run.state === "planning" && run.activity ? `planning · ${esc(run.activity)}` : esc(BENCH_STEPS[run.state] || run.state);
    body.appendChild(el("div", "bm-activity", `<span class="bm-spin"></span><span>${what}…</span>`));
  }
  body.appendChild(benchmarkPlanFold(view, run));
  if (run.logs && run.logs.length) body.appendChild(benchmarkLogsFold(view, run));
  if (run.rows && run.rows.length) body.appendChild(benchmarkTable(view, run, live));
  else if (!live) body.appendChild(el("p", "bs-wait", "nothing was measured"));
}

/* The run's log files (GET /api/benchmark-log/<id>/<name>), one tab each;
   open by itself on a failed run until toggled. view.log: { run, name, text }. */
function benchmarkLogsFold(view, run) {
  const fold = el("details", "bm-fold bm-logs");
  fold.open = view.logsOpen != null ? view.logsOpen : run.state === "failed";
  const shown = () => view.log && view.log.run === run.id && run.logs.includes(view.log.name) ? view.log : null;
  const log = shown();
  const first = () => { if (bench === view && !shown()) openBenchmarkLog(run, run.logs[0]); };
  fold.ontoggle = () => {
    view.logsOpen = fold.open;
    if (fold.open) first();
  };
  fold.innerHTML = `<summary>Logs <small>${run.logs.map(esc).join(" · ")}</small></summary>`;
  const tabs = el("div", "bm-log-tabs");
  run.logs.forEach(name => {
    const b = el("button", "btn", esc(name));
    b.setAttribute("aria-pressed", String(!!log && log.name === name));
    b.onclick = () => openBenchmarkLog(run, name);
    tabs.appendChild(b);
  });
  fold.appendChild(tabs);
  if (log) fold.appendChild(el("pre", "bm-log", log.text == null ? "loading…" : esc(log.text)));
  else if (fold.open) setTimeout(first);
  return fold;
}

async function openBenchmarkLog(run, name) {
  const view = bench;
  const log = view.log = { run: run.id, name, text: null };
  renderBenchmark();
  let text;
  try {
    text = await (await fetch(`/api/benchmark-log/${encodeURIComponent(run.id)}/${encodeURIComponent(name)}`)).text();
  } catch (e) { text = "could not reach qm"; }
  if (bench !== view || view.log !== log) return;
  log.text = text;
  renderBenchmark();
  const pre = openModal && openModal.querySelector(".bm-log");
  if (pre) pre.scrollTop = pre.scrollHeight;
}

function benchmarkPlanFold(view, run) {
  const fold = el("details", "bm-fold");
  fold.open = view.foldOpen;
  fold.ontoggle = () => { view.foldOpen = fold.open; };
  const subjects = run.subjects || [];
  const cases = (run.rows || []).filter(r => r.why);
  fold.innerHTML = `<summary>Plan &amp; subjects <small>${subjects.length} subject${subjects.length === 1 ? "" : "s"} · ${(run.rows || []).length} case${(run.rows || []).length === 1 ? "" : "s"}</small></summary>
    <p class="bm-request"><b>Asked:</b> ${run.request ? esc(run.request) : "<em>work it out from the branch's changes</em>"}</p>
    ${subjects.length ? `<h3>Subjects</h3><dl>${subjects.map(s => `<dt><code>${esc(s.subject)}</code></dt><dd>${esc(s.about || "")}</dd>`).join("")}</dl>` : ""}
    ${cases.length ? `<h3>Why these cases</h3><dl>${cases.map(r => `<dt>${esc(r.case)} <code>${esc(r.subject)}</code></dt><dd>${esc(r.why)}</dd>`).join("")}</dl>` : ""}`;
  return fold;
}

/* ---- EXPLAIN plan overlay ---- */

async function openBenchmarkPlan(id, file, title) {
  const view = bench;
  view.plan = { title, text: null };
  renderBenchmark();
  let text;
  try {
    const r = await fetch(`/api/benchmark-plan/${encodeURIComponent(id)}/${encodeURIComponent(file)}`);
    text = await r.text();
  } catch (e) { text = "could not reach qm"; }
  if (bench !== view || !view.plan || view.plan.title !== title) return;
  view.plan.text = text;
  renderBenchmark();
}

function benchmarkPlanOverlay(view) {
  const box = el("div", "bm-plan");
  const head = el("div", "bm-plan-head", `<b>EXPLAIN</b> <span>${esc(view.plan.title)}</span>`);
  const close = el("button", "btn", "✕");
  close.title = "Back to the table";
  close.onclick = () => { view.plan = null; renderBenchmark(); };
  head.appendChild(close);
  box.appendChild(head);
  box.appendChild(el("pre", "", view.plan.text == null ? "loading…" : esc(view.plan.text)));
  return box;
}

/* ---- actions ---- */

function benchmarkActions(view, d, run) {
  const bar = el("div", "modal-actions");
  const button = (label, title, onclick, cls = "btn") => {
    const b = el("button", cls, label);
    b.title = title;
    b.onclick = onclick;
    bar.appendChild(b);
    return b;
  };
  if (d && d.runs && d.runs.length) bar.appendChild(benchmarkRunPicker(view, d, run));
  if (run && !BENCH_FINAL.includes(run.state)) {
    button("Cancel", "Stop this run (the agent or the measuring) and drop its database clone", () => cancelBenchmark(run));
  }
  if (run && BENCH_FINAL.includes(run.state) && run.canRerun) {
    const b = button("↻ Re-run script", "Measure again with the same script, without planning anew", () => rerunBenchmark(run));
    b.disabled = !!d.busy;
  }
  if (run) button("✨ New benchmark", "Plan a new benchmark of this branch", () => { view.mode = "start"; view.plan = null; renderBenchmark(); });
  else if (d && d.enabled) {
    const go = button(view.starting ? "Starting…" : "Start", "Plan and run a benchmark (⌘⏎)", startBenchmark, "btn primary");
    go.disabled = view.starting || !!d.busy;
  }
  button("Close", "Close; a running benchmark keeps going", closeModal);
  return bar;
}

function benchmarkRunPicker(view, d, run) {
  const pick = el("select", "bm-runs");
  pick.title = "Earlier runs of this branch";
  pick.innerHTML = (run ? "" : '<option value="">earlier runs…</option>') + d.runs.map(r => {
    const what = r.rerunOf ? `re-run of ${r.rerunOf}` : r.request ? r.request.slice(0, 40) : "from the changes";
    return `<option value="${esc(r.id)}"${run && run.id === r.id ? " selected" : ""}>${esc(agoText(r.startedAt))} · ${esc(r.state)} · ${esc(what)}</option>`;
  }).join("");
  pick.onchange = () => { if (pick.value) showBenchmarkRun(pick.value); };
  return pick;
}

async function cancelBenchmark(run) {
  if (!confirm(`Cancel the benchmark of ${run.branch}? Cases measured so far stay.`)) return;
  const view = bench;
  await act("benchmark-cancel", { slug: run.slug, args: { run: run.id } });
  if (bench === view) loadBenchmark();
}

async function rerunBenchmark(run) {
  const view = bench;
  const r = await act("benchmark-rerun", { slug: run.slug, args: { run: run.id } });
  if (bench !== view) return;
  if (r.ok) showBenchmarkRun(r.run);
  else loadBenchmark();
}
