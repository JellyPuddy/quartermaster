"use strict";

/* ------- annotation drafts anchored in the diff ------- */
/* Where each annotation shows is annotationAnchor's rule (anchors.js): a
   row under its owner's line, a badge on its file's header, or the tray
   only. Anchored, it stays an annotation: edited here it edits that draft
   and sends in the annotation section, never as a diff comment. */

/* The anchors of the item's annotations in the diff the pane shows. */
function diffAnchors() {
  const shown = diffOpen && diffView.slug === chatSlug && diffView.data;
  return shown ? annotationAnchors(itemDrafts(), diffView.data) : new Map();
}

/* One file's line-anchored annotations: branch-side line number → drafts. */
function diffAnnotationsByLine(path, anchors) {
  const byLine = new Map();
  itemDrafts().forEach(d => {
    const a = anchors.get(d.id);
    if (!a || a.at !== "line" || a.path !== path) return;
    byLine.set(a.line, (byLine.get(a.line) || []).concat([d]));
  });
  return byLine;
}

/* The file header's "N annotations": a click opens the tray at them. */
function diffAnnotationBadge(drafts) {
  const badge = el("span", "d-annot-badge", PAGE_ICON + esc(plural(drafts.length, "annotation")));
  badge.title = `${drafts.map(d => d.comment).join("\n—\n")}\n\nIn the tray under the diff: their element is in this file, but no line shown here is known to be its source`;
  badge.onclick = e => { e.preventDefault(); e.stopPropagation(); revealTrayEntry(drafts[0].id); };
  return badge;
}

/* The row under an annotation's line: page icon, the page it is on, its
   comment (a click edits it), ✎ and ✕, and its element folded away. */
function renderDiffAnnotationRow(d, editing = false) {
  const tr = el("tr", "d-annot");
  tr.dataset.id = d.id;
  tr.appendChild(el("td", "d-num", ""));
  tr.appendChild(el("td", "d-num", ""));
  const td = el("td", "d-annot-cell");
  const top = el("div", "d-annot-top", PAGE_ICON + '<span class="d-annot-tag">annotation</span>');
  const page = d.page || d.url || "";
  top.appendChild(el("span", "dt-page", esc(pagePath(page)))).title = page;
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the annotation's comment";
  edit.onclick = () => tr.replaceWith(renderDiffAnnotationRow(d, true));
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this annotation";
  del.onclick = () => { tr.remove(); deleteDraft(d); };
  top.append(edit, del);
  td.appendChild(top);
  if (editing) td.appendChild(diffAnnotationEditor(d, tr));
  else {
    const text = el("div", "d-annot-text", esc(d.comment));
    text.title = "Edit the annotation's comment";
    text.onclick = () => tr.replaceWith(renderDiffAnnotationRow(d, true));
    td.appendChild(text);
  }
  td.appendChild(annotationDetails(d));
  tr.appendChild(td);
  return tr;
}

function diffAnnotationEditor(d, tr) {
  const box = el("div", "dt-edit");
  const input = el("textarea", "d-comment-input annot");
  input.rows = 3;
  input.value = d.comment;
  input.placeholder = "⌘⏎ saves, Esc cancels — saving it empty deletes the annotation";
  const close = comment => {
    if (comment.trim()) tr.replaceWith(renderDiffAnnotationRow({ ...d, comment }));
    else tr.remove();
  };
  const save = () => { const comment = input.value; close(comment); editDraft(d, comment); };
  const cancel = () => close(d.comment);
  input.addEventListener("keydown", e => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancel(); }
  });
  const acts = el("div", "d-comment-acts");
  const ok = el("button", "primary annot", "Save");
  ok.onclick = save;
  const no = el("button", "", "Cancel");
  no.onclick = cancel;
  const del = el("button", "danger", "Delete");
  del.onclick = () => { tr.remove(); deleteDraft(d); };
  acts.append(ok, no, del);
  box.append(input, acts);
  setTimeout(() => input.focus(), 0);
  return box;
}

/* A rebuild brings an open annotation editor back with what was typed. */
function reopenDiffAnnotation(id, value) {
  const row = document.querySelector(`#diff-body tr.d-annot[data-id="${CSS.escape(id)}"]`);
  const d = itemDrafts().find(x => x.id === id);
  if (!row || !d) return;
  const editor = renderDiffAnnotationRow(d, true);
  editor.querySelector("textarea").value = value;
  row.replaceWith(editor);
}

/* From the tray: scroll to an anchored annotation's row (or its file's
   header, for a badge) and flash it. */
function revealDiffAnnotation(d) {
  const a = diffAnchors().get(d.id);
  if (!a) { renderDiffTray(); return; }
  const file = [...document.querySelectorAll("#diff-body details.diff-file")].find(f => f.dataset.path === a.path);
  if (!file) return;
  if (a.at === "file") { flashDiffTarget(file.querySelector("summary"), "start"); return; }
  file.open = true;
  if (file.fillRows) file.fillRows();
  const row = file.querySelector(`tr.d-annot[data-id="${CSS.escape(d.id)}"] .d-annot-cell`);
  if (row) showDiffRow(row.closest("tr"));
  flashDiffTarget(row || file.querySelector("summary"), row ? "center" : "start");
}

function flashDiffTarget(target, block) {
  if (!target) return;
  target.scrollIntoView({ block });
  target.classList.remove("d-flash");
  void target.offsetWidth; // restart the animation on a second click
  target.classList.add("d-flash");
  setTimeout(() => target.classList.remove("d-flash"), 1600);
}
