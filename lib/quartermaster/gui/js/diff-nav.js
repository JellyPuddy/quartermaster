"use strict";

/* ------- finding files: the list column (fullscreen), the jump menu (narrow) ------- */
/* The column sits outside the diff body's scroll, so it stays put while the
   diff scrolls; it marks the file at the top of the view. */
function renderDiffNav() {
  const nav = $("#diff-nav");
  keepScroll(nav, () => {
    nav.innerHTML = "";
    const d = !diffView.error && diffView.data;
    const files = d && !d.notice ? d.files : [];
    nav.hidden = !files.length;
    if (!files.length) return;
    const t = diffTotals(files);
    nav.appendChild(el("div", "dn-head", `<span>${files.length} file${files.length === 1 ? "" : "s"} ${diffStat(t.add, t.del)}</span>` +
      `<span class="d-viewed-count">${diffViewedCount(files)}</span>`));
    files.forEach((f, i) => {
      const slash = f.path.lastIndexOf("/");
      const row = el("div", "dn-row" + (f.viewed ? " viewed" : ""),
        `<span class="dn-check" aria-hidden="true"></span><span class="d-status ${f.status}">${DIFF_STATUS[f.status] || "M"}</span>` +
        `<span class="dn-path"><span class="dn-name">${esc(f.path.slice(slash + 1))}</span>` +
        `<span class="dn-dir">${esc(f.path.slice(0, slash + 1))}</span></span>` +
        (f.commitStatus === "uncommitted" || f.commitStatus === "mixed" ? '<span class="dn-unc" title="Has uncommitted changes"></span>' : "") +
        `<span class="d-stat">${f.binary ? "bin" : diffStat(f.additions, f.deletions)}</span>`);
      row.dataset.index = i;
      row.title = f.path + (f.viewed ? " · viewed" : "");
      row.onclick = () => diffJumpTo(i);
      nav.appendChild(row);
    });
  });
  markDiffNavCurrent();
}

/* Narrow pane: the same list as a menu in the bar. */
function renderDiffJump(d) {
  const pick = el("select", "diff-jump");
  pick.title = "Jump to a changed file";
  const head = el("option", "", `Jump to file… (${diffViewedCount(d.files)})`);
  head.value = "";
  pick.appendChild(head);
  d.files.forEach((f, i) => {
    const o = el("option", "", esc(`${f.viewed ? "✓ " : "\u2003"}${f.path}  +${f.additions} −${f.deletions}`));
    o.value = String(i);
    pick.appendChild(o);
  });
  pick.onchange = () => { if (pick.value !== "") diffJumpTo(Number(pick.value)); pick.value = ""; };
  return pick;
}

/* Opens the file (a viewed one too, without unviewing it) and puts its
   header at the top. */
function diffJumpTo(i) {
  const target = document.getElementById(`diff-file-${i}`);
  if (!target) return;
  target.open = true;
  const body = $("#diff-body");
  body.scrollTop += target.getBoundingClientRect().top - body.getBoundingClientRect().top - 10;
}

/* The nav row of the file whose header is at (or last passed) the top of
   the diff body. */
function markDiffNavCurrent() {
  const nav = $("#diff-nav");
  if (nav.hidden || !nav.offsetParent) return;
  const top = $("#diff-body").getBoundingClientRect().top + 12;
  let current = 0;
  document.querySelectorAll("#diff-body details.diff-file").forEach((box, i) => {
    if (box.getBoundingClientRect().top <= top) current = i;
  });
  nav.querySelectorAll(".dn-row").forEach(row => row.classList.toggle("cur", Number(row.dataset.index) === current));
}

let diffNavFrame = 0;
$("#diff-body").addEventListener("scroll", () => {
  if (diffNavFrame) return;
  diffNavFrame = requestAnimationFrame(() => { diffNavFrame = 0; markDiffNavCurrent(); });
}, { passive: true });

/* ------- viewed marks ------- */
/* The server keys a mark to the file's path and a digest of its diff as
   shown (f.digest), so a file an agent changed since comes back unviewed;
   it says per file whether it is viewed (f.viewed). A viewed file folds to
   its header; opening it again leaves it viewed. */
const diffViewedCount = files => `${files.filter(f => f.viewed).length}/${files.length} viewed`;

/* A button, not an <input> in a <label>: a click on a label's text inside
   <summary> would also fold the file. */
function diffViewedToggle(f, i) {
  const box = el("button", "d-viewed", '<span class="d-viewed-box" aria-hidden="true"></span>Viewed');
  box.type = "button";
  box.setAttribute("role", "checkbox");
  box.setAttribute("aria-checked", String(!!f.viewed));
  box.title = "Mark this file viewed — it folds away until its diff changes";
  box.onclick = e => { e.preventDefault(); e.stopPropagation(); setDiffViewed(i, !f.viewed); };
  return box;
}

async function setDiffViewed(i, viewed) {
  const d = diffView.data;
  const f = d && d.files[i];
  if (!f) return;
  showDiffViewed(i, viewed);
  const res = await act("diff-viewed", { slug: diffView.slug, args: { path: f.path, digest: f.digest, viewed } });
  if (!res.ok && diffView.data === d) showDiffViewed(i, !viewed);
}

/* Applies a file's mark on the page: its header, its fold, the counts. */
function showDiffViewed(i, viewed) {
  const f = diffView.data.files[i];
  f.viewed = viewed;
  const box = document.getElementById(`diff-file-${i}`);
  if (box) {
    box.classList.toggle("viewed", viewed);
    box.querySelector(".d-viewed").setAttribute("aria-checked", String(viewed));
    const body = $("#diff-body");
    if (viewed && box.open) {
      box.open = false;
      // Marked from below its header: keep the next file in view, not a jump.
      const above = box.getBoundingClientRect().top - body.getBoundingClientRect().top;
      if (above < 0) body.scrollTop += above - 10;
    } else if (!viewed) {
      box.open = true;
    }
  }
  renderDiffBar();
  renderDiffNav();
}

function renderDiffFile(f, i, anchors = new Map()) {
  const box = el("details", "diff-file" + (f.viewed ? " viewed" : ""));
  box.id = `diff-file-${i}`;
  box.dataset.path = f.path;
  const lines = f.hunks.reduce((n, h) => n + h.lines.length, 0);
  box.open = !f.viewed && lines <= DIFF_FOLD_LINES && !DIFF_FOLD_PATH.test(f.path);
  const name = f.status === "renamed" && f.oldPath !== f.path ? `${esc(f.oldPath)} → ${esc(f.path)}` : esc(f.path);
  const summary = el("summary", "", `<span class="d-status ${f.status}">${DIFF_STATUS[f.status] || "M"}</span>` +
    `<span class="d-path">${name}</span>${diffFileLayerCircles(f)}${diffCommitBadge(f)}<span class="d-stat">${f.binary ? "binary" : diffStat(f.additions, f.deletions)}</span>`);
  const badged = itemDrafts().filter(d => { const a = anchors.get(d.id); return a && a.at === "file" && a.path === f.path; });
  if (badged.length) summary.querySelector(".d-stat").before(diffAnnotationBadge(badged));
  const threads = prThreadPlacement(f);
  if (threads) summary.querySelector(".d-stat").before(prThreadBadge(threads));
  if (f.digest) summary.appendChild(diffViewedToggle(f, i));
  box.appendChild(summary);
  if (threads && (threads.off.length || threads.onFile.length)) box.appendChild(prThreadsAtTop(threads));
  renderOutdatedCards(box, f);
  if (f.binary) { box.appendChild(el("div", "diff-note", "Binary file — not shown.")); return box; }
  if (!f.hunks.length) { box.appendChild(el("div", "diff-note", "No content change (mode or rename only).")); return box; }
  // Built on first open: a long, collapsed file costs nothing until asked for.
  // Kept on the box so jumping to an annotation's row can build it at once.
  const fill = box.fillRows = () => {
    if (box.querySelector("table")) return;
    const table = el("table", "diff-table");
    const tbody = el("tbody");
    const annotated = diffAnnotationsByLine(f.path, diffAnchors());
    const context = diffContextFor(f, box);
    f.hunks.forEach((h, i) => {
      if (context) renderDiffGap(tbody, f, context, context.gaps[i]);
      tbody.appendChild(renderDiffHunkHeader(h));
      h.lines.forEach(line => {
        tbody.appendChild(renderDiffLine(f, line));
        // The line's address, not the stored draft: an edit then saves what
        // the line says now (its D8 mark included), not the draft's own fields.
        const address = diffLineAddress(f.path, line);
        // An outdated draft's number is no longer its line's: its card shows it.
        const drafted = diffDraftAt(address);
        if (drafted && !isOutdatedDraft(drafted)) tbody.appendChild(renderDiffCommentRow(address));
        if (line.t !== "-") (annotated.get(line.n) || []).forEach(a => tbody.appendChild(renderDiffAnnotationRow(a)));
        const onLine = threads ? prLineKeys(line).flatMap(k => threads.rows.get(k) || []) : [];
        if (onLine.length) tbody.appendChild(prThreadRow(onLine));
      });
    });
    if (context && context.gaps[f.hunks.length]) renderDiffGap(tbody, f, context, context.gaps[f.hunks.length]);
    markDiffDraftRanges(tbody, f.path);
    markDiffRowSides(tbody);
    table.appendChild(tbody);
    box.appendChild(table);
    if (f.truncated) box.appendChild(el("div", "diff-note d-rest", "The rest of this file is left out (the diff is too long)."));
  };
  if (box.open) fill(); else box.addEventListener("toggle", () => { if (box.open) fill(); });
  return box;
}

function renderDiffHunkHeader(h) {
  const tr = el("tr", "d-hunk");
  tr.appendChild(el("td", "d-num", "⋯"));
  tr.appendChild(el("td", "d-num", "⋯"));
  tr.appendChild(el("td", "d-code", esc(h.header)));
  return tr;
}
