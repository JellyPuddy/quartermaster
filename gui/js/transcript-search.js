"use strict";

/* ------- transcript search -------
   The search box's second explicit action (⇧⏎, or the row under the box):
   /api/grep has rg find the sessions whose prompts or replies contain the
   text, grouped by work item. Results open in a modal rather than on the
   board — they are sessions, not items, and unlinked ones have no card. */
function renderSearchMenu() {
  const menu = $("#search-menu");
  const q = query.trim();
  menu.hidden = !(q && !ask && document.activeElement === $("#search"));
  if (menu.hidden) return;
  // #1234 alone: ⏎ starts work on the issue (issue-start.js) rather than asking.
  const ref = issueRef(q);
  $("#search-menu-issue").hidden = !ref;
  if (ref) $("#search-menu-issue").innerHTML = `<span>Start work on <b>${esc(ref.project ? `${ref.project}#${ref.number}` : `#${ref.number}`)}</b>${ref.project ? "" : ` <i>(${esc(contextProject() || DEFAULT_PROJECT || "No project")})</i>`}</span><kbd>⏎</kbd>`;
  $("#search-menu-ask").innerHTML = `<span>Ask by meaning</span>${ref ? "" : "<kbd>⏎</kbd>"}`;
  $("#search-menu-grep").innerHTML = `<span>Search transcripts for “<b>${esc(q)}</b>”</span><kbd>⇧⏎</kbd>`;
}

async function runTranscriptSearch() {
  const q = query.trim();
  if (!q) return;
  $("#search").blur();
  let box = null;
  modal(m => {
    m.classList.add("grep-modal");
    m.innerHTML = `<h2>Transcripts mentioning “${esc(q)}”</h2><p class="sub">searching prompts and replies…</p>`;
    box = m;
  });
  const shown = openModal;
  let res;
  try {
    const r = await fetch("/api/grep", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query: q }) });
    res = await r.json();
  } catch (e) {
    res = { ok: false, error: "network error" };
  }
  if (openModal !== shown) return;  // closed (or replaced) while rg ran
  if (!res.ok) { closeModal(); toast(res.error || "transcript search failed", false); return; }
  renderTranscriptHits(box, res);
}

function renderTranscriptHits(m, res) {
  const count = res.groups.reduce((n, g) => n + g.sessions.length, 0);
  const sub = m.querySelector(".sub");
  sub.textContent = count ? `${count} session${count === 1 ? "" : "s"} · prompts and replies, asides left out` : "no session mentions that";
  if (res.more) sub.textContent += ` · ${res.more} more transcript(s) unread — narrow the phrase`;
  const list = el("div", "grep-results");
  res.groups.forEach(g => list.appendChild(transcriptGroup(g)));
  m.appendChild(list);
  const bar = el("div", "modal-actions");
  const done = el("button", "btn", "Close"); done.onclick = closeModal;
  bar.appendChild(done); m.appendChild(bar);
}

function transcriptGroup(g) {
  const it = g.slug && items.find(i => i.slug === g.slug);
  const sec = el("section", "grep-group");
  const head = el("div", "grep-head");
  if (g.state) head.appendChild(el("span", "col-dot dot-" + g.state));
  head.appendChild(el("span", "grep-title", esc(g.title)));
  if (g.slug) head.appendChild(el("span", "grep-slug", esc(g.slug)));
  if (it) {
    const open = el("button", "btn", "Open item");
    open.onclick = () => { closeModal(); openDetail(it); };
    head.appendChild(open);
  }
  sec.appendChild(head);
  g.sessions.forEach(se => sec.appendChild(transcriptHit(g, se)));
  return sec;
}

function transcriptHit(g, se) {
  const row = el("div", "grep-hit");
  const meta = el("div", "grep-meta");
  const date = se.date ? new Date(se.date).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : "undated";
  meta.innerHTML = `<span>${esc(date)}</span><span class="mono">${esc(short(se.id))}</span>` +
    (se.hits > 1 ? `<span>${se.hits} hits</span>` : "");
  const resume = el("button", "btn", "Resume");
  resume.title = `resume session ${se.id} in a Warp tab`;
  resume.onclick = () => (g.slug ? act("resume", { slug: g.slug, args: { session: se.id } })
                                 : act("resume-session", { args: { session: se.id } }))
    .then(r => { if (r.ok) { closeModal(); toast(`resuming ${short(se.id)} → Warp tab`); } });
  meta.appendChild(resume);
  row.appendChild(meta);
  row.appendChild(el("div", "grep-snippet",
    `<span class="grep-role">${se.role === "user" ? "you" : "claude"}</span> ` +
    `${esc(se.before)}<mark>${esc(se.match)}</mark>${esc(se.after)}`));
  return row;
}
