"use strict";

/* ------- session slide-over (stacks above the item sheet) ------- */
let openSessSheet = null;
function closeSession() { if (openSessSheet) { openSessSheet.remove(); openSessSheet = null; } }

// `it` is null for inbox sessions — no work item yet, so no Resume-via-item
// and no snapshots, and the tier chip fills in once the fetch answers.
function openSession(it, se) {
  closeSession();
  const scrim = el("div", "sheet-scrim stack");
  scrim.addEventListener("mousedown", e => { if (e.target === scrim) closeSession(); });
  const s = el("div", "sheet");

  const head = el("div", "sheet-head");
  const r1 = el("div", "row1");
  const chip = el("span", "sess-tier" + (se.tier ? " tier-" + se.tier : ""), se.tier || "…");
  r1.appendChild(chip);
  r1.appendChild(el("span", "slug", short(se.id)));
  const close = el("button", "sheet-close", "✕"); close.onclick = closeSession;
  r1.appendChild(close);
  head.appendChild(r1);
  const h2 = el("h2", "", esc(se.prompt || "no prompt captured"));
  head.appendChild(h2);
  const meta = el("div", "meta");
  meta.style.marginTop = "7px";
  meta.textContent = se.when;
  head.appendChild(meta);
  s.appendChild(head);

  if (it && se.tier === "resumable") {
    const bar = el("div", "sheet-actions");
    const rb = el("button", "act strong", "▸ Resume");
    rb.onclick = () => act("resume", { slug: it.slug, args: { session: se.id } }).then(r => { if (r.ok) toast(`resuming ${short(se.id)} → Warp tab`); });
    bar.appendChild(rb);
    s.appendChild(bar);
  }

  const body = el("div", "sheet-body");
  body.appendChild(el("div", "desc-text", "Loading transcript…"));
  s.appendChild(body);
  scrim.appendChild(s);
  document.body.appendChild(scrim);
  openSessSheet = scrim;

  fetch("/api/session/" + encodeURIComponent(se.id))
    .then(r => r.json())
    .then(d => {
      if (openSessSheet !== scrim) return;
      if (d.tier) { chip.className = "sess-tier tier-" + d.tier; chip.textContent = d.tier; }
      if (!it && d.tier === "resumable" && !se.aside) { // an aside reopens in its drawer, never as a plain session
        const bar = el("div", "sheet-actions");
        const rb = el("button", "act strong", "▸ Resume");
        rb.onclick = () => act("resume-session", { args: { session: se.id } }).then(r => { if (r.ok) toast(`resuming ${short(se.id)} → Warp tab`); });
        bar.appendChild(rb);
        s.insertBefore(bar, body);
      }
      renderSessionDetail(h2, meta, body, it, se, d);
    })
    .catch(() => { body.innerHTML = ""; body.appendChild(el("div", "desc-text", "Could not load session details.")); });
}

const TIER_FALLBACKS = TAXONOMIES.tierFallbacks;

function renderSessionDetail(h2, meta, body, it, se, d) {
  body.innerHTML = "";
  if (d.error) { body.appendChild(el("div", "desc-text", esc(d.error))); return; }
  if (d.title) h2.innerHTML = esc(d.title);
  meta.innerHTML = [se.when, d.cwd, d.branch && "⑂ " + d.branch, d.model]
    .filter(Boolean).map(esc).join(' <span class="sep">·</span> ');

  const sec = (title, n) => { const dv = el("div", "sheet-sec"); const h = el("h3", "", esc(title)); if (n != null) h.appendChild(el("span", "n", String(n))); dv.appendChild(h); return dv; };

  const turns = d.turns;
  const tsec = sec("Turns", turns ? turns.length : null);
  if (!turns) {
    tsec.appendChild(el("div", "desc-text", TIER_FALLBACKS[d.tier] || "No transcript found."));
  } else if (!turns.length) {
    tsec.appendChild(el("div", "desc-text", "No prompts in the transcript."));
  } else {
    const tl = el("div", "timeline");
    turns.forEach(t => {
      const row = el("div", "tl-note");
      row.appendChild(el("div", "tl-dot"));
      const b = el("div", "tl-body");
      const stamp = (t.ts || "").replace("T", " ").slice(0, 16);
      if (stamp) b.appendChild(el("span", "stamp", esc(stamp)));
      b.appendChild(el("div", "turn-prompt", esc(t.prompt)));
      const bits = (t.tools || []).map(tc => esc(tc.name) + (tc.count > 1 ? " ×" + tc.count : ""));
      if (t.files && t.files.length) bits.push(esc(t.files.join(", ")));
      if (bits.length) b.appendChild(el("div", "turn-tools", bits.join(" · ")));
      if (t.reply) b.appendChild(el("div", "turn-reply", esc(t.reply)));
      row.appendChild(b);
      tl.appendChild(row);
    });
    tsec.appendChild(tl);
  }
  body.appendChild(tsec);

  const snaps = ((it && it.snapshots) || []).filter(sn => sn.session === se.id);
  if (snaps.length) {
    const psec = sec("Snapshots", snaps.length);
    snaps.forEach(sn => {
      const row = el("div", "tl-note");
      row.appendChild(el("div", "tl-dot"));
      row.appendChild(el("div", "tl-body", `<span class="stamp">${esc(sn.stamp)}</span>${esc(sn.text)}`));
      psec.appendChild(row);
    });
    body.appendChild(psec);
  }
}
