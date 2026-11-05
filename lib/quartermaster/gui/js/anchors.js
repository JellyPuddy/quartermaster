"use strict";

/* ------- where an annotation draft shows in the diff ------- */
/* Pure, no DOM: from an annotation's owners and a diff payload (/api/diff)
   to one of
     { at: "line", path, line }  a row under that branch-side line,
     { at: "file", path }        a badge on that file's header,
     null                        the tray only.
   Owners come innermost first. A row needs the innermost owner whose
   file:line is a shown added or context line, and that owner's `code` (the
   JSX line pf read) must equal the line's text, trimmed: line numbers alone
   drift as soon as the branch moves on, the text says it is still the same
   line. Without `code` there is no row. Otherwise the innermost owner whose
   file is in the diff gets the badge. Under a selected run of commits the
   numbers are that run's, so nothing anchors there.
   Both sides are repo-relative (pf: "app/javascript/…", git: b/<path>);
   repoRelative only drops a stray leading "./" or "/". */
const repoRelative = path => String(path || "").trim().replace(/^(?:\.?\/)+/, "");

function annotationAnchor(draft, diff) {
  if (!draft || !diff || diff.range || !Array.isArray(diff.files)) return null;
  const files = new Map(diff.files.map(f => [repoRelative(f.path), f]));
  const owners = (Array.isArray(draft.owners) ? draft.owners : [])
    .filter(o => o && o.file && files.has(repoRelative(o.file)));
  if (!owners.length) return null;
  for (const o of owners) {
    const f = files.get(repoRelative(o.file));
    const line = branchSideLine(f, o.line);
    if (!line) continue;
    if (sameCode(o.code, line.s)) return { at: "line", path: f.path, line: line.n };
    break;
  }
  return { at: "file", path: files.get(repoRelative(owners[0].file)).path };
}

/* The shown added or context line numbered n on the branch side, or null. */
function branchSideLine(f, n) {
  const want = Number(n);
  if (!Number.isInteger(want) || want <= 0 || !Array.isArray(f.hunks)) return null;
  for (const h of f.hunks) for (const l of h.lines || []) if (l.t !== "-" && l.n === want) return l;
  return null;
}

const sameCode = (code, text) => typeof code === "string" && code.trim() !== "" && code.trim() === String(text == null ? "" : text).trim();

/* Every annotation's anchor in this diff: id → anchor (unanchored left out). */
function annotationAnchors(drafts, diff) {
  const anchors = new Map();
  (drafts || []).forEach(d => {
    if (d.kind !== "annotation") return;
    const a = annotationAnchor(d, diff);
    if (a) anchors.set(d.id, a);
  });
  return anchors;
}
