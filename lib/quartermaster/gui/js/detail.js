"use strict";

/* ------- detail slide-over ------- */
let openSheet = null;
let noteFilter = "all";
let foldedSecs = {};
/* ⋯ → Links…: the sheet with its Links section open and the label field focused. */
function openDetailLinks(it) {
  linkDraft = { slug: it.slug, label: "", url: "", focus: "label" };
  foldedSecs.Links = false;
  openDetail(it);
  const editor = openSheet && openSheet.querySelector(".links-editor");
  if (editor) editor.scrollIntoView({ block: "nearest" });
}
function closeDetail() { detailSlug = null; closeSession(); if (openSheet) { openSheet.remove(); openSheet = null; } }

function openDetail(it) {
  const rerender = openSheet && detailSlug === it.slug;
  keepScroll(() => openSheet, () => {
    if (openSheet) { openSheet.remove(); openSheet = null; }
    if (detailSlug !== it.slug) { noteFilter = "all"; foldedSecs = {}; }
    detailSlug = it.slug;
    const scrim = el("div", "sheet-scrim");
    scrim.addEventListener("mousedown", e => { if (e.target === scrim) closeDetail(); });
    const s = el("div", "sheet");
    if (rerender) { scrim.style.animation = "none"; s.style.animation = "none"; }

    const head = el("div", "sheet-head");
    const r1 = el("div", "row1");
    r1.appendChild(el("span", "status-dot dot-" + it.state));
    r1.appendChild(el("span", "slug", esc(it.slug)));
    if (isEpic(it)) r1.appendChild(el("span", "epic-kind", "EPIC"));
    const parent = epicOf(it);
    if (parent) {
      const tag = el("button", "epic-tag", `◆ ${esc(parent.title)}`);
      tag.title = "Open the epic (⋯ → Epic… moves or clears it)";
      tag.onclick = () => openDetail(parent);
      r1.appendChild(tag);
    }
    if (it.live) r1.appendChild(el("span", "live-dot", "live"));
    const close = el("button", "sheet-close", "✕"); close.onclick = closeDetail;
    r1.appendChild(close);
    head.appendChild(r1);
    head.appendChild(el("h2", "", esc(it.title)));
    const meta = el("div", "meta");
    meta.style.marginTop = "7px";
    meta.innerHTML = `${esc(stateLabel(it.state))} <span class="sep">·</span> ${esc(it.project)} <span class="sep">·</span> ${it.sessions} sessions <span class="sep">·</span> updated ${esc(it.updated)}`;
    head.appendChild(meta);
    const headBadges = badgesOf(it);
    if (headBadges.length) {
      const b = el("div", "badges"); b.style.marginTop = "9px";
      headBadges.forEach(bd => b.appendChild(el("span", "badge " + bd.type, esc(bd.label))));
      head.appendChild(b);
    }
    s.appendChild(head);

    const bar = el("div", "sheet-actions");
    const mk = (a, extra, label) => bar.appendChild(action(a, extra, label, ""));
    mk("resume", "strong", "▸ Resume"); mk("start", "", "Start ⧉"); mk("pr", "", "PR");
    mk("state", "", "State ▾"); mk("note", "", "Note +"); mk("more", "", "⋯");
    bar.addEventListener("click", e => {
      const btn = e.target.closest(".act"); if (!btn) return;
      runAction(btn.dataset.act, it, btn);
    });
    s.appendChild(bar);

    const body = el("div", "sheet-body");
    const sec = (title, n) => {
      const d = el("div", "sheet-sec");
      const h = el("h3", "fold", esc(title));
      if (n != null) h.appendChild(el("span", "n", String(n)));
      h.appendChild(el("span", "chev", foldedSecs[title] ? "▸" : "▾"));
      h.onclick = () => { foldedSecs[title] = !foldedSecs[title]; openDetail(it); };
      d.appendChild(h);
      return d;
    };
    const unfolded = title => !foldedSecs[title];

    const issues = itemIssues(it);
    if (issues) {
      const created = issues.count - issues.open - issues.errors;
      const mix = [issues.open && `${issues.open} to create`, created && `${created} created`, issues.errors && `${issues.errors} unreadable`];
      const row = el("button", "issues-row", `<span class="t">Issues (${issues.count})</span>` +
        `<span class="sub">${mix.filter(Boolean).join(" · ")}</span><span class="go">open ›</span>`);
      row.type = "button";
      row.title = "Review the issue drafts beside this item's chat — no live chat needed";
      row.onclick = () => openIssuesFor(it);
      body.appendChild(row);
    }

    const dsec = sec("Description");
    if (unfolded("Description")) {
      const descText = (it.description && it.description.trim()) || "No description yet.";
      dsec.appendChild(el("div", "desc-text", esc(descText)));
      const chips = branchChips(it);
      if (chips) dsec.appendChild(chips);
    }
    body.appendChild(dsec);

    const lsec = sec("Links", (it.links || []).length);
    if (unfolded("Links")) lsec.appendChild(linksEditor(it));
    body.appendChild(lsec);

    const notes = it.notes || [];
    const nsec = sec("Notes", notes.length);
    if (unfolded("Notes")) {
      const kindsPresent = NOTE_KINDS.filter(k => notes.some(nt => nt.kind === k));
      if (kindsPresent.length > 1) {
        const fr = el("div", "note-filters");
        ["all", ...kindsPresent].forEach(k => {
          const n = k === "all" ? notes.length : notes.filter(nt => nt.kind === k).length;
          const b = el("button", `note-filter ${k}${noteFilter === k ? " on" : ""}`, `${k} <span class="n">${n}</span>`);
          b.onclick = () => { noteFilter = k; openDetail(it); };
          fr.appendChild(b);
        });
        nsec.appendChild(fr);
      }
      const shownNotes = noteFilter === "all" ? notes : notes.filter(nt => nt.kind === noteFilter);
      if (shownNotes.length) {
        nsec.appendChild(noteTimeline(it, shownNotes));
      } else {
        nsec.appendChild(el("div", "desc-text", notes.length ? `No ${noteFilter} notes.` : "No notes yet."));
      }
      const addNote = el("button", "act", "+ Add note"); addNote.style.marginTop = "4px";
      addNote.onclick = () => noteModal(it);
      nsec.appendChild(addNote);
    }
    body.appendChild(nsec);

    const sess = it.sessionList || [];
    const ssec = sec("Sessions", sess.length);
    if (unfolded("Sessions") && !sess.length) ssec.appendChild(el("div", "desc-text", "No sessions attached."));
    if (unfolded("Sessions")) sess.forEach(se => ssec.appendChild(sessionRow(it, se)));
    body.appendChild(ssec);

    if (it.snapshots && it.snapshots.length) {
      const psec = sec("Snapshots", it.snapshots.length);
      if (unfolded("Snapshots")) it.snapshots.forEach(sn => {
        const row = el("div", "tl-note");
        row.appendChild(el("div", "tl-dot"));
        row.appendChild(el("div", "tl-body", `<span class="stamp">${esc(sn.stamp)} · ${esc(short(sn.session))}</span>${esc(sn.text)}`));
        psec.appendChild(row);
      });
      body.appendChild(psec);
    }

    const foot = el("div", "sheet-sec");
    const del = el("button", "act danger", "Delete item…");
    del.title = "Remove a work item made by accident (refused when it holds work, unless you force it)";
    del.onclick = () => deleteItemModal(it);
    foot.appendChild(del);
    body.appendChild(foot);

    s.appendChild(body);
    scrim.appendChild(s);
    document.body.appendChild(scrim);
    openSheet = scrim;
  }, rerender);
}

/* Pieces the detail sheet and the chat view's digest both render. */
function branchChips(it) {
  if (!(it.branches && it.branches.length) && !it.board) return null;
  const bl = el("div", ""); bl.style.marginTop = "11px"; bl.style.display = "flex"; bl.style.flexWrap = "wrap"; bl.style.gap = "6px";
  (it.branches || []).forEach(br => {
    const wt = it.worktrees && it.worktrees[br];
    bl.appendChild(el("span", "branch-chip",
      "⑂ " + esc(br) + (wt ? ` <span class="wt">· ${esc(wt)}</span>` : "")));
  });
  if (it.board) {
    const a = el("a", "branch-chip board-chip", "▤ status board");
    a.href = it.board; a.target = "_blank"; a.rel = "noreferrer";
    a.title = it.board;
    bl.appendChild(a);
  }
  return bl;
}
function noteTimeline(it, notes) {
  const tl = el("div", "timeline");
  notes.forEach(nt => {
    const row = el("div", "tl-note");
    row.appendChild(el("div", "tl-dot"));
    const b = el("div", "tl-body",
      `<span class="stamp">${esc(nt.stamp)}</span>${esc(nt.text)}`);
    b.prepend(kindChip(it, nt));
    row.appendChild(b);
    tl.appendChild(row);
  });
  return tl;
}
/* resumeTo: "warp" (board, detail sheet), "pane" (the chat view, which continues the
   session in the item's pane), or null under a live pane — one live chat per item. */
function sessionRow(it, se, resumeTo = "warp") {
  const row = el("div", "sess-row");
  row.tabIndex = 0;
  row.appendChild(el("span", "sess-tier tier-" + se.tier, se.tier));
  const main = el("div", "sess-main");
  main.appendChild(el("div", "sess-id", short(se.id)));
  main.appendChild(el("div", "sess-prompt", "“" + esc(se.prompt || "no prompt captured") + "”"));
  row.appendChild(main);
  row.appendChild(el("span", "sess-when", esc(se.when)));
  if (resumeTo && se.tier !== "live" && se.tier !== "uncaptured") {
    const rb = el("button", "act", "Resume");
    rb.onclick = resumeTo === "pane"
      ? () => paneAction("pane-resume", it, { session: se.id })
      : () => act("resume", { slug: it.slug, args: { session: se.id } }).then(r => { if (r.ok) toast(`resuming ${short(se.id)} → Warp tab`); });
    row.appendChild(rb);
  }
  const ub = el("button", "act", "Unlink");
  ub.onclick = () => act("detach", { slug: it.slug, args: { session: se.id } }).then(r => { if (r.ok) { toast(`unlinked ${short(se.id)} from ${it.slug}`); refresh(); } });
  row.appendChild(ub);
  row.addEventListener("click", e => { if (!e.target.closest("button")) openSession(it, se); });
  row.addEventListener("keydown", e => { if (e.key === "Enter" && e.target === row) openSession(it, se); });
  return row;
}
