"use strict";

/* ------- error badge (header) ------- */
/* qm.log errors the user hasn't marked seen (ErrorLog: not transient, not
   recovered, newer than errors-seen-at or the last day). The state carries
   the count and the newest ~20 entries, header line first, then its
   continuation lines; a click lists them, and Mark seen moves the marker to now. */
let qmErrors = { count: 0, entries: [] };

function renderErrorBadge() {
  const badge = $("#errors-badge");
  if (!badge) return;
  const n = qmErrors.count || 0;
  badge.hidden = n === 0;
  badge.textContent = `⚠ ${n} error${n === 1 ? "" : "s"}`;
  badge.title = "qm errors in qm.log since you last marked them seen — click to read them";
}

function errorsMenu(anchor) {
  popAt(anchor, p => {
    p.classList.add("err-pop");
    const shown = qmErrors.entries || [];
    const more = (qmErrors.count || 0) - shown.length;
    p.appendChild(el("div", "pop-label", `qm.log · ${qmErrors.count} unseen` + (more > 0 ? ` · newest ${shown.length}` : "")));
    const list = el("div", "err-list");
    shown.forEach(e => list.appendChild(el("pre", "err-entry", esc(e.lines.join("\n")))));
    p.appendChild(list);
    p.appendChild(el("div", "sep"));
    const seen = el("button", "", "Mark seen");
    seen.onclick = () => {
      closePop();
      act("errors-seen").then(r => { if (r.ok) toast("qm errors marked seen"); });
    };
    p.appendChild(seen);
  });
}

$("#errors-badge").addEventListener("click", e => errorsMenu(e.currentTarget));
