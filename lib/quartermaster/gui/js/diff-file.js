"use strict";

/* ------- context expanding: unchanged lines around the hunks, GitHub-style ------- */
/* Context is the same on both sides, so it comes from the old side's file
   at the payload's oldRev (GET /api/diff-file), fetched on a file's first
   expand and kept until ↻ or another chat (a file at a sha can't change).
   What a file shows is kept as revealed old-line intervals per file key
   (oldRev|oldPath|path), so a re-render of the same diff — a draft saved,
   a reload with nothing moved — shows the same lines. f.hunks is never
   touched: the highlight cache and viewed digests are keyed on them. */
const DIFF_EXPAND_STEP = 20;
const DIFF_CONTEXT_FILES = 50;
const DIFF_CONTEXT_HIGHLIGHT_LINES = 10000;
const DIFF_EXPANDED_FILES = 200;
const diffContextFiles = new Map(); // oldRev + "\0" + oldPath → { promise, res }, newest last
const diffExpanded = new Map();     // file key → [[from, to], …] old lines shown, sorted and merged; to may be Infinity

/* What expanding a file needs, or null when there is nothing to expand:
   binary, no hunks, added or deleted (shown whole already), or no oldRev. */
function diffContextFor(f, box) {
  const rev = diffView.data && diffView.data.oldRev;
  if (!rev || f.binary || !f.hunks.length || f.status === "added" || f.status === "deleted") return null;
  const oldPath = f.oldPath || f.path;
  const kept = diffContextFiles.get(rev + "\0" + oldPath);
  const ctx = { box, rev, oldPath, key: `${rev}|${oldPath}|${f.path}`, file: kept && kept.res, gaps: diffGaps(f) };
  ctx.shown = diffExpanded.get(ctx.key) || [];
  // Lines shown before a ↻ dropped the file: fetched again, then the file refills.
  if (ctx.shown.length && !ctx.file) showDiffContext(ctx);
  return ctx;
}

/* A hunk's first and last old line, and what turns an old number into a
   new one before and after it. An empty side's start names the line
   before it (@@ -5,0 +6,2 @@). */
function diffHunkSpan(h) {
  const olds = h.lines.filter(l => l.o != null).length;
  const news = h.lines.filter(l => l.n != null).length;
  const oldFirst = olds ? h.oldStart : h.oldStart + 1;
  const newFirst = news ? h.newStart : h.newStart + 1;
  return { oldFirst, oldLast: oldFirst + olds - 1, delta: newFirst - oldFirst, deltaAfter: newFirst - oldFirst + news - olds };
}

/* The unchanged old lines before each hunk, and after the last one, which
   run to the file's end (Infinity until it is fetched). A file the diff's
   line limit cut short has no gap after its last hunk: that hunk may not
   be whole. */
function diffGaps(f) {
  const spans = f.hunks.map(diffHunkSpan);
  const gaps = spans.map((s, i) => ({ from: i ? spans[i - 1].oldLast + 1 : 1, to: s.oldFirst - 1, delta: s.delta, last: false }));
  const end = spans[spans.length - 1];
  if (!f.truncated) gaps.push({ from: end.oldLast + 1, to: Infinity, delta: end.deltaAfter, last: true });
  return gaps;
}

/* A gap's rows: its revealed lines, and an expander for each run still
   hidden. Past the fetched file's end (or its 20,000-line cap) nothing is
   offered, so the expander after the last hunk vanishes once exhausted. */
function renderDiffGap(tbody, f, ctx, gap) {
  const end = ctx.file ? Math.min(gap.to, ctx.file.lines.length) : gap.to;
  const shown = ctx.file ? ctx.shown : [];
  let k = gap.from;
  while (k <= end && k !== Infinity) { // Infinity: the expander for the rest of a file not fetched was the last row
    const run = shown.find(([a, b]) => a <= k && k <= b);
    if (run) {
      const last = Math.min(run[1], end);
      for (; k <= last; k++) renderDiffExpandedLine(tbody, f, ctx, k, k + gap.delta);
    } else {
      const next = shown.find(([a]) => a > k);
      const last = next ? Math.min(next[0] - 1, end) : end;
      tbody.appendChild(renderDiffExpander(ctx, k, last, !gap.last || last < end));
      k = last + 1;
    }
  }
}

/* An expanded line is a context line (old k, new k + delta), drawn like one
   and commentable as a chat draft; GitHub takes comments only on lines in
   the PR's hunks, so in the PR scope it is gh: false (the D8 offer). */
function renderDiffExpandedLine(tbody, f, ctx, o, n) {
  const lit = diffContextHighlight(ctx, f);
  const line = { t: " ", o, n, s: ctx.file.lines[o - 1], lit: lit ? lit[o - 1] : null };
  if (diffPrScope()) line.gh = false;
  const tr = renderDiffLine(f, line);
  tr.classList.add("d-expanded");
  tbody.appendChild(tr);
  const address = diffLineAddress(f.path, line);
  const drafted = diffDraftAt(address);
  if (drafted && !isOutdatedDraft(drafted)) tbody.appendChild(renderDiffCommentRow(address));
}

/* The controls for hidden old lines from..to (to Infinity: the rest of a
   file not fetched yet). Up to a step: one control for all of them;
   more: ↓ under what is shown above, ↑ over what is shown below, and all.
   Buttons inside the table, never the <summary>: the file doesn't fold. */
function renderDiffExpander(ctx, from, to, shownBelow) {
  const tr = el("tr", "d-expand");
  tr.append(el("td", "d-num", ""), el("td", "d-num", ""));
  const td = el("td", "d-code d-expand-cell");
  const size = to - from + 1;
  const button = (label, title, a, b) => {
    const btn = el("button", "d-expand-btn", label);
    btn.type = "button";
    btn.title = title;
    btn.onclick = e => {
      e.preventDefault();
      e.stopPropagation();
      tr.querySelectorAll("button").forEach(x => { x.disabled = true; });
      expandDiffContext(ctx, a, b);
    };
    return btn;
  };
  const lines = n => `${n} unchanged line${n === 1 ? "" : "s"}`;
  if (size <= DIFF_EXPAND_STEP) {
    td.appendChild(button(`⇕ ${lines(size)}`, `Show the ${lines(size)} here`, from, to));
  } else {
    if (from > 1) td.appendChild(button(`↓ ${DIFF_EXPAND_STEP}`, `Show ${DIFF_EXPAND_STEP} more lines below`, from, from + DIFF_EXPAND_STEP - 1));
    if (shownBelow) td.appendChild(button(`↑ ${DIFF_EXPAND_STEP}`, `Show ${DIFF_EXPAND_STEP} more lines above`, to - DIFF_EXPAND_STEP + 1, to));
    td.appendChild(button("⇕ all", size === Infinity ? "Show the rest of the file" : `Show all ${lines(size)}`, from, to));
    td.appendChild(el("span", "d-expand-label", size === Infinity ? "rest of the file" : lines(size)));
  }
  tr.appendChild(td);
  return tr;
}

function expandDiffContext(ctx, from, to) {
  const shown = mergeDiffIntervals((diffExpanded.get(ctx.key) || []).concat([[from, to]]));
  diffExpanded.delete(ctx.key);
  diffExpanded.set(ctx.key, shown);
  while (diffExpanded.size > DIFF_EXPANDED_FILES) diffExpanded.delete(diffExpanded.keys().next().value);
  if (ctx.file) refillDiffFile(ctx.box); else showDiffContext(ctx);
}

function mergeDiffIntervals(list) {
  const merged = [];
  list.slice().sort((x, y) => x[0] - y[0]).forEach(([a, b]) => {
    const last = merged[merged.length - 1];
    if (last && a <= last[1] + 1) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  });
  return merged;
}

/* Fetches the old file, then rebuilds the file's rows with it. A file that
   can't be read forgets what was to be shown, so it isn't asked again on
   every render. A pane re-rendered meanwhile refills itself. */
async function showDiffContext(ctx) {
  const res = await fetchDiffContextFile(ctx.rev, ctx.oldPath);
  if (!res.ok && diffExpanded.delete(ctx.key)) toast(`Can't expand ${ctx.oldPath}: ${res.error || "no such file"}`, false);
  if (ctx.box.isConnected) refillDiffFile(ctx.box);
}

function fetchDiffContextFile(rev, path) {
  const key = rev + "\0" + path;
  let kept = diffContextFiles.get(key);
  if (kept) {
    diffContextFiles.delete(key);
    diffContextFiles.set(key, kept);
    return kept.promise;
  }
  kept = { res: null };
  const url = `/api/diff-file/${encodeURIComponent(diffView.slug)}?${new URLSearchParams({ rev, path })}`;
  kept.promise = fetch(url).then(r => r.json()).catch(() => ({ ok: false, error: "could not reach qm" })).then(res => {
    if (res.ok) kept.res = res;
    else if (diffContextFiles.get(key) === kept) diffContextFiles.delete(key); // a failure is asked again
    return res;
  });
  diffContextFiles.set(key, kept);
  while (diffContextFiles.size > DIFF_CONTEXT_FILES) diffContextFiles.delete(diffContextFiles.keys().next().value);
  return kept.promise;
}

/* The fetched file highlighted once, whole, and cut into lines — so a
   string or comment that opens above a gap colours it right. None for a
   huge file or minified lines; asked again until highlight.js has loaded. */
function diffContextHighlight(ctx, f) {
  const file = ctx.file;
  if (file.lit !== undefined) return file.lit;
  if (!window.hljs) return null;
  const lang = diffLanguage(f.path);
  file.lit = null;
  if (!lang || file.lines.length > DIFF_CONTEXT_HIGHLIGHT_LINES || file.lines.some(s => s.length > DIFF_HIGHLIGHT_MAX_LINE)) return null;
  try {
    file.lit = splitHighlightedLines(hljs.highlight(file.lines.join("\n"), { language: lang, ignoreIllegals: true }).value);
  } catch (e) { /* plain text */ }
  return file.lit;
}

/* Rebuilds one open file's rows (expanded lines added), keeping what was
   being typed in its editors. */
function refillDiffFile(box) {
  const editing = [...box.querySelectorAll("tr.d-comment textarea")].map(t => [t.closest("tr").dataset.key, t.value, t.closest("tr").diffAddress]);
  const annotEditing = [...box.querySelectorAll("tr.d-annot textarea")].map(t => [t.closest("tr").dataset.id, t.value]);
  box.querySelectorAll(":scope > table, :scope > .d-rest").forEach(n => n.remove());
  box.fillRows(); // folded meanwhile too: a file open when rendered has no fill-on-open listener
  editing.forEach(([key, value, address]) => reopenDiffComment(key, value, address));
  annotEditing.forEach(([id, value]) => reopenDiffAnnotation(id, value));
}

/* One diff line as a table row. The row carries what addresses the line —
   path, kind, old and new number — so a comment on it can say path:line. */
function renderDiffLine(f, line) {
  const kind = line.t === "+" ? "add" : line.t === "-" ? "del" : "ctx";
  const tr = el("tr", `d-line ${kind}${line.uncommitted ? " unc" : ""}`);
  tr.dataset.path = f.path;
  tr.dataset.kind = kind;
  if (line.o != null) tr.dataset.old = line.o;
  if (line.n != null) tr.dataset.new = line.n;
  tr.dataset.code = line.s;
  if (line.gh === false) tr.dataset.gh = "0"; // GitHub won't take a comment here at the anchor commit
  tr.dataset.key = diffAddressKey(diffLineAddress(f.path, line));
  tr.appendChild(el("td", "d-num", line.o == null ? "" : String(line.o)));
  tr.appendChild(el("td", "d-num", line.n == null ? "" : String(line.n)));
  const code = el("td", "d-code");
  code.innerHTML = `<span class="d-sign">${line.t === " " ? " " : line.t}</span>${diffLineCode(f, line)}`;
  tr.appendChild(code);
  return tr;
}

/* A line's code as HTML: the one place that turns source text into markup.
   Syntax colour comes from highlight.js when it loaded and knows the file's
   language; otherwise the line is plain escaped text. */
function diffLineCode(f, line) {
  if (line.lit != null) return line.lit; // an expanded line, coloured with its whole file
  if (!diffHighlights.has(f)) diffHighlights.set(f, diffFileHighlights(f));
  const lit = diffHighlights.get(f);
  const html = lit && lit.get(line);
  return html == null ? esc(line.s) : html;
}

const diffHighlights = new WeakMap(); // file → Map(line → html), or null: not highlighted

/* Every load brings new file objects, but a file's digest (ViewedMarks)
   covers its path and every line shown: a reload at a turn's end, or a
   commit seen before, takes an unchanged file's colouring from here. */
const DIFF_HIGHLIGHT_FILES = 300;
const diffHighlightsByDigest = new Map(); // digest → [html per line, hunks in order] or null; newest last

function diffFileHighlights(f) {
  const lines = f.hunks.flatMap(h => h.lines);
  const known = f.digest ? diffHighlightsByDigest.get(f.digest) : undefined;
  if (known !== undefined) {
    diffHighlightsByDigest.delete(f.digest);
    diffHighlightsByDigest.set(f.digest, known);
    return known && new Map(lines.map((line, i) => [line, known[i]]));
  }
  const lit = highlightDiffFile(f);
  if (f.digest && window.hljs) { // before highlight.js loads, null says nothing about the file
    diffHighlightsByDigest.set(f.digest, lit && lines.map(line => lit.get(line)));
    while (diffHighlightsByDigest.size > DIFF_HIGHLIGHT_FILES) diffHighlightsByDigest.delete(diffHighlightsByDigest.keys().next().value);
  }
  return lit;
}
const DIFF_HIGHLIGHT_MAX_LINE = 1000;  // minified code: slow to highlight, unreadable anyway
const DIFF_LANG_BY_NAME = {
  Gemfile: "ruby", Rakefile: "ruby", Guardfile: "ruby", Brewfile: "ruby", Podfile: "ruby",
  Makefile: "makefile",
};
const DIFF_LANG_BY_EXT = {
  rake: "ruby", ru: "ruby", jbuilder: "ruby", erb: "xml", vue: "xml", svg: "xml",
  mjs: "javascript", cjs: "javascript", jsx: "javascript", tsx: "typescript",
};

function diffLanguage(path) {
  if (!window.hljs) return null;
  const name = path.split("/").pop();
  const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  const lang = DIFF_LANG_BY_NAME[name] || DIFF_LANG_BY_EXT[ext] || ext;
  return lang && hljs.getLanguage(lang) ? lang : null;
}

/* Each hunk's old side (context and removed lines) and new side (context and
   added lines) is highlighted as one piece, so a string or comment spanning
   lines keeps its colour, then cut back into lines. Context lines sit on both
   sides; the new side's colouring wins. */
function highlightDiffFile(f) {
  const lang = diffLanguage(f.path);
  if (!lang) return null;
  const lit = new Map();
  try {
    f.hunks.forEach(h => ["+", "-"].forEach(otherSide => {
      const side = h.lines.filter(l => l.t !== otherSide);
      if (!side.length || side.some(l => l.s.length > DIFF_HIGHLIGHT_MAX_LINE)) return;
      const html = hljs.highlight(side.map(l => l.s).join("\n"), { language: lang, ignoreIllegals: true }).value;
      splitHighlightedLines(html).forEach((code, i) => { if (side[i]) lit.set(side[i], code); });
    }));
  } catch (e) { return null; }
  return lit;
}

/* highlight.js output is escaped text and nested <span>s; a span open across
   a newline is closed at the line's end and reopened on the next line. */
function splitHighlightedLines(html) {
  const lines = [];
  const open = [];
  let cur = "";
  html.split(/(<span[^>]*>|<\/span>|\n)/).forEach(tok => {
    if (tok === "\n") {
      lines.push(cur + "</span>".repeat(open.length));
      cur = open.join("");
    } else if (tok.startsWith("<span")) {
      open.push(tok);
      cur += tok;
    } else if (tok === "</span>") {
      open.pop();
      cur += tok;
    } else {
      cur += tok;
    }
  });
  lines.push(cur);
  return lines;
}
