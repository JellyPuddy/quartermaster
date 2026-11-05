"use strict";

/* ------- rendering ------- */
function render() {
  const cols = $("#columns");
  const answered = ask && !ask.pending;
  const shown = answered ? STATES.map(s => s.key) : statesShown();
  visibleSlugs = [];
  terms = answered ? [] : parseQuery(query);
  const results = new Map();
  if (answered) ask.hits.forEach((h, rank) => results.set(h.slug, { score: -rank, why: h.why }));
  else items.forEach(it => { const r = searchResult(it); if (r) results.set(it.slug, r); });

  keepScroll(cols, () => {
    cols.innerHTML = "";
    shown.forEach(st => {
      const list = items.filter(it => it.state === st && results.has(it.slug));
      if (answered || terms.some(t => t.text && !t.neg)) list.sort((a, b) => results.get(b.slug).score - results.get(a.slug).score);
      list.forEach(it => visibleSlugs.push(it.slug));
  
      const col = el("div", "column");
      const head = el("div", "col-head");
      head.appendChild(el("span", "col-dot dot-" + st));
      head.appendChild(el("span", "col-title", stateLabel(st)));
      head.appendChild(el("span", "col-count", String(list.length)));
      col.appendChild(head);
  
      const body = el("div", "col-body");
      if (!list.length) {
        body.appendChild(el("div", "col-empty", terms.length || answered ? "no matches" : "empty"));
      } else {
        list.forEach(it => body.appendChild(card(it, results.get(it.slug))));
      }
      col.appendChild(body);
      cols.appendChild(col);
    });
  });

  // Matches the state filter hides — one click widens it rather than leaving
  // a search for an old item looking empty.
  const hidden = terms.length ? items.filter(it => !shown.includes(it.state) && results.has(it.slug)).length : 0;
  const elsewhere = $("#elsewhere");
  elsewhere.hidden = !hidden;
  elsewhere.textContent = `+${hidden} in other states`;
  renderAskState();

  renderInbox();
  applyFocus();
  renderChatCount();
  renderPfBadge();
  renderCaffeinate();
  renderLimits();
  renderIssuesBadge();
  if (mode === "chat") renderChat();
  if (mode === "prs") renderPrs();
  if (mode === "issues") renderIssueList();
}
/* ☕: on keeps the Mac from idle-sleeping until it is switched off or the GUI exits;
   auto only while some session is working or has agents out. Clicks cycle off → auto → on. */
const CAFFEINATE_NEXT = { off: "auto", auto: "on", on: "off" };
function renderCaffeinate() {
  const b = $("#caffeinate");
  const m = caffeinate.mode || (caffeinate.on ? "on" : "off");
  b.setAttribute("aria-pressed", { off: "false", on: "true", auto: "mixed" }[m]);
  b.classList.toggle("held", !!caffeinate.on);
  b.title = {
    on: `Kept from idle sleep (caffeinate pid ${caffeinate.pid}) until you switch it off or qm gui exits — click for off`,
    auto: caffeinate.on
      ? `Auto: kept from idle sleep while a session is working (caffeinate pid ${caffeinate.pid}) — click for always on`
      : "Auto: no session is working, so the Mac may sleep; it is held awake again as soon as one is — click for always on",
    off: "Keep the Mac from idle-sleeping (caffeinate -i; the display may still sleep) — click for auto: only while a session is working"
  }[m];
}
/* The toggle's count: chats waiting on the user (blocked or an unsnoozed your turn). */
function renderChatCount() {
  const n = attention.filter(a => a.state === "blocked" || (a.state === "your_turn" && !a.snoozed)).length;
  $("#chat-count").innerHTML = n ? `<span class="col-count" style="margin-left:4px;color:var(--turn)">${n}</span>` : "";
}

/* The server's attention badges plus the page-side "distilling" one, which
   lives on the job registry rather than the item. */
function badgesOf(it) {
  const list = (it.badges || []).slice();
  if (distilling.includes(it.slug)) list.push({ type: "distilling", label: "distilling via haiku…" });
  const job = jobFor(it.slug);
  if (job) list.push({ type: "distilling", label: job.label });
  return list;
}
