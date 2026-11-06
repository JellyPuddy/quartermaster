"use strict";

/* ------- long actions (pf switch, worktree creation, cleanup) -------
   They run on server threads; the item carries the job's label as a badge
   meanwhile, and a later state build hands the outcome over once. */
function jobFor(key) { return jobs.find(j => j.key === key); }
function jobFinished(r) {
  if (automationJobFinished(r)) return;
  // A job may have created a worktree or moved pf: every cached target is suspect.
  Object.keys(wsCache).forEach(k => delete wsCache[k]);
  if (r.ok) toast(r.message || `${r.key}: done`); else toast(r.error || `${r.key}: failed`, false);
  if (r.warning) toast(r.warning, false);
  if (r.ok && r.switched && r.path) updateOffer = { slug: r.key, path: r.path };
  // A PR job may have created the worktree its row shows.
  if (mode === "prs") loadPrs();
  reviewPostFinished(r);
  branchStatsJobFinished(r);
  issueStartFinished(r);
}

/* Header badge: "<command>: <mode> @ <worktree>", with Stop while it serves;
   hidden when no project configures a dev server. */
function renderPfBadge() {
  const box = $("#pf-badge");
  box.hidden = !pf.command;
  if (box.hidden) return;
  const cmd = pf.command;
  const job = jobs.find(j => j.pf);
  box.className = "pf-badge" + (job || pf.switching ? " busy" : pf.running ? " running" : "");
  box.innerHTML = "";
  box.appendChild(el("span", "pf-dot"));
  let text = `${cmd}: stopped`;
  if (job) text = job.key === "pf" ? `${cmd}: stopping…` : `${cmd}: switching for ${job.key}…`;
  else if (pf.switching) text = `${cmd}: switching to ${pf.mode} @ ${pf.worktree}…`;
  else if (pf.running) text = `${cmd}: ${pf.mode} @ ${pf.worktree}`;
  box.appendChild(el("span", "pf-text", esc(text)));
  box.title = (pf.short ? `${pf.running ? "serving" : "last served"}: ${pf.mode} @ ${pf.short}` : `the dev server (${cmd})`) + (pf.off ? ` — ${pf.off}` : "");
  if (pf.running && !job) {
    const stop = el("button", "act", "Stop");
    stop.title = pf.off || `${cmd} stop`;
    stop.disabled = !!pf.off;
    stop.onclick = () => act("pf-stop").then(r => { if (r.ok) toast(`stopping ${cmd}…`); });
    box.appendChild(stop);
  }
}
function headerMenu(anchor) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "qm"));
    const b = el("button", "", "Sweep orphan worktrees…");
    b.title = "qm sweep: every .claude/worktrees worktree and worktree-* branch nobody needs any more";
    b.onclick = () => { closePop(); cleanupModal("sweep"); };
    p.appendChild(b);
  });
}

function card(it, found) {
  const c = el("div", "card");
  c.dataset.slug = it.slug;
  c.tabIndex = 0;
  c.style.setProperty("--dotcolor", `var(--${it.state === "in_progress" ? "accent" : it.state === "fridge" ? "warn" : it.state === "active" ? "turn" : "good"})`);

  const top = el("div", "card-top");
  top.appendChild(el("span", "status-dot dot-" + it.state));
  top.appendChild(el("span", "slug", esc(it.slug)));
  if (it.live) top.appendChild(el("span", "live-dot", "live"));
  if (it.served) top.appendChild(servedMark());
  top.appendChild(el("span", "sess", (it.sessions || 0) + " sess"));
  c.appendChild(top);

  c.appendChild(el("div", "title-line", esc(it.title)));

  const meta = el("div", "meta");
  meta.innerHTML = `${esc(it.project)} <span class="sep">·</span> updated ${esc(it.updated)}`;
  c.appendChild(meta);

  const cardBadges = badgesOf(it);
  if (cardBadges.length) {
    const b = el("div", "badges");
    cardBadges.forEach(bd => b.appendChild(el("span", "badge " + bd.type, esc(bd.label))));
    c.appendChild(b);
  }

  if (found && found.why) {
    c.appendChild(el("div", "hit", `<span class="where">✦</span>${esc(found.why)}`));
  } else if (found && found.hit) {
    c.appendChild(el("div", "hit", `<span class="where">${esc(found.hit.where)}</span>${snippet(found.hit)}`));
  }

  if (it.note) {
    const n = el("div", "note", `<span class="stamp">▸ ${esc(it.note.stamp)}</span> ${esc(it.note.text)}`);
    if (it.note.kind === "open") n.prepend(el("span", "kind-chip open", "open"));
    c.appendChild(n);
  }

  const acts = el("div", "actions");
  acts.appendChild(action("resume", "strong grow", '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 3v18M9 5l10 7-10 7z" fill="currentColor" stroke="none"/></svg>Resume', "r"));
  acts.appendChild(action("start", "grow", "Start", "n"));
  acts.appendChild(action("state", "grow", "State ▾", "s"));
  acts.appendChild(action("more", "", "⋯", "."));
  // Cards are the only tab stops; their actions have bare-key shortcuts and are
  // clickable, so keep them out of the tab order — otherwise Tab lands on a
  // button while j/k moves the card highlight, and the two selections diverge.
  acts.querySelectorAll("button").forEach(b => b.tabIndex = -1);
  c.appendChild(acts);
  return c;
}
function servedMark() {
  const s = el("span", "served", "🖥");
  s.title = `${devCmd()} serves this item's worktree (${pf.mode || "?"})`;
  return s;
}
function action(act, extra, label, key) {
  const b = el("button", "act " + extra, label + (key ? ` <kbd>${key}</kbd>` : ""));
  b.dataset.act = act;
  return b;
}

function renderInbox() {
  $("#inbox-count").textContent = inbox.length;
  const body = $("#inbox-body");
  keepScroll(body, () => {
    body.innerHTML = "";
    if (!inbox.length) { body.appendChild(el("div", "col-empty", "inbox clear")); return; }
    inbox.forEach(s => {
      const it = el("div", "inbox-item");
      it.dataset.id = s.id;
      it.tabIndex = 0;
      it.addEventListener("keydown", e => { if (e.key === "Enter" && e.target === it) openSession(null, s); });
      it.appendChild(el("div", "inbox-prompt", '“' + esc(s.prompt) + '”'));
      it.appendChild(el("div", "inbox-meta", short(s.id) + " · " + esc(s.when) + " · " + esc(s.cwd)));
      const acts = el("div", "inbox-acts");
      acts.appendChild(action("attach", "strong", "Attach", ""));
      acts.appendChild(action("mk-item", "", "New item", ""));
      acts.appendChild(action("dismiss", "", "Dismiss", ""));
      it.appendChild(acts);
      body.appendChild(it);
    });
  });
}
