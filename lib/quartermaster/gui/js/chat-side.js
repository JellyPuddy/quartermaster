"use strict";

const sessionsOpen = {};

/* The digest a new session of this item is told about: the description plus
   the injected notes, rendered with the detail sheet's pieces. */
function renderChatSide() {
  const side = $("#chat-side");
  // A state poll must not wipe what the user is typing (a board answer) or the
  // select he has open; the panel catches up on the next render.
  const active = document.activeElement;
  if (active && side.contains(active) && /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName)) return;
  keepScroll(side, () => {
    side.innerHTML = "";
    const it = items.find(i => i.slug === chatSlug);
    if (!it) return;
    const head = el("div", "side-head");
    head.appendChild(el("span", "col-title", "Item"));
    const full = el("button", "act", "Full detail <kbd>i</kbd>");
    full.tabIndex = -1;
    full.onclick = () => openDetail(it);
    head.appendChild(full);
    side.appendChild(head);
    const body = el("div", "sheet-body");
    body.append(...[chatEpicSection(it)].filter(Boolean), workspaceSection(it));
    const dsec = el("div", "sheet-sec");
    dsec.appendChild(el("h3", "", "Description"));
    dsec.appendChild(el("div", "desc-text", esc((it.description && it.description.trim()) || "No description yet.")));
    body.appendChild(dsec);
    if (it.board) body.appendChild(boardSection(it));
    const notes = it.notes || [];
    const injected = notes.filter(nt => (it.injected || []).includes(nt.position));
    const nsec = el("div", "sheet-sec");
    const h = el("h3", "", "Carried notes");
    h.appendChild(el("span", "n", `${injected.length} of ${notes.length}`));
    h.title = "The notes every new session of this item is told about";
    nsec.appendChild(h);
    if (injected.length) nsec.appendChild(noteTimeline(it, injected));
    else nsec.appendChild(el("div", "desc-text", notes.length ? "Only history notes so far; none are carried." : "No notes yet."));
    const addNote = el("button", "act", "+ Add note"); addNote.style.marginTop = "4px";
    addNote.onclick = () => noteModal(it);
    nsec.appendChild(addNote);
    body.appendChild(nsec);
    side.appendChild(body);
    if (it.usage) side.appendChild(usageFoot(it));
  }, sameSubject(side, chatSlug));
}

/* "1.2M tok · ~$14" with a per-session breakdown. Remembered
   open across the state polls that rebuild the panel. */
let usageOpen = false;
function usageFoot(it) {
  const u = it.usage;
  const foot = el("div", "usage-foot" + (usageOpen ? " open" : ""));
  const btn = el("button", "", `<span>${esc(u.line)}</span><span class="hint">per session</span>`);
  btn.tabIndex = -1;
  btn.title = "API-equivalent estimate from the transcripts' token usage, sub-agents and asides included";
  btn.onclick = () => { usageOpen = !usageOpen; foot.classList.toggle("open", usageOpen); };
  const brk = el("div", "usage-break");
  u.sessions.forEach(s => {
    const what = `${short(s.id)} · ${s.aside ? "aside · " : ""}${s.when}` + (s.agents ? ` · ${s.agents} agent${s.agents === 1 ? "" : "s"}` : "");
    const row = el("div", "row" + (s.known ? "" : " missing"),
      `<span class="what">${esc(what)}</span>` +
      `<span class="num">${s.known ? esc(s.tokensLabel) : "?"}</span>` +
      `<span class="num">${s.known ? "~" + esc(s.costLabel) + (s.unpriced.length ? "+" : "") : "expired"}</span>`);
    row.title = s.id + (Object.keys(s.models || {}).length ? "\n" + Object.entries(s.models).map(([m, n]) => `${m}: ${n.toLocaleString()} tok`).join("\n") : "");
    brk.appendChild(row);
  });
  const notes = [];
  if (u.lowerBound) notes.push("≥: a session expired before qm tallied it.");
  if (u.partial) notes.push(`partial: no price for ${u.unpriced.join(", ")} (add it under prices: in config.yml).`);
  if (notes.length) brk.appendChild(el("div", "foot", esc(notes.join(" "))));
  foot.append(btn, brk);
  return foot;
}

/* Where "work on this" lands (docs/areas/worktrees.md): fetched per item and
   selected branch, since resolving it costs a git worktree listing the
   state build shouldn't pay for every item. Refetched on chat selection,
   on another branch selected and after any job. Each answer also says where
   the chat runs and the default selection (stacks.js). */
function workspaceFor(it) {
  const slug = it.slug;
  const branch = workspaceBranchFor(it) || "";
  const cached = wsCache[slug];
  if (cached && cached.query === branch) return cached;
  if (wsLoading[slug] === undefined) {
    wsLoading[slug] = branch;
    fetch("/api/workspace/" + encodeURIComponent(slug) + (branch ? "?branch=" + encodeURIComponent(branch) : ""))
      .then(r => r.json())
      .then(d => {
        wsCache[slug] = { ...d, query: branch };
        if (d.ok) chatBranches[slug] = { chat: d.chatBranch || null, def: d.defaultBranch || null };
      })
      .catch(() => { wsCache[slug] = { ok: false, error: "could not reach qm", query: branch }; })
      .finally(() => {
        delete wsLoading[slug];
        // The default selection may have just become known: the diff pane follows it.
        if (mode === "chat" && chatSlug === slug) { renderChatSide(); syncDiffPane(); }
      });
  }
  return cached || null;
}

function workspaceSection(it) {
  const sec = el("div", "sheet-sec");
  sec.appendChild(el("h3", "", "Workspace"));
  const job = jobFor(it.slug);
  if (job) {
    const b = el("div", "badges"); b.style.margin = "0 0 10px";
    b.appendChild(el("span", "badge distilling", esc(job.label)));
    sec.appendChild(b);
  }
  if (itemChains(it).length) sec.appendChild(workspaceRails(it));
  const ws = workspaceFor(it);
  // A stale answer (another branch was selected) shows until the new one lands.
  if (!ws) { sec.appendChild(el("div", "muted-text", "finding the worktree…")); return sec; }
  if (!ws.ok) { sec.appendChild(el("div", "desc-text", esc(ws.error))); return sec; }

  const t = ws.target;
  const line = el("div", "ws-target");
  if (t.branch) line.appendChild(el("span", "", "⑂ " + esc(t.branch)));
  if (t.create) {
    line.appendChild(el("span", "path new", "@ new worktree"));
    line.appendChild(el("span", "new", "· created on first use"));
    line.title = t.path;
  } else {
    line.appendChild(el("span", "path", "@ " + esc(t.short)));
  }
  sec.appendChild(line);
  const stale = stalePfText(it);
  if (stale) sec.appendChild(el("div", "ws-warning stale-pf", `⚠ ${esc(stale)} — Switch ${esc(devCmd())} serves the selected branch`));
  if (t.warning) sec.appendChild(el("div", "ws-warning", "⚠ " + esc(t.warning)));

  // Name the mode on the switch whenever it isn't what already runs.
  const dev = ws.devServer; // { command, modes, mode } when the item's project has a dev server
  const modeNote = dev && (!pf.running || pf.mode !== dev.mode) ? ` · ${dev.mode}` : "";
  const bar = el("div", "ws-actions");
  // The branch this answer was resolved for: the actions land on that same target.
  const branch = ws.query || ws.defaultBranch || null;
  const fresh = ws.query === (workspaceBranchFor(it) || ""); // else the answer for the newly selected branch is on its way
  const where = t.create ? `a new worktree for ${t.branch}` : t.short;
  const run = (cmd, label) => {
    const args = branch ? { branch } : {};
    act(cmd, { slug: it.slug, args }).then(r => { if (r.ok) toast(`${it.slug}: ${label} — running in the background`); });
  };
  const button = (cls, label, cmd, what, title, off = null) => {
    const b = el("button", "act " + cls, esc(label));
    b.disabled = !!job || !fresh || !!off;
    b.title = off || title;
    b.onclick = () => run(cmd, what);
    bar.appendChild(b);
  };
  const ide = ws.ide; // { label, command } when an IDE is configured (ide_command)
  const ideTitle = ide && ide.command.map(a => a.split("PATH").join(where)).join(" ");
  if (dev) {
    if (ide) button("primary", "Work on this" + modeNote, "work-on", "work on this", `${dev.command} switch + open in ${ide.label}, in ${where}`, pf.off);
    button(ide ? "" : "primary", `Switch ${dev.command}` + modeNote, "pf-switch", `${dev.command} switch`, `${dev.command} switch ${where} ${dev.mode}`, pf.off);
    if (ide) button("", `Open in ${ide.label}`, "ide", `opening ${ide.label}`, ideTitle);
  } else if (ide) {
    button("strong", `Open in ${ide.label}`, "ide", `opening ${ide.label}`, ideTitle);
  }
  button("", "Terminal", "terminal", "opening a Warp tab", `New Warp tab in ${where}`);
  // Nothing to adopt in a worktree that doesn't exist yet.
  if (ws.root && !t.create && t.path !== ws.root) {
    const adopt = el("button", "act", "Adopt worktree…");
    adopt.disabled = !!job || !fresh;
    adopt.title = `/adopt-worktree ${t.short} in this item's chat`;
    adopt.onclick = () => adoptModal(it, t);
    bar.appendChild(adopt);
  }
  sec.appendChild(bar);

  if (dev) {
    const row = el("div", "ws-row");
    row.appendChild(el("span", "", `${esc(dev.command)} mode`));
    const sel = el("select", "mode-chip", dev.modes.map(m => `<option${m === dev.mode ? " selected" : ""}>${esc(m)}</option>`).join(""));
    sel.title = `This item's ${dev.command} mode (qm pf-mode)`;
    sel.onchange = () => {
      const m = sel.value;
      sel.blur();
      act("pf-mode", { slug: it.slug, args: { mode: m } }).then(r => {
        delete wsCache[it.slug];
        if (r.ok) toast(`${it.slug} → ${dev.command} ${m}`);
        renderChatSide();
      });
    };
    row.appendChild(sel);
    if (it.served) row.appendChild(el("span", "", `· 🖥 ${esc(dev.command)} serves it now (${esc(pf.mode)})`));
    sec.appendChild(row);
  }

  if (updateOffer && updateOffer.slug === it.slug) {
    const offer = el("div", "ws-offer", `<span>${esc(devCmd())} switched — dependencies or migrations may lag.</span>`);
    const go = el("button", "act strong", "Run bin/update");
    go.title = `bin/update in ${updateOffer.path} (its own tmux session)`;
    go.onclick = () => act("run-update", { args: { path: updateOffer.path } }).then(r => {
      if (r.ok) { terminalModal(r.session, `bin/update · ${updateOffer.path.split("/").pop()}`); updateOffer = null; renderChatSide(); }
    });
    const x = el("button", "x", "✕"); x.title = "Dismiss";
    x.onclick = () => { updateOffer = null; renderChatSide(); };
    offer.append(go, x);
    sec.appendChild(offer);
  }

  const tidy = el("button", "act", "Clean up worktrees…");
  tidy.style.marginTop = "10px";
  tidy.onclick = () => cleanupModal(it.slug);
  sec.appendChild(tidy);
  return sec;
}

/* Adopt runs the /adopt-worktree skill in the item's chat (typed into the
   live pane, or as a fresh chat's first prompt in the main checkout), then
   shows that chat: the skill may need answers along the way. */
function adoptModal(it, wt) {
  modal(m => {
    m.innerHTML = `<h2>Adopt worktree?</h2><p class="sub">${esc(it.slug)}</p>
      <p style="margin:12px 0">Runs <code>/adopt-worktree</code> in this item's chat: it removes
      <code>${esc(wt.short)}</code> and checks out ${wt.branch ? `<code>${esc(wt.branch)}</code>` : "its branch"} in the main checkout
      (moving the IDE there if it has the worktree open).</p>`;
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const go = el("button", "btn primary", "Adopt");
    go.onclick = () => {
      closeModal();
      act("adopt", { slug: it.slug, args: { worktree: wt.path } }).then(r => {
        if (!r.ok) return;
        toast(r.attached ? `${it.slug}: /adopt-worktree typed into its chat` : `${it.slug}: new chat adopting ${wt.short}`);
        delete wsCache[it.slug];
        if (!panes.includes(it.slug)) panes = panes.concat(it.slug);
        renderChatMain();
        chatTerm.focus();
      });
    };
    bar.append(cancel, go); m.appendChild(bar);
  });
}

/* ------- the rails: the Workspace's branch picker (docs/areas/stacks.md) -------
   One rail per chain: a stack's layers top first above its trunk, a loose
   branch as a one-node rail. A click on a node only selects it (stacks.js);
   the selected node offers 📊, 🏁 and "Diff ›". Merged layers fold into one line, and
   with three or more chains the ones not holding the selection fold to a
   summary line. Both remembered across the state polls that rebuild the panel. */
const railMergedOpen = new Set(); // "slug|bottom branch": a stack's merged layers unfolded
const railChainOpen = new Set();  // "slug|top branch": a folded chain opened

function workspaceRails(it) {
  const chains = itemChains(it);
  const selected = selectedBranch(it);
  const box = el("div", "rails");
  const fold = chains.length >= 3;
  chains.forEach(c => {
    const holds = c.layers.some(l => l.branch === selected);
    const key = `${it.slug}|${chainTop(c)}`;
    if (fold && !holds && !railChainOpen.has(key)) box.appendChild(railSummary(it, c, key));
    else box.appendChild(rail(it, c, selected, fold && !holds ? key : null));
  });
  return box;
}

function rail(it, c, selected, foldKey) {
  const r = el("div", "rail " + c.kind);
  if (foldKey) {
    const up = el("button", "rail-fold", "▴ fold");
    up.title = "Fold this chain to one line";
    up.onclick = () => { railChainOpen.delete(foldKey); renderChatSide(); };
    r.appendChild(up);
  }
  const stack = c.kind === "stack";
  const prefix = stack ? chainPrefix(c) : "";
  const numbered = c.layers.map((l, i) => ({ l, n: i + 1 }));
  const open = numbered.filter(x => !x.l.merged).reverse();
  const merged = numbered.filter(x => x.l.merged).reverse();
  const mergedKey = `${it.slug}|${c.layers[0].branch}`;
  // A selected merged layer stays in view.
  const showMerged = railMergedOpen.has(mergedKey) || merged.some(x => x.l.branch === selected);
  const node = x => railNode(it, c, x.l, x.n, prefix, x.l.branch === selected);
  open.forEach(x => r.appendChild(node(x)));
  if (merged.length) {
    if (showMerged) merged.forEach(x => r.appendChild(node(x)));
    const m = el("div", "rail-node rail-merged");
    m.appendChild(el("span", "rail-dot merged", "✓"));
    m.appendChild(el("span", "rail-mline", `${merged.length} merged ${showMerged ? "▴" : "▾"}`));
    m.title = merged.map(x => `${circled(x.n)} ${x.l.branch}`).join("\n");
    m.onclick = () => { if (railMergedOpen.has(mergedKey)) railMergedOpen.delete(mergedKey); else railMergedOpen.add(mergedKey); renderChatSide(); };
    r.appendChild(m);
  }
  if (stack) {
    const trunk = el("div", "rail-node rail-trunk");
    trunk.appendChild(el("span", "rail-dot trunk", ""));
    trunk.appendChild(el("span", "rail-branch", esc(String(c.trunk || "main").replace(/^origin\//, ""))));
    trunk.title = "the stack's trunk";
    r.appendChild(trunk);
  }
  return r;
}

function railNode(it, c, l, n, prefix, isSelected) {
  const stack = c.kind === "stack";
  const status = layerStatus(l);
  const node = el("div", "rail-node" + (isSelected ? " selected" : "") + (l.merged ? " merged" : ""));
  node.dataset.branch = l.branch;
  node.appendChild(el("span", "rail-dot " + status, stack ? String(n) : "⑂"));
  const main = el("div", "rail-main");
  const top = el("div", "rail-line");
  top.appendChild(el("span", "rail-branch", esc(l.branch.slice(prefix.length) || l.branch)));
  if (stack && n === c.layers.length && c.layers.length > 1) top.appendChild(el("span", "rail-top", "top"));
  if ((chatBranches[it.slug] || {}).chat === l.branch) {
    const chat = el("span", "rail-chat", "◆ chat");
    chat.title = "The chat runs on this branch";
    top.appendChild(chat);
  }
  if (it.servedBranch === l.branch) {
    const s = el("span", "served", "🖥");
    s.title = stalePfText(it) || `${devCmd()} serves this checkout (${pf.mode || "?"})`;
    top.appendChild(s);
  }
  main.appendChild(top);
  const meta = el("div", "rail-line");
  const chip = layerPrChip(l);
  if (chip) meta.appendChild(chip);
  if (stack && l.ahead != null) meta.appendChild(el("span", "rail-ahead", `${l.ahead} commit${l.ahead === 1 ? "" : "s"}`));
  if (stack && l.needsRestack && !l.merged) {
    const r = el("button", "rail-restack", "⟳ restack");
    r.title = `${l.parent}'s tip is not in this branch — ask the chat to restack the stack (gh stack rebase)`;
    r.onclick = e => { e.stopPropagation(); restackStack(it, l.branch); };
    meta.appendChild(r);
  }
  if (isSelected) meta.appendChild(railTools(it, l.branch));
  if (meta.childNodes.length) main.appendChild(meta);
  const wt = it.worktrees && it.worktrees[l.branch];
  if (wt) {
    const w = el("div", "rail-line");
    const chip = el("span", "wt-chip", `<span class="p">${esc(wt)}</span>`);
    chip.title = wt;
    w.appendChild(chip);
    main.appendChild(w);
  } else if (isSelected) {
    main.appendChild(el("div", "rail-line rail-nowt", "no checkout — the Workspace buttons add a worktree"));
  }
  node.appendChild(main);
  node.title = l.branch + (stack ? `\nparent: ${l.parent}` : "");
  node.onclick = () => { if (!isSelected) setSelectedBranch(it.slug, l.branch); };
  return node;
}

/* A folded chain: one line, a click opens it. */
function railSummary(it, c, key) {
  const line = el("div", "rail-summary");
  if (c.kind === "stack") {
    const merged = c.layers.filter(l => l.merged).length;
    const behind = c.layers.filter(l => l.needsRestack && !l.merged).length;
    line.appendChild(el("span", "rail-dot " + layerStatus(c.layers[c.layers.length - 1]), String(c.layers.length)));
    line.appendChild(el("span", "rail-branch", esc(chainTop(c))));
    line.appendChild(el("span", "rail-ahead", `${c.layers.length} layers${merged ? ` · ${merged} merged` : ""}`));
    if (behind) line.appendChild(el("span", "restack-count", `⟳ ${behind}`));
  } else {
    const l = c.layers[0];
    const status = layerStatus(l);
    line.appendChild(el("span", "rail-dot " + status, "⑂"));
    line.appendChild(el("span", "rail-branch", esc(l.branch)));
    line.appendChild(el("span", "rail-ahead", (l.pr_number ? `#${l.pr_number} ` : "") + LAYER_STATUS_LABEL[status]));
  }
  line.title = c.layers.map(l => l.branch).join("\n");
  line.onclick = () => { railChainOpen.add(key); renderChatSide(); };
  return line;
}

/* The item's status board, mirrored from board-writes.jsonl,
   grouped like the artifact: one foldable group per build batch, newest
   first (the server's row order), the newest open and earlier ones folded.
   A batch with a blocked row opens too — it is waiting on an answer.
   A blocked row gets an answer box when the run's answers directory is known. */
function boardSection(it) {
  const sec = el("div", "sheet-sec");
  const rows = it.boardRows || [];
  const h = el("h3", "", "Board");
  h.appendChild(el("span", "n", String(rows.length)));
  const link = el("a", "branch-chip board-chip", "open ↗");
  link.href = it.board; link.target = "_blank"; link.rel = "noreferrer"; link.title = it.board;
  link.style.cssText = "margin-left:auto;text-transform:none;letter-spacing:0;font-weight:500;padding:1px 7px";
  h.appendChild(link);
  sec.appendChild(h);
  if (buildActive.includes(it.slug)) sec.appendChild(progressBlock(it));
  if (!rows.length) sec.appendChild(el("div", "muted-text", "no board writes mirrored yet"));
  const groups = boardBatches(rows);
  groups.forEach((g, i) => {
    const key = `${it.slug}#${g.key}`;
    const current = i === 0;
    const byDefault = current || g.rows.some(r => rowStatus(r) === "blocked");
    const open = foldedBatches.has(key) ? !byDefault : byDefault;
    if (groups.length > 1) {
      const head = el("div", "batch-head" + (current ? " current" : ""));
      head.appendChild(el("span", "chev", open ? "▼" : "▶"));
      head.appendChild(el("span", "batch-name", esc(g.label)));
      head.appendChild(Object.assign(el("span", "batch-sum", esc(batchSummary(g.rows, true))), { title: batchSummary(g.rows) }));
      head.onclick = () => { foldedBatches.has(key) ? foldedBatches.delete(key) : foldedBatches.add(key); renderChatSide(); };
      sec.appendChild(head);
    }
    if (open) g.rows.forEach(r => sec.appendChild(boardRow(it, r)));
  });
  return sec;
}
/* "How far along is each agent now?" — only on a click: one haiku call over
   the live transcripts of every active sub-agent of the item's running
   Workflow runs. The newest answer shows here with its time; a click
   replaces it. */
function progressBlock(it) {
  const box = el("div", "progress-box");
  const busy = jobs.some(j => j.key === `progress:${it.slug}`);
  const btn = el("button", "act", busy ? "estimating…" : "Check build progress");
  btn.tabIndex = -1;
  btn.disabled = busy;
  btn.title = "Ask haiku how far each running sub-agent of this item's builds is";
  btn.onclick = () => act("build-progress", { slug: it.slug });
  const head = el("div", "progress-head");
  head.appendChild(btn);
  box.appendChild(head);
  const p = buildProgress[it.slug];
  if (!p) return box;
  const at = new Date(p.taken_at);
  const when = el("span", "progress-when", esc(`${at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} · ${agoText(p.taken_at)}`));
  when.title = `estimated at ${at.toLocaleString()}`;
  head.appendChild(when);
  if (!p.ok) box.appendChild(el("div", "board-note progress-error", esc(p.error || "failed")));
  else if (p.raw) box.appendChild(el("div", "board-note", esc(p.raw)));
  else if (!p.agents.length) box.appendChild(el("div", "muted-text", "nothing running"));
  p.agents && p.agents.forEach(a => {
    const line = el("div", "progress-line");
    line.appendChild(el("span", "progress-pct", a.percent == null ? "?" : `≈${a.percent}%`));
    line.appendChild(el("span", "progress-label", esc(a.task)));
    line.appendChild(el("span", "progress-doing", esc(a.doing)));
    box.appendChild(line);
  });
  return box;
}
function boardBatches(rows) {
  const groups = [];
  rows.forEach(r => {
    const key = r.batch || "";
    let g = groups.find(x => x.key === key);
    if (!g) groups.push(g = { key, label: r.batchLabel || r.batch || "Earlier tasks", rows: [] });
    g.rows.push(r);
  });
  // Batch ids are ISO-prefixed: newest first, rows predating batches last.
  return groups.sort((a, b) => !a.key - !b.key || b.key.localeCompare(a.key));
}
const STATUS_GLYPHS = { done: "✓", merged: "✓", running: "▶", reviewing: "▶", queued: "○", blocked: "!", failed: "✗" };
function batchSummary(rows, short = false) {
  const counts = {};
  rows.forEach(r => { const s = rowStatus(r); counts[s] = (counts[s] || 0) + 1; });
  return Object.entries(counts).map(([s, n]) => short && STATUS_GLYPHS[s] ? `${n}${STATUS_GLYPHS[s]}` : `${n} ${s}`).join(short ? " " : " · ");
}
const rowStatus = r => String(r.status || "unset").toLowerCase();
function boardRow(it, r) {
  const status = rowStatus(r);
  const row = el("div", "board-row" + (status === "blocked" ? " blocked" : ""));
  const top = el("div", "board-top");
  top.appendChild(el("span", "row-status " + status, esc(status)));
  top.appendChild(el("span", "board-title", esc(r.title || r.doc_id)));
  top.appendChild(el("span", "board-id", esc(r.doc_id)));
  row.appendChild(top);
  if (r.note) row.appendChild(el("div", "board-note", esc(r.note)));
  if (r.dependsOn && r.dependsOn.length) row.appendChild(el("div", "board-deps", "after " + r.dependsOn.map(esc).join(", ")));
  if (status === "blocked") row.appendChild(answerBox(it, r));
  return row;
}
function answerBox(it, r) {
  if (!it.board_answers_dir) {
    return el("div", "board-deps", `no answers directory known — qm board ${esc(it.slug)} URL --answers-dir DIR`);
  }
  const key = `${it.slug}#${r.doc_id}`;
  const box = el("div", "answer-box");
  const ta = el("textarea");
  ta.placeholder = "Answer — STOP to make it hand back";
  ta.value = answerDrafts[key] || "";
  ta.oninput = () => { answerDrafts[key] = ta.value; };
  const send = el("button", "act strong", "Send answer");
  send.title = `writes ${it.board_answers_dir}/${r.doc_id}.md`;
  send.onclick = () => {
    const text = ta.value.trim();
    if (!text) { ta.focus(); return; }
    act("board-answer", { slug: it.slug, args: { doc_id: r.doc_id, text } }).then(res => {
      if (res.ok) { delete answerDrafts[key]; ta.blur(); toast(`answered ${r.doc_id}`); renderChatSide(); }
    });
  };
  ta.addEventListener("keydown", e => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") send.click(); });
  box.append(ta, send);
  return box;
}
