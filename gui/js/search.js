"use strict";

/* ------- filtering ------- */
function statesShown() {
  if (filter === "all") return STATES.map(s => s.key);
  if (filter === "open") return ["in_progress", "fridge"];
  return [filter];
}
/* ------- search -------
   Live search: every space-separated term must match somewhere. Free terms
   fuzzy-match the slug and title (fzf-style subsequence) and substring-match
   the body text, weighted so a title hit outranks a note hit. Field terms
   narrow one field: p:project, b:branch, #issue (project#issue: in that project), is:live|stale|degrading|merged,
   and a leading - excludes. The search text is built once per refresh. */
function searchIndex(it) {
  const lc = s => String(s || "").toLowerCase();
  return {
    slug: lc(it.slug), title: lc(it.title), project: lc(it.project),
    branches: (it.branches || []).map(lc), issue: it.issue_number ? String(it.issue_number) : "",
    body: [
      ...(it.branches || []).map(b => ({ where: "branch", text: b })),
      { where: "project", text: it.project || "" },
      { where: "description", text: it.description || "" },
      ...(it.notes || []).map(n => ({ where: "note " + n.stamp, text: n.text })),
      ...(it.snapshots || []).map(sn => ({ where: "snapshot " + (sn.stamp || ""), text: sn.text })),
    ].filter(f => f.text).map(f => ({ ...f, lc: lc(f.text) })),
  };
}
const BODY_WEIGHT = { branch: 60, project: 50, description: 30, note: 20, snapshot: 8 };

function parseQuery(q) {
  return q.trim().split(/\s+/).filter(Boolean).map(raw => {
    const neg = raw.length > 1 && raw[0] === "-";
    const t = (neg ? raw.slice(1) : raw).toLowerCase();
    const m = t.match(/^(p|project|b|branch|is):(.+)$/);
    if (m) return { neg, field: m[1][0], value: m[2] };
    if (/^#\d+$/.test(t)) return { neg, field: "#", value: t.slice(1) };
    const ref = t.match(/^([a-z][\w.-]*)#(\d+)$/);
    if (ref) return { neg, field: "#", value: ref[2], project: ref[1] };
    return { neg, text: t };
  });
}

/* fzf-flavoured subsequence score: consecutive runs and word starts earn
   bonuses, a contiguous substring beats any scattered match. Scattered
   matching only kicks in from four characters and must stay tight or hit
   word starts — otherwise "lti" finds "coLlecTIons". */
function fuzzyScore(term, hay) {
  if (!term || !hay) return 0;
  const at = hay.indexOf(term);
  if (at >= 0) return 100 + term.length * 4 + (at === 0 ? 30 : /[^a-z0-9]/.test(hay[at - 1]) ? 20 : 0);
  if (term.length < 4) return 0;
  const wordStart = i => i === 0 || /[^a-z0-9]/.test(hay[i - 1]);
  let best = 0;
  for (let start = hay.indexOf(term[0]); start >= 0; start = hay.indexOf(term[0], start + 1)) {
    let score = 0, prev = -2, gaps = 0, starts = 0, i = start;
    for (let k = 0; k < term.length; k++, i++) {
      i = hay.indexOf(term[k], i);
      if (i < 0) { score = 0; break; }
      if (wordStart(i)) { starts++; score += 8; }
      if (i === prev + 1) score += 5; else if (prev >= 0) gaps += i - prev - 1;
      score += 1; prev = i;
    }
    if (!score) break;
    if (gaps > term.length && starts < term.length - 1) continue;
    best = Math.max(best, score - gaps);
  }
  return Math.max(best, 0);
}

function wordStartIndex(hay, term) {
  for (let at = hay.indexOf(term); at >= 0; at = hay.indexOf(term, at + 1)) {
    if (at === 0 || /[^a-z0-9]/.test(hay[at - 1])) return at;
  }
  return -1;
}

function termHit(term, idx, it) {
  if (term.field === "p") return idx.project.includes(term.value) ? { score: 1 } : null;
  if (term.field === "b") return idx.branches.some(b => b.includes(term.value)) ? { score: 1 } : null;
  if (term.field === "#") {
    if (term.project && idx.project !== term.project) return null;
    return idx.issue.startsWith(term.value) || idx.slug.includes(term.value) ? { score: 1 } : null;
  }
  if (term.field === "i") {
    const v = term.value;
    return (v === "live" ? it.live : badgesOf(it).some(b => b.type === v)) ? { score: 1 } : null;
  }
  const head = Math.max(fuzzyScore(term.text, idx.slug), fuzzyScore(term.text, idx.title) * 1.2);
  if (head) return { score: head };
  // Body text only matches at word starts: "lti" should find "LTI launch",
  // not every note that says "multi".
  for (const f of idx.body) {
    const at = wordStartIndex(f.lc, term.text);
    if (at >= 0) return { score: BODY_WEIGHT[f.where.split(" ")[0]], where: f.where, text: f.text, at, len: term.text.length };
  }
  return null;
}

/* null when the item doesn't match; otherwise its score and, when a term only
   matched body text, that text — the card shows it so the hit isn't a mystery. */
let terms = [];
function searchResult(it) {
  if (!terms.length) return { score: 0 };
  if (!it._idx) it._idx = searchIndex(it);
  let score = 0, shown = null;
  for (const term of terms) {
    const hit = termHit(term, it._idx, it);
    if (term.neg ? hit : !hit) return null;
    if (term.neg) continue;
    score += hit.score;
    if (hit.where && !shown) shown = hit;
  }
  return { score, hit: shown };
}

function snippet(hit) {
  const pad = 50;
  const from = Math.max(0, hit.at - pad), to = Math.min(hit.text.length, hit.at + hit.len + pad * 2);
  return (from ? "…" : "") + esc(hit.text.slice(from, hit.at)) + "<mark>" + esc(hit.text.slice(hit.at, hit.at + hit.len)) +
    "</mark>" + esc(hit.text.slice(hit.at + hit.len, to)) + (to < hit.text.length ? "…" : "");
}

/* Ask mode: Enter sends the search text to /api/ask, which has headless
   claude read every item and answer with ranked slugs and a reason each. The
   answer replaces the board's contents across all states — what you're
   half-remembering may well be resolved — until the query is edited or Esc. */
async function runAsk() {
  const q = query.trim();
  if (!q || (ask && ask.query === q)) return;
  ask = { query: q, pending: true, hits: [] };
  renderAskState();
  try {
    const r = await fetch("/api/ask", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query: q }) });
    const res = await r.json();
    if (!ask || ask.query !== q) return;  // edited or cleared while claude was thinking
    if (!res.ok) { ask = null; toast(res.error || "ask failed", false); }
    else ask = { query: q, pending: false, hits: res.hits };
  } catch (e) {
    if (!ask || ask.query !== q) return;
    ask = null; toast("network error", false);
  }
  focusIdx = -1;
  render();
}
// The question was prose, useless as a live filter — clear it with the answer.
function clearAsk() { ask = null; query = ""; $("#search").value = ""; render(); }
function renderAskState() {
  const box = $(".search"), label = $("#ask-state");
  box.classList.toggle("asking", !!(ask && ask.pending));
  box.classList.toggle("asked", !!(ask && !ask.pending));
  label.hidden = !ask;
  if (ask) label.textContent = ask.pending ? "✦ asking…" : `✦ ${ask.hits.length} found · esc`;
}
