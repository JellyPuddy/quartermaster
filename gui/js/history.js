"use strict";

/* The item's earlier sessions, read-only above its live chat (ChatHistory):
   oldest at the top, rotation dividers between, loaded a page at a time from
   the newest end as the user scrolls up. It survives the state polls' re-renders
   and reloads only when the earlier sessions or the rotations change. */
const hist = { key: null, slug: null, segs: [], idx: -1, before: null, busy: false, gen: 0 };
let histCollapsed = false;
try { histCollapsed = localStorage.getItem("qm-history-collapsed") === "1"; } catch (e) { /* storage blocked: open */ }

function historyKey(it) {
  const earlier = (it.sessionList || []).filter(s => s.tier !== "live").map(s => s.id).sort();
  return `${it.slug}|${earlier.join(",")}|${it.rotations || 0}`;
}

function renderHistory(it) {
  const box = $("#chat-history");
  // Bumping gen drops a timeline still in flight for the previous item.
  if (!it) { box.hidden = true; hist.key = null; hist.gen++; return; }
  const key = historyKey(it);
  if (key === hist.key) return;
  hist.key = key;
  hist.slug = it.slug;
  hist.gen++;
  hist.segs = []; hist.idx = -1; hist.before = null; hist.busy = false;
  $("#hist-scroll").innerHTML = "";
  box.hidden = true;
  const gen = hist.gen;
  fetch(`/api/history/${encodeURIComponent(it.slug)}`).then(r => r.json()).then(r => {
    if (gen !== hist.gen || !r.ok) return;
    hist.segs = r.timeline || [];
    hist.idx = hist.segs.length - 1;
    if (!hist.segs.some(s => s.type === "session")) return;
    box.hidden = false;
    renderHistoryBar();
    const sc = $("#hist-scroll");
    sc.appendChild(el("div", "hist-top", "↑ scroll for older"));
    loadOlder(true);
  }).catch(() => { /* the next state change retries */ });
}

function renderHistoryBar() {
  const box = $("#chat-history");
  box.classList.toggle("collapsed", histCollapsed);
  const bar = $("#hist-bar");
  bar.className = "hist-bar term-bar";
  bar.innerHTML = "";
  const sessions = hist.segs.filter(s => s.type === "session").length;
  const rotations = hist.segs.filter(s => s.type === "divider").length;
  bar.appendChild(el("span", "tag", "EARLIER"));
  bar.appendChild(el("span", "grow", `${sessions} session${sessions === 1 ? "" : "s"}` +
    (rotations ? ` · ${rotations} rotation${rotations === 1 ? "" : "s"}` : "") + " — read-only, from the transcripts"));
  const t = el("button", "", histCollapsed ? "Show ▾" : "Hide ▴");
  t.onclick = () => {
    histCollapsed = !histCollapsed;
    try { localStorage.setItem("qm-history-collapsed", histCollapsed ? "1" : "0"); } catch (e) { /* not remembered */ }
    renderHistoryBar();
    if (!histCollapsed) {
      const sc = $("#hist-scroll");
      sc.scrollTop = sc.scrollHeight;
      if (sc.scrollHeight <= sc.clientHeight + 40) loadOlder(true);
    }
  };
  bar.appendChild(t);
}

const hm = ts => { const d = new Date(ts); return isNaN(d) ? "" : d.toTimeString().slice(0, 5); };
const dayTime = ts => {
  const d = new Date(ts);
  if (isNaN(d)) return "";
  const today = new Date().toDateString() === d.toDateString();
  return (today ? "today" : d.toLocaleDateString(undefined, { month: "short", day: "numeric" })) + " " + hm(ts);
};

function historyEntry(e) {
  if (e.kind === "snapshot") {
    const n = el("div", "h-entry h-snapshot");
    n.appendChild(el("span", "lbl", "transcript expired · distilled snapshot"));
    n.appendChild(document.createTextNode(e.text));
    return n;
  }
  const n = el("div", `h-entry h-${e.kind}`);
  n.textContent = e.text;
  if (e.ts) n.title = dayTime(e.ts);
  return n;
}

function sessionHeader(seg) {
  const src = { transcript: "", snapshot: " · transcript expired", none: " · transcript expired" }[seg.source] || "";
  return el("div", "h-session", `session ${esc(short(seg.id))}${seg.at ? " · " + esc(dayTime(seg.at)) : ""}${src}`);
}

function rotationDivider(seg) {
  const d = el("details", "rot-div");
  const s = el("summary", "", `── rotated ${esc(hm(seg.at))} · carried: ${seg.decisions} decision${seg.decisions === 1 ? "" : "s"}, ${seg.open} open ──`);
  s.title = `${dayTime(seg.at)} — ${seg.via === "distill" ? "dead chat, distilled" : "wrap-up by the chat itself"}; click for the carried notes`;
  d.appendChild(s);
  const ul = el("ul");
  if (!seg.notes.length) ul.appendChild(el("li", "", "no notes were carried"));
  seg.notes.forEach(nt => {
    const li = el("li");
    li.append(el("span", "pos", `#${nt.position}`), el("span", "k " + nt.kind, esc(nt.kind)), document.createTextNode(nt.text));
    ul.appendChild(li);
  });
  d.appendChild(ul);
  return d;
}

/* Prepends the next older chunk: a divider, or a page of the current
   session (its header once its first entry is in). Keeps the reading
   position; the first load lands at the bottom, next to the live chat. */
async function loadOlder(first = false) {
  if (hist.busy || hist.idx < 0) return;
  hist.busy = true;
  const gen = hist.gen;
  const sc = $("#hist-scroll");
  const nodes = [];
  try {
    while (hist.idx >= 0 && !nodes.length) {
      const seg = hist.segs[hist.idx];
      if (seg.type === "divider") { nodes.push(rotationDivider(seg)); hist.idx--; continue; }
      const q = hist.before != null ? `?before=${hist.before}` : "";
      const r = await (await fetch(`/api/history/${encodeURIComponent(hist.slug)}/${encodeURIComponent(seg.id)}${q}`)).json();
      if (gen !== hist.gen) return;
      if (!r.ok) { hist.idx = -1; break; }
      if (r.before == null) nodes.push(sessionHeader(seg));
      r.entries.forEach(e => nodes.push(historyEntry(e)));
      if (r.before == null) { hist.idx--; hist.before = null; } else hist.before = r.before;
    }
  } catch (e) { hist.busy = false; return; } finally { if (gen === hist.gen) hist.busy = false; }
  if (gen !== hist.gen) return;
  const top = sc.querySelector(".hist-top");
  const height = sc.scrollHeight, scrolled = sc.scrollTop;
  const frag = document.createDocumentFragment();
  nodes.forEach(n => frag.appendChild(n));
  top.after(frag);
  if (hist.idx < 0) top.textContent = "the item's first session";
  if (first) sc.scrollTop = sc.scrollHeight;
  else sc.scrollTop = scrolled + (sc.scrollHeight - height);
  // Not enough to scroll yet: keep filling upward.
  if (hist.idx >= 0 && sc.scrollHeight <= sc.clientHeight + 40 && !histCollapsed) loadOlder(first);
}
$("#hist-scroll").addEventListener("scroll", e => { if (e.target.scrollTop < 80) loadOlder(); });
