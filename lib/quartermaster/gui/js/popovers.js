"use strict";

/* ------- popovers ------- */
let openPop = null;
let popOutside = null;
function closePop() {
  if (popOutside) { document.removeEventListener("mousedown", popOutside); popOutside = null; }
  if (openPop) { openPop.remove(); openPop = null; }
}
function popAt(anchor, build) {
  closePop();
  const p = el("div", "pop");
  build(p);
  document.body.appendChild(p);
  const r = anchor.getBoundingClientRect();
  let top = r.bottom + 6, left = r.left;
  const pw = p.offsetWidth, ph = p.offsetHeight;
  if (left + pw > window.innerWidth - 10) left = window.innerWidth - pw - 10;
  if (top + ph > window.innerHeight - 10) top = r.top - ph - 6;
  p.style.top = top + "px"; p.style.left = left + "px";
  openPop = p;
  // Roving keyboard focus: land on the first option and let arrows walk the
  // list (wrapping). Enter/Space activate natively; Escape is closed by the
  // global handler. Without this, arrows fell through to the card grid and the
  // menu was mouse-only.
  const opts = () => [...p.querySelectorAll("button")];
  opts()[0] && opts()[0].focus({ preventScroll: true });
  p.addEventListener("keydown", e => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "Home" && e.key !== "End") return;
    e.preventDefault();
    const list = opts(); if (!list.length) return;
    const cur = list.indexOf(document.activeElement);
    let next;
    if (e.key === "Home") next = 0;
    else if (e.key === "End") next = list.length - 1;
    else { const d = e.key === "ArrowDown" ? 1 : -1; next = cur < 0 ? (d > 0 ? 0 : list.length - 1) : (cur + d + list.length) % list.length; }
    list[next].focus({ preventScroll: true });
  });
  // Close on the next click/tap outside the menu. mousedown (not click), and
  // registered now — after this opening click's own mousedown — so it can't
  // dismiss the menu it just opened, and a menu item that opens a nested menu
  // installs its own fresh listener without the old one killing it.
  popOutside = e => { if (openPop && !openPop.contains(e.target)) closePop(); };
  document.addEventListener("mousedown", popOutside);
}

function stateMenu(anchor, it) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Set state"));
    STATES.forEach(s => {
      const b = el("button", "", "");
      b.appendChild(el("span", "pdot dot-" + s.key));
      b.appendChild(el("span", "", s.label));
      if (s.key === it.state) b.appendChild(el("span", "tick", "●"));
      b.onclick = () => { closePop(); changeState(it, s.key); };
      p.appendChild(b);
    });
  });
}
function changeState(it, state) {
  return act("state", { slug: it.slug, args: { state } }).then(r => {
    if (!r.ok) return;
    toast(`${it.slug} → ${stateLabel(state)}`);
    // Resolving answers with the item's cleanup plan when there is one.
    if (r.cleanup) cleanupModal(it.slug, r.cleanup, resolveHeading(r.cleanup));
  });
}
function moreMenu(anchor, it) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", it.slug));
    const add = (label, fn) => { const b = el("button", "", esc(label)); b.onclick = () => { closePop(); fn(); }; p.appendChild(b); };
    add("Open detail", () => openDetail(it));
    add("Add note…", () => noteModal(it));
    add("Links…", () => openDetailLinks(it));
    add("Open PR", () => runAction("pr", it));
    p.appendChild(el("div", "sep"));
    add("Clean up worktrees…", () => cleanupModal(it.slug));
    add("Change project…", () => projectMenu(anchor, it));
    if (!isEpic(it) && it.kind !== "automation") add("Epic…", () => epicMenu(anchor, it));
    epicTurnEntry(p, it);
    add("Distill transcript", () => distill(it));
    if (panes.includes(it.slug)) {
      add("Wrap up & close chat", () => closeChat(it.slug));
      add("Finish: wrap up, close & resolve", () => finishChat(it.slug));
    }
    add("Snooze staleness…", () => snoozeMenu(anchor, it));
    add("Ack degradation", () => act("ack", { slug: it.slug }).then(r => { if (r.ok) toast(`won't nag ${it.slug} (${r.acked || 0} session${r.acked === 1 ? "" : "s"})`); }));
  });
}
function projectMenu(anchor, it) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Move to project"));
    PROJECTS.forEach(pr => {
      const b = el("button", "", esc(pr));
      if (pr === it.project) b.appendChild(el("span", "tick", "●"));
      b.onclick = () => { closePop(); act("move", { slug: it.slug, args: { project: pr } }).then(r => { if (r.ok) toast(`${it.slug} → ${pr}`); }); };
      p.appendChild(b);
    });
  });
}
function snoozeMenu(anchor, it) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Snooze staleness"));
    [["1 day", "1d"], ["7 days", "7d"], ["Clear snooze", "clear"]].forEach(([label, dur]) => {
      const b = el("button", "", esc(label));
      b.onclick = () => { closePop(); act("snooze", { slug: it.slug, args: { duration: dur } }).then(r => { if (r.ok) toast(dur === "clear" ? `${it.slug} snooze cleared` : `${it.slug} snoozed ${dur}`); }); };
      p.appendChild(b);
    });
  });
}
function attachMenu(anchor, sess) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Attach to work item"));
    const open = items.filter(i => i.state !== "resolved");
    if (!open.length) { p.appendChild(el("div", "pop-label", "no open items")); return; }
    open.forEach(it => {
      const b = el("button", "", "");
      b.appendChild(el("span", "pdot dot-" + it.state));
      b.appendChild(el("span", "", it.slug));
      b.onclick = () => { closePop(); act("attach", { slug: it.slug, args: { session: sess.id } }).then(r => { if (r.ok) toast(`${short(sess.id)} → ${it.slug}` + movedFrom(r)); if (r.warning) toast(r.warning, false); }); };
      p.appendChild(b);
    });
  });
}
