"use strict";

/* ------- focus ------- */
function applyFocus() {
  document.querySelectorAll(".card.focused").forEach(c => c.classList.remove("focused"));
  if (focusIdx < 0 || focusIdx >= visibleSlugs.length) return;
  const slug = visibleSlugs[focusIdx];
  const c = document.querySelector(`.card[data-slug="${slug}"]`);
  if (c) { c.classList.add("focused"); c.scrollIntoView({ block: "nearest", behavior: "smooth" }); }
}
function moveFocus(d) {
  if (!visibleSlugs.length) return;
  focusIdx = focusIdx < 0 ? 0 : Math.min(visibleSlugs.length - 1, Math.max(0, focusIdx + d));
  // Move real DOM focus too, so a subsequent Tab continues from the selected
  // card. focusin (below) mirrors it back into focusIdx, keeping one highlight.
  const c = document.querySelector(`.card[data-slug="${visibleSlugs[focusIdx]}"]`);
  if (c) c.focus({ preventScroll: true });
  applyFocus();
}
// Jump to the neighbouring column, keeping the same row where possible (clamped
// to that column's last card). Empty columns are skipped. With no selection yet,
// either direction just enters the first non-empty column.
function moveColumn(dir) {
  const cols = [...document.querySelectorAll("#columns .column")]
    .map(c => [...c.querySelectorAll(".card")]);
  if (!cols.length) return;
  const cur = visibleSlugs[focusIdx];
  let ci = -1, ri = 0;
  cols.forEach((cards, i) => { const j = cards.findIndex(c => c.dataset.slug === cur); if (j >= 0) { ci = i; ri = j; } });
  let ti;
  if (ci < 0) { ti = dir > 0 ? 0 : cols.length - 1; }
  else { ti = ci + dir; }
  while (ti >= 0 && ti < cols.length && !cols[ti].length) ti += dir;
  if (ti < 0 || ti >= cols.length || !cols[ti].length) return;
  const target = cols[ti][Math.min(ri, cols[ti].length - 1)];
  focusIdx = visibleSlugs.indexOf(target.dataset.slug);
  target.focus({ preventScroll: true });
  applyFocus();
}
function focusedItem() {
  if (focusIdx < 0) return null;
  return items.find(it => it.slug === visibleSlugs[focusIdx]);
}
