"use strict";

/* ------- cleanup checklist (docs/areas/worktrees.md) -------
   The planner's entries: ok ones start ticked, a ⚠ one is unticked with its
   reasons and needs a per-entry force behind a second confirm, a ⛔ one can't
   be ticked at all. Removal runs server-side on a thread against a fresh
   plan; the outcome arrives as a toast. */
function resolveHeading(plan) {
  const n = plan.entries.filter(e => e.kind === "worktree").length;
  if (n) return `Resolved. Clean up ${n} worktree${n === 1 ? "" : "s"}?`;
  return plan.entries.some(e => e.kind === "branch") ? "Resolved. Clean up its branches?" : "Resolved. Clean up its issue drafts?";
}
const CLEANUP_KINDS = { worktree: "worktree", branch: "branch", "issue-draft": "issue draft" };
async function cleanupModal(scope, plan, heading) {
  heading = heading || (scope === "sweep" ? "Sweep orphan worktrees" : "Clean up worktrees");
  modal(m => {
    m.classList.add("wide");
    m.innerHTML = `<h2>${esc(heading)}</h2><p class="sub">${esc(scope)} · planning — checking every worktree…</p>`;
  });
  const shown = openModal;
  if (!plan) {
    try {
      const r = await fetch("/api/cleanup-plan", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ scope }) });
      const res = await r.json();
      if (openModal !== shown) return;
      if (!res.ok) { closeModal(); toast(res.error || "planning failed", false); return; }
      plan = res.plan;
    } catch (e) { if (openModal === shown) closeModal(); toast("network error", false); return; }
  }
  if (openModal !== shown) return;
  renderCleanup(shown.querySelector(".modal"), scope, plan, heading);
}
function renderCleanup(m, scope, plan, heading) {
  const checked = new Set(plan.entries.filter(e => e.ticked).map(e => e.id));
  const forced = new Set();
  let confirming = null;
  // A branch checked out in a worktree can only go with it: ticking the
  // worktree ticks its ok branch along, unticking it drops the branch too.
  const dependents = e => plan.entries.filter(d => d.requires === e.id && d.status === "ok");
  const tick = e => { checked.add(e.id); dependents(e).forEach(d => checked.add(d.id)); };
  const untick = e => { checked.delete(e.id); forced.delete(e.id); dependents(e).forEach(d => checked.delete(d.id)); };
  const draw = () => keepScroll(m, () => {
    m.innerHTML = `<h2>${esc(heading)}</h2><p class="sub">${esc(scope)} · ${esc(plan.summary)}</p>`;
    (plan.notes || []).forEach(n => m.appendChild(el("p", "cl-note", esc(n))));
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", plan.entries.length ? "Cancel" : "Close"); cancel.onclick = closeModal;
    bar.appendChild(cancel);
    if (!plan.entries.length) { m.appendChild(el("p", "cl-note", "Nothing to clean up.")); m.appendChild(bar); return; }

    const list = el("div", "cl-list");
    plan.entries.forEach(e => list.appendChild(entryRow(e)));
    m.appendChild(list);
    const n = checked.size;
    const go = el("button", "btn " + (forced.size ? "danger" : "primary"), n ? `Remove ${n}${forced.size ? ` (${forced.size} forced)` : ""}` : "Nothing ticked");
    go.disabled = !n;
    go.onclick = () => {
      const force = [...forced];
      const selected = [...checked].filter(id => !forced.has(id));
      act("cleanup", { args: { scope, selected, force } }).then(r => {
        if (r.ok) { closeModal(); toast(`cleaning up ${n} entr${n === 1 ? "y" : "ies"} in the background…`); }
      });
    };
    bar.appendChild(go);
    m.appendChild(bar);
  });
  const entryRow = e => {
    const row = el("div", "cl-entry " + e.status);
    const cb = el("input");
    cb.type = "checkbox";
    cb.checked = checked.has(e.id);
    cb.disabled = e.status === "blocked" || (e.status === "warn" && !forced.has(e.id));
    cb.title = e.status === "blocked" ? "blocked — can't be removed" : e.status === "warn" ? "needs a look — force it to remove" : "";
    cb.onchange = () => { if (cb.checked) tick(e); else untick(e); draw(); };
    row.appendChild(cb);
    const mark = e.status === "warn" ? "⚠ " : e.status === "blocked" ? "⛔ " : "";
    const target = e.kind === "worktree"
      ? `${esc(e.short || e.path)} <span class="b">(${esc(e.branch || "detached")})</span>`
      : e.kind === "issue-draft"
        ? `${esc(e.title || "")} <span class="b">(${esc((e.path || "").split("/").pop())})</span>`
        : `${esc(e.branch)}`;
    const t = el("div", "cl-target", `${mark}<span class="k">${CLEANUP_KINDS[e.kind] || esc(e.kind)}</span>${target}`);
    if (forced.has(e.id)) t.appendChild(el("span", "forced", "forced"));
    row.appendChild(t);
    const side = el("div", "");
    if (e.status === "warn" && !forced.has(e.id) && confirming !== e.id) {
      const f = el("button", "act", "Force…");
      f.onclick = () => { confirming = e.id; draw(); };
      side.appendChild(f);
    }
    row.appendChild(side);
    (e.reasons || []).forEach(r => row.appendChild(el("div", "cl-reason", esc(r))));
    const details = [...(e.notes || [])];
    if (e.db_names && e.db_names.length) details.push("test DBs: " + e.db_names.join(", "));
    if (e.requires) details.push("goes only once its worktree does");
    if (e.item && scope === "sweep") details.push("item: " + e.item);
    if (details.length) row.appendChild(el("div", "cl-detail", esc(details.join(" · "))));
    if (confirming === e.id) {
      const c = el("div", "cl-confirm", `<span class="grow">Remove it anyway, despite the above? This can't be undone.</span>`);
      const no = el("button", "btn", "Keep it"); no.onclick = () => { confirming = null; draw(); };
      const yes = el("button", "btn danger", "Force remove");
      yes.onclick = () => { confirming = null; forced.add(e.id); tick(e); draw(); };
      c.append(no, yes);
      row.appendChild(c);
    }
    return row;
  };
  draw();
}

/* An explicit selection (a click on a row, opening a chat from the board or
   the PRs view) lands in that chat's terminal; j/k only move the highlight. */
let wantsTermFocus = null;
const focusIsIdle = () => {
  const f = document.activeElement;
  return !openModal && !openSheet && !openSessSheet && !openPop && (!f || f === document.body || !!f.closest(".att-row"));
};
function focusChatTermSoon(slug) {
  requestAnimationFrame(() => { if (mode === "chat" && chatSlug === slug && focusIsIdle()) chatTerm.focus(); });
}
function selectChat(slug, { focusTerm = false } = {}) {
  if (slug !== chatSlug) delete wsCache[slug];
  chatSlug = slug;
  wantsTermFocus = focusTerm ? slug : null;
  renderChat();
  wantsTermFocus = null;
  const row = document.querySelector(`.att-row[data-slug="${slug}"]`);
  if (row) { row.focus({ preventScroll: true }); row.scrollIntoView({ block: "nearest" }); }
}
function moveChat(d) {
  const rows = [...chatRows().map(a => a.slug), ...looseChats.map(l => l.name)];
  if (!rows.length) return;
  const i = rows.indexOf(chatSlug);
  selectChat(rows[i < 0 ? 0 : Math.min(rows.length - 1, Math.max(0, i + d))]);
}
