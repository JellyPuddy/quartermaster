"use strict";

/* The aside drawer: a one-off question beside the item's chat, in a tmux
   session of its own (<slug>--aside) started with the item's digest. It is
   not the item's chat — no attention, never distilled, not in its sessions —
   and closing the drawer ends it. Promote turns its last answer into a note. */
const asideTerm = new TermView($("#aside-host"));
asideTerm.onClosed = () => refresh();
asideTerm.onMaxChord = () => togglePaneMax();
const asideWanted = {}; // slug → the start form is open (no aside runs yet)
const asideName = slug => `${slug}--aside`;

function openAside(it) {
  asideWanted[it.slug] = true;
  renderAside(it);
  if (panes.includes(asideName(it.slug))) asideTerm.focus();
  else { const sel = $("#aside-start select"); if (sel) sel.focus(); }
}

function closeAside(it) {
  asideWanted[it.slug] = false;
  if (!panes.includes(asideName(it.slug))) return renderAside(it);
  asideTerm.disconnect();
  act("aside-close", { slug: it.slug }).then(r => { if (r.ok) toast(`aside for ${it.slug} closed`); });
}

function startAside(it, model) {
  act("aside-open", { slug: it.slug, args: { model } }).then(r => {
    if (!r.ok) return;
    asideWanted[it.slug] = false;
    if (!panes.includes(r.session)) panes = panes.concat(r.session);
    renderAside(it);
    asideTerm.focus();
  });
}

function renderAside(it) {
  const drawer = $("#aside-drawer");
  const live = !!it && panes.includes(asideName(it.slug));
  if (!it || (!live && !asideWanted[it.slug])) { drawer.hidden = true; asideTerm.disconnect(); return; }
  drawer.hidden = false;
  const bar = $("#aside-bar");
  bar.innerHTML = "";
  bar.appendChild(el("span", "tag", "ASIDE"));
  bar.appendChild(el("span", "grow", live ? `tmux · ${esc(asideName(it.slug))} — not the item's chat; closing ends it`
                                          : "a one-off question with the item's digest — not the item's chat"));
  const button = (label, title, onclick) => { const b = el("button", "", label); b.title = title; b.onclick = onclick; bar.appendChild(b); return b; };
  if (live) {
    button("Promote", "Copy the aside's last answer into a note on the item", () =>
      act("aside-promote", { slug: it.slug }).then(r => { if (r.ok) toast(`answer promoted to a note on ${it.slug}`); }));
    button("Open in Warp", "tmux attach to this aside in a Warp tab", () =>
      act("pane-warp", { slug: asideName(it.slug) }).then(r => { if (r.ok) toast("aside → Warp tab (same session)"); }));
  }
  button("Close ✕", live ? "Ends the aside (kills its tmux session)" : "Close the drawer", () => closeAside(it));

  const host = $("#aside-host");
  const start = $("#aside-start");
  host.hidden = !live; start.hidden = live;
  if (live) { start.innerHTML = ""; delete start.dataset.slug; asideTerm.connect(asideName(it.slug)); return; }
  asideTerm.disconnect();
  if (start.dataset.slug === it.slug) return; // keep the picker as the user left it across polls
  start.dataset.slug = it.slug;
  start.innerHTML = "";
  const inner = el("div", "");
  inner.innerHTML = `<strong>Ask on the side</strong><br>Starts claude with ${esc(it.slug)}'s digest. ` +
    "Nothing here reaches the item unless you promote it.";
  const row = el("div", "row");
  const sel = el("select", "");
  sel.setAttribute("aria-label", "Model");
  asideModels.forEach(m => sel.appendChild(new Option(m, m)));
  const go = el("button", "go", "Start aside");
  go.onclick = () => startAside(it, sel.value);
  sel.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); go.click(); } });
  row.append(sel, go);
  inner.appendChild(row);
  start.appendChild(inner);
  start.classList.remove("has-earlier");
  loadEarlierAsides(it, start);
}

/* The item's earlier asides under the picker, fetched on demand (each reads a
   transcript, so they stay out of the state poll). Reopen resumes one in the
   drawer, still an aside; Promote notes its last answer on the item. */
function loadEarlierAsides(it, start) {
  fetch("/api/asides/" + encodeURIComponent(it.slug)).then(r => r.json()).then(d => {
    if (start.dataset.slug !== it.slug || !start.querySelector("select")) return; // moved on meanwhile
    const old = start.querySelector(".aside-earlier"); if (old) old.remove();
    const list = d.asides || [];
    start.classList.toggle("has-earlier", list.length > 0);
    if (!list.length) return;
    const wrap = el("div", "aside-earlier");
    wrap.appendChild(el("h4", "", `EARLIER ASIDES · ${list.length}`));
    list.forEach(a => wrap.appendChild(earlierAsideCard(it, a, start)));
    start.appendChild(wrap);
  }).catch(() => { /* the picker still works without the list */ });
}

// "claude-sonnet-5-5" → "sonnet": the picker's word for it.
const modelName = id => (id && asideModels.find(m => id.includes(m))) || id;

function earlierAsideCard(it, a, start) {
  const c = el("div", "aside-card");
  c.appendChild(el("div", "q", esc(a.prompt || "no prompt captured")));
  const ans = el("div", "a", esc(a.answer || "(no answer)"));
  ans.onclick = () => ans.classList.toggle("open");
  c.appendChild(ans);
  const m = el("div", "meta");
  m.appendChild(el("span", "", [short(a.id), a.when, modelName(a.model)].filter(Boolean).map(esc).join(" · ")));
  if (a.promoted) m.appendChild(el("span", "promoted", "✓ promoted"));
  m.appendChild(el("span", "grow"));
  const button = (label, title, onclick) => { const b = el("button", "", label); b.title = title; b.onclick = onclick; m.appendChild(b); };
  button("Transcript", "Read this aside", () => openSession(null, { id: a.id, tier: a.tier, when: a.when, prompt: a.prompt, aside: true }));
  if (a.tier === "resumable") button("Reopen", "Continue this aside in the drawer", () =>
    act("aside-reopen", { slug: it.slug, args: { session: a.id } }).then(r => {
      if (!r.ok) return;
      asideWanted[it.slug] = false;
      if (!panes.includes(r.session)) panes = panes.concat(r.session);
      renderAside(it);
      asideTerm.focus();
    }));
  if (a.answer && !a.promoted) button("Promote", "Copy this answer into a note on the item", () =>
    act("aside-promote", { slug: it.slug, args: { session: a.id } }).then(r => {
      if (r.ok) { toast(`answer promoted to a note on ${it.slug}`); loadEarlierAsides(it, start); }
    }));
  c.appendChild(m);
  return c;
}
