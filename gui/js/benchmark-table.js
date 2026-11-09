"use strict";

/* ------- benchmark results table -------
   The run view's results <table> (js/benchmark.js renders the rest of the
   modal): Subject, Case, one column per stage, Ids and the speed bars,
   sortable by a header click. */

/* The stage names in order: the run's stages, then any a case named besides. */
function benchmarkStageNames(run) {
  const names = (run.stages || []).map(s => s.name);
  (run.rows || []).forEach(r => Object.keys(r.cells || {}).forEach(n => { if (!names.includes(n)) names.push(n); }));
  return names;
}

/* Each run's chosen table sort, by run id, for this page's life:
   { key: "subject" | "case" | "stage:<name>", dir: "desc" | "asc" }. */
const benchSorts = {};

/* A header click cycles first → second → plan order: stages slowest first
   then fastest first, Subject and Case A→Z then Z→A. */
function cycleBenchmarkSort(runId, key) {
  const now = benchSorts[runId];
  const first = key.startsWith("stage:") ? "desc" : "asc";
  const second = first === "desc" ? "asc" : "desc";
  if (!now || now.key !== key) benchSorts[runId] = { key, dir: first };
  else if (now.dir === first) benchSorts[runId] = { key, dir: second };
  else delete benchSorts[runId];
  renderBenchmark();
}

/* A row's sort value for a key: a stage's ms (a timeout slower than any
   number), the subject or case text; null for an unmeasured cell. */
function benchmarkSortValue(row, key) {
  if (key === "subject") return String(row.subject || "");
  if (key === "case") return String(row.case || "");
  const cell = (row.cells || {})[key.slice(6)];
  if (!cell) return null;
  if (cell.timeout) return Infinity;
  return cell.ms == null ? null : cell.ms;
}

/* The rows in the chosen order; unmeasured last both ways, ties in plan order. */
function benchmarkSortedRows(rows, sort) {
  if (!sort) return rows;
  const sign = sort.dir === "asc" ? 1 : -1;
  return rows.map((row, i) => ({ row, i, v: benchmarkSortValue(row, sort.key) }))
    .sort((a, b) => {
      if (a.v == null || b.v == null) return a.v == null && b.v == null ? a.i - b.i : a.v == null ? 1 : -1;
      const c = typeof a.v === "string" ? a.v.localeCompare(b.v, undefined, { numeric: true }) : a.v === b.v ? 0 : a.v < b.v ? -1 : 1;
      return c * sign || a.i - b.i;
    })
    .map(x => x.row);
}

function benchmarkTable(view, run, live) {
  const stages = benchmarkStageNames(run);
  const sort = benchSorts[run.id] || null;
  const head = (key, label, cls, title) => {
    const on = sort && sort.key === key;
    const mark = on ? `<span class="bm-sort-mark">${sort.dir === "desc" ? "▼" : "▲"}</span>` : "";
    return `<th class="bm-sortable${cls ? " " + cls : ""}${on ? " bm-sorted" : ""}" data-sort="${esc(key)}" title="${esc(title)}" aria-sort="${on ? (sort.dir === "desc" ? "descending" : "ascending") : "none"}">${label}${mark}</th>`;
  };
  const table = el("table", "bm-table");
  table.innerHTML = `<thead><tr>` +
    head("subject", "Subject", "", "Sort by subject: A→Z, Z→A, plan order") +
    head("case", "Case", "", "Sort by case: A→Z, Z→A, plan order") +
    stages.map((s, i) => head(`stage:${s}`, `${esc(s)}${i ? " <small>Δ vs " + esc(stages[0]) + "</small>" : ""}`, "bm-num",
      `Sort by ${s}: slowest first, fastest first, plan order`)).join("") +
    `<th>Ids</th><th class="bm-speed-h">speed <small>log</small></th></tr></thead>`;
  table.querySelectorAll("th[data-sort]").forEach(th => { th.onclick = () => cycleBenchmarkSort(run.id, th.dataset.sort); });
  const tbody = el("tbody", "");
  benchmarkSortedRows(run.rows, sort).forEach(row => {
    const tr = el("tr", "");
    tr.innerHTML = `<td class="bm-subject"><code>${esc(row.subject)}</code></td><td class="bm-case">${esc(row.case)}</td>` +
      stages.map((s, i) => `<td class="bm-num">${benchmarkCell(row.cells[s], i ? row.cells[stages[0]] : null, live, s)}</td>`).join("") +
      `<td class="bm-ids-col">${benchmarkIds(stages, row)}</td>` +
      `<td class="bm-speed">${benchmarkSpeedBar(stages, row)}</td>`;
    tr.querySelectorAll("[data-plan]").forEach(b => {
      b.onclick = () => openBenchmarkPlan(run.id, b.dataset.plan, `${row.case} · ${row.subject} · ${b.dataset.stage}`);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  const wrap = el("div", "bm-table-wrap");
  wrap.appendChild(table);
  return wrap;
}

/* Each stage's id check, in stage order: ✓ same, ✗ differ, – n/a. */
function benchmarkIds(stages, row) {
  const marks = stages.map(s => {
    const cell = row.cells[s];
    const ids = cell && cell.ids && BENCH_IDS[cell.ids];
    return ids ? `<span class="bm-ids ${ids[1]}" title="${esc(s)}: ids vs ${esc(cell.vs || "–")}: ${esc(cell.ids)}">${ids[0]}</span>` : "";
  }).filter(Boolean);
  return marks.length ? marks.join(" ") : '<span class="bm-none">–</span>';
}

function benchmarkMs(ms) {
  if (ms == null) return "–";
  return ms >= 1000 ? `${(ms / 1000).toFixed(ms >= 10000 ? 1 : 2)} s` : `${ms >= 100 ? Math.round(ms) : ms.toFixed(1)} ms`;
}

const BENCH_IDS = { same: ["✓", "bm-ids-same"], differ: ["✗", "bm-ids-differ"], "n/a": ["–", "bm-ids-na"] };

/* One measured cell: time (or ∞), its Δ% chip against the base cell, the
   query count and a ▸ to its EXPLAIN plan (the id check has its own column). */
function benchmarkCell(cell, base, live, stage) {
  if (!cell) return live ? '<span class="bm-spin" title="not measured yet"></span>' : '<span class="bm-none">–</span>';
  const time = cell.timeout ? '<span class="bm-inf" title="timed out">∞ <small>(&gt;60 s)</small></span>' : `<span class="bm-ms">${benchmarkMs(cell.ms)}</span>`;
  const parts = [time];
  if (base) parts.push(benchmarkDelta(cell, base));
  if (cell.queries != null) parts.push(`<small class="bm-q" title="queries">${esc(cell.queries)} q</small>`);
  if (cell.plan) parts.push(`<button class="bm-plan-btn" data-plan="${esc(cell.plan)}" data-stage="${esc(stage)}" title="EXPLAIN plan">▸</button>`);
  return parts.join(" ");
}

function benchmarkDelta(cell, base) {
  if (base.timeout && !cell.timeout) return '<span class="bm-delta bm-faster" title="main timed out">was ∞</span>';
  if (cell.timeout || base.ms == null || cell.ms == null || base.ms <= 0) return "";
  const pct = (cell.ms - base.ms) / base.ms * 100;
  const cls = Math.abs(pct) < BENCH_GREY_PCT ? "bm-noise" : pct < 0 ? "bm-faster" : "bm-slower";
  const shown = Math.abs(pct) >= 1000 ? `${pct > 0 ? "+" : ""}${(cell.ms / base.ms).toFixed(0)}×` : `${pct > 0 ? "+" : "−"}${Math.abs(pct).toFixed(0)}%`;
  return `<span class="bm-delta ${cls}" title="${BENCH_GREY_PCT}% either way is run-to-run noise">${shown}</span>`;
}

/* One bar per stage on a log scale from 1 ms to the 60 s timeout. */
function benchmarkSpeedBar(stages, row) {
  const top = Math.log10(BENCH_TIMEOUT_MS);
  return `<span class="bm-bars">${stages.map((s, i) => {
    const cell = row.cells[s];
    if (!cell) return `<span class="bm-bar"></span>`;
    const ms = cell.timeout ? BENCH_TIMEOUT_MS : Math.max(1, cell.ms || 1);
    const w = Math.min(100, Math.max(2, 100 * Math.log10(ms) / top));
    const cls = cell.timeout ? "bm-bar-inf" : `bm-bar-${Math.min(i, 3)}`;
    return `<span class="bm-bar" title="${esc(s)}: ${cell.timeout ? "timed out" : benchmarkMs(cell.ms)}"><span class="${cls}" style="width:${w.toFixed(1)}%"></span></span>`;
  }).join("")}</span>`;
}
