"use strict";

/* ------- the diff pane's stack views (docs/areas/diff.md) -------
   For an item with chains (stacks.js): the bar's strip of the selected
   branch's chain in place of the branch <select>, the commit list grouped
   by layer under Commits and PR, and number-only layer circles on file
   headers. Only the selected layer's (or span's) diff is ever loaded: the
   other layers' headers and commits come with it (`layers`, StackLayers). */

/* ------- the strip ------- */
/* main › ①–② merged › ③● › ④ name #PR › ⑤● top  ⟳ 1 behind · restack —
   the selected branch's chain, its merged layers folded, the others as
   number + state dot, the selected one by its short name. A switcher at
   its start offers every other chain and whatever else the old <select>
   did (the chat's detached folder, an unlinked branch the chat runs on). */
function renderDiffStrip(d, it) {
  const shown = diffBranchFor(it.slug) || (d ? d.branch : selectedBranch(it));
  const found = shown ? chainOf(it, shown) : null;
  const strip = el("div", "diff-strip");
  const known = new Set(chainBranches(it));
  const extras = d ? d.branches.filter(b => !b.branch || !known.has(b.branch)) : [];
  const chains = itemChains(it);
  if (chains.length > 1 || extras.length) strip.appendChild(diffStripSwitcher(d, it, found, extras));
  if (!found) {
    const entry = d ? diffBranchEntry(d, shown) : {};
    const c = el("span", "ds-crumb sel loose", esc(shown || (entry.short ? `chat folder · ${entry.short}` : "chat folder")));
    c.title = shown ? `${shown} — not one of the item's linked branches` : "The chat's folder (detached HEAD)";
    strip.appendChild(c);
    return strip;
  }
  const { chain, at } = found;
  strip.appendChild(el("span", "ds-crumb trunk", esc(String(chain.trunk || "main").replace(/^origin\//, ""))));
  if (chain.kind !== "stack") {
    strip.appendChild(diffStripStep(diffStripCrumb(it, chain, chain.layers[0], 0, true)));
    return strip;
  }
  // Merged layers other than the selected one fold into one crumb where the first of them sits.
  const folded = chain.layers.map((l, i) => l.merged && i !== at);
  const firstFolded = folded.indexOf(true);
  chain.layers.forEach((l, i) => {
    if (folded[i] && i !== firstFolded) return;
    strip.appendChild(diffStripStep(folded[i] ? diffStripMerged(it, chain, folded) : diffStripCrumb(it, chain, l, i, i === at)));
  });
  const behind = chain.layers.filter(l => l.needsRestack && !l.merged);
  if (behind.length) {
    const chip = el("button", "ds-restack", `⟳ ${behind.length} behind · restack`);
    chip.title = behind.map(l => `${l.branch} is not on ${l.parent}'s tip`).join("\n") +
      "\nAsk the chat to restack the stack (gh stack rebase)";
    chip.onclick = () => restackStack(it, chainTop(chain));
    strip.appendChild(chip);
  }
  return strip;
}

/* "› crumb", kept together so a wrap never strands the separator. */
function diffStripStep(crumb) {
  const step = el("span", "ds-step");
  step.append(el("span", "ds-sep", "›"), crumb);
  return step;
}

function diffStripCrumb(it, chain, l, i, isSel) {
  const stack = chain.kind === "stack";
  const status = layerStatus(l);
  const b = el("button", `ds-crumb ${status}` + (isSel ? " sel" : ""), "");
  if (stack) b.appendChild(el("span", "ds-n", circled(i + 1)));
  if (isSel) {
    const prefix = stack ? chainPrefix(chain) : "";
    b.appendChild(el("span", "ds-name", esc(l.branch.slice(prefix.length) || l.branch)));
    if (l.pr_number) b.appendChild(el("span", "ds-pr", `#${l.pr_number}`));
  } else {
    b.appendChild(el("span", "ds-dot " + status));
  }
  if (stack && chain.layers.length > 1 && i === chain.layers.length - 1) b.appendChild(el("span", "ds-top", "top"));
  if ((chatBranches[it.slug] || {}).chat === l.branch) b.appendChild(el("span", "ds-chat", "◆"));
  if (l.needsRestack && !l.merged) b.appendChild(el("span", "ds-behind", "⟳"));
  b.title = `${stack ? circled(i + 1) + " " : ""}${l.branch} · ${LAYER_STATUS_LABEL[status]}` +
    (l.ahead != null ? ` · ${l.ahead} commit${l.ahead === 1 ? "" : "s"} on ${l.parent}` : "") +
    (l.needsRestack && !l.merged ? " · needs a restack" : "") +
    ((chatBranches[it.slug] || {}).chat === l.branch ? " · the chat runs on it" : "") +
    (it.worktrees && it.worktrees[l.branch] ? `\n@ ${it.worktrees[l.branch]}` : "\nno checkout");
  b.onclick = () => { if (!isSel) setSelectedBranch(it.slug, l.branch); };
  return b;
}

/* The folded merged layers: "①–② merged" (one: "① merged"; a gap: "①③ merged"); a click selects the topmost of them. */
function diffStripMerged(it, chain, folded) {
  const idx = folded.flatMap((f, i) => f ? [i] : []);
  const first = idx[0], last = idx[idx.length - 1];
  const numbers = last - first === idx.length - 1
    ? circled(first + 1) + (idx.length > 1 ? "–" + circled(last + 1) : "")
    : idx.map(i => circled(i + 1)).join("");
  const b = el("button", "ds-crumb merged", `<span class="ds-n">${numbers}</span><span class="ds-name">merged</span>`);
  b.title = idx.map(i => `${circled(i + 1)} ${chain.layers[i].branch}` +
    (chain.layers[i].pr_number ? ` #${chain.layers[i].pr_number}` : "")).join("\n");
  b.onclick = () => setSelectedBranch(it.slug, chain.layers[last].branch);
  return b;
}

/* "stack ▾ · +1 loose": opens a menu of every chain's branches and the extras. */
function diffStripSwitcher(d, it, found, extras) {
  const chains = itemChains(it);
  const here = found ? found.chain : null;
  const others = { stack: 0, loose: 0 };
  chains.forEach(c => { if (c !== here) others[c.kind] += 1; });
  const parts = [`${here ? here.kind : "other"} ▾`];
  if (others.stack) parts.push(`+${others.stack} stack${others.stack === 1 ? "" : "s"}`);
  if (others.loose) parts.push(`+${others.loose} loose`);
  if (here && extras.length) parts.push(`+${extras.length} other`);
  const b = el("button", "ds-switch", esc(parts.join(" · ")));
  b.title = "Pick another of the item's branches to review";
  b.onclick = () => popAt(b, p => diffSwitcherMenu(p, d, it, chains, extras));
  return b;
}

function diffSwitcherMenu(p, d, it, chains, extras) {
  const shown = d ? d.branch : selectedBranch(it);
  const add = (label, branch, isShown, title) => {
    const o = el("button", "", "");
    o.appendChild(el("span", "", esc(label)));
    if (isShown) o.appendChild(el("span", "tick", "●"));
    if (title) o.title = title;
    o.onclick = () => { closePop(); setSelectedBranch(it.slug, branch); };
    p.appendChild(o);
  };
  const note = branch => {
    const entry = d && branch ? diffBranchEntry(d, branch) : {};
    return entry.chat ? " · chat" : entry.checkout === false ? " · not checked out" : "";
  };
  chains.forEach((c, k) => {
    if (k) p.appendChild(el("div", "sep"));
    if (c.kind === "stack") {
      p.appendChild(el("div", "pop-label", esc(`stack · ${chainTop(c)}`)));
      c.layers.map((l, i) => [l, i]).reverse()
        .forEach(([l, i]) => add(`${circled(i + 1)} ${l.branch}${l.merged ? " · merged" : ""}${note(l.branch)}`, l.branch, l.branch === shown));
    } else {
      const l = c.layers[0];
      add(`⑂ ${l.branch}${l.pr_number ? ` #${l.pr_number}` : ""}${note(l.branch)}`, l.branch, l.branch === shown);
    }
  });
  if (extras.length) {
    p.appendChild(el("div", "sep"));
    p.appendChild(el("div", "pop-label", "other"));
    extras.forEach(b => add((b.branch || "detached HEAD") + (b.chat ? " · chat" : b.checkout === false ? " · not checked out" : ""),
      b.branch || null, (b.branch || null) === (shown || null), b.short));
  }
}

/* ------- the layered commit list ------- */
/* Top layer first: a header per layer (number, branch, PR chip, +/−, n
   commits, ⟳), its commits beneath, newest first. The loaded diff's own
   commits (the selected layer, or every layer of a span) are the list's
   rows to pick from as before; the other layers' come with `layers` and a
   click on one selects its layer with that commit. A header click selects
   its branch; ⇧-click on a second header spans from the lower one's parent
   to the upper one (Commits scope, base=). Long layers fold to their newest
   few. A commit a lower layer (or the trunk) already holds — a squash
   merge's leftover — is dimmed and tagged, never hidden. */
const DIFF_LAYER_FOLD = 10;   // more commits than this fold...
const DIFF_LAYER_SHOWN = 6;   // ...to the newest this many
const diffLayersOpen = new Set(); // "slug|branch": a folded layer's commits all shown
const diffSpanAnchor = {};    // slug → the last header clicked, where a ⇧-click span starts

/* The 0-based [low, high] layer indexes the loaded diff covers, or null. */
function diffLayerSpan(d) {
  const high = d.layers.findIndex(l => l.branch === d.branch);
  if (high < 0) return null;
  const base = d.base && d.base.kind === "stack-span" ? d.base.branch : null;
  if (!base) return [high, high];
  const low = base === d.layerTrunk ? 0 : d.layers.findIndex(l => l.branch === base) + 1;
  return low > 0 || base === d.layerTrunk ? [low, high] : [high, high];
}

function renderLayeredCommits(d, it) {
  const box = el("details", "diff-commits diff-layered");
  box.open = commitsOpen;
  box.addEventListener("toggle", () => { commitsOpen = box.open; });
  const span = diffLayerSpan(d);
  const summary = el("summary", "", `${d.commitCount} commit${d.commitCount === 1 ? "" : "s"}` +
    (d.range ? ` · showing ${esc(d.range.label)}`
      : span && span[0] < span[1] ? ` · ${circled(span[0] + 1)}–${circled(span[1] + 1)}`
      : " · click a layer, ⇧-click another for a span"));
  if (d.range) {
    const all = el("button", "diff-clear", "Show all");
    all.title = "Back to every commit of the layer";
    all.onclick = e => { e.preventDefault(); selectDiffCommits(null); };
    summary.appendChild(all);
  }
  box.appendChild(summary);
  const facts = new Map();     // sha → the layer commit (alsoIn)
  const owner = new Map();     // sha → layer index
  d.layers.forEach((l, i) => l.commits.forEach(c => { facts.set(c.sha, c); owner.set(c.sha, i); }));
  const covered = i => span && i >= span[0] && i <= span[1];
  // The loaded diff's commits under the covered layer that owns them; one
  // no layer lists (past its first 200, a PR's own) goes under the top of the span.
  const loaded = new Map(d.layers.map((l, i) => [i, []]));
  d.commits.forEach((c, i) => {
    let at = owner.get(c.sha);
    if (at === undefined || !covered(at)) at = span ? span[1] : d.layers.length - 1;
    loaded.get(at).push(i);
  });
  const sel = diffCommitSelection(d);
  const list = el("div", "diff-commit-list diff-layer-list");
  const chain = (chainOf(it, d.branch) || {}).chain;
  d.layers.map((l, i) => i).reverse().forEach(i => {
    const layer = d.layers[i];
    list.appendChild(diffLayerHeader(d, it, chain, layer, i, covered(i)));
    const key = `${it.slug}|${layer.branch}`;
    // Covered: the loaded diff's rows (newest first); else the layer's own list.
    const rows = covered(i)
      ? loaded.get(i).slice().reverse().map(k => ({ c: d.commits[k], k }))
      : layer.commits.map(c => ({ c, k: null }));
    const inSel = r => sel && r.k !== null && r.k >= sel[0] && r.k <= sel[1];
    const folds = !diffLayersOpen.has(key) && rows.length > DIFF_LAYER_FOLD;
    const visible = folds ? rows.filter((r, n) => n < DIFF_LAYER_SHOWN || inSel(r)) : rows;
    visible.forEach(r => list.appendChild(diffLayerCommit(d, it, layer, r, inSel(r), facts)));
    const hidden = rows.length - visible.length;
    if (hidden) {
      const more = el("button", "d-layer-more", `${hidden} more commit${hidden === 1 ? "" : "s"} — show`);
      more.onclick = () => { diffLayersOpen.add(key); renderDiffPane(); };
      list.appendChild(more);
    }
  });
  box.appendChild(list);
  return box;
}

function diffLayerHeader(d, it, chain, layer, i, isCovered) {
  const facts = (chain && chain.layers[i] && chain.layers[i].branch === layer.branch) ? chain.layers[i] : { branch: layer.branch };
  const status = layerStatus(facts);
  const h = el("div", `d-layer-head ${status}` + (isCovered ? " sel" : "") + (facts.merged ? " merged" : ""), "");
  const prefix = chain ? chainPrefix(chain) : "";
  h.appendChild(el("span", "d-layer-n", circled(i + 1)));
  h.appendChild(el("span", "d-layer-b", esc(layer.branch.slice(prefix.length) || layer.branch)));
  const chip = layerPrChip(facts);
  if (chip) h.appendChild(chip);
  h.insertAdjacentHTML("beforeend", `<span class="d-commit-stat">${diffStat(layer.add, layer.del)}</span>` +
    `<span class="d-layer-count">${layer.n} commit${layer.n === 1 ? "" : "s"}</span>`);
  if (facts.needsRestack && !facts.merged) {
    const r = el("span", "d-layer-behind", "⟳");
    r.title = `${facts.parent}'s tip is not in this branch — it needs a restack`;
    h.appendChild(r);
  }
  h.title = `${layer.branch}${facts.parent ? ` vs ${facts.parent}` : ""}\nclick: select this layer · ⇧-click: span from the last layer clicked`;
  h.onmousedown = e => { if (e.shiftKey) e.preventDefault(); }; // no text selection on ⇧-click
  h.onclick = e => pickDiffLayer(d, it, i, e.shiftKey);
  return h;
}

function diffLayerCommit(d, it, layer, r, isSel, facts) {
  const c = r.c;
  const also = (facts.get(c.sha) || c).alsoIn;
  const row = el("div", "diff-commit-row d-layer-commit" + (isSel ? " sel" : "") + (also ? " stale" : "") + (r.k === null ? " other" : ""),
    `<span class="d-sha">${esc(c.short)}</span><span class="d-subject">${esc(c.subject)}</span>` +
    (also ? `<span class="d-also">also in ${esc(diffLayerName(d, also))}</span>` : "") +
    `<span class="d-commit-stat">${diffStat(c.add, c.del)}</span>` +
    (c.time ? `<span class="d-when">${esc(agoText(c.time))}</span>` : ""));
  row.title = `${c.sha}\n${c.subject}` + (also ? `\n${also} already holds an equivalent of this commit — a leftover a restack drops` : "");
  row.onmousedown = e => { if (e.shiftKey) e.preventDefault(); };
  row.onclick = e => {
    if (r.k !== null) { pickDiffCommit(d, r.k, e.shiftKey); return; }
    // Another layer's commit: select that layer, showing this commit.
    pickBranch(it.slug, layer.branch);
    const choice = diffChoice[it.slug] || {};
    const scope = choice.scope || d.scope;
    diffChoice[it.slug] = { scope, rebase: choice.rebase, from: c.sha, to: c.sha, anchor: c.sha };
    diffSpanAnchor[it.slug] = layer.branch;
    renderChatSide();
    syncDiffPane();
  };
  return row;
}

/* alsoIn as the list says it: a layer's number, or the trunk's name. */
function diffLayerName(d, branch) {
  const i = d.layers.findIndex(l => l.branch === branch);
  return i >= 0 ? circled(i + 1) : branch;
}

/* A header click selects its layer; ⇧-click spans from the last header
   clicked (else the shown layer) to this one: base= the lower one's parent,
   the upper one selected, under Commits (GitHub diffs a PR against its own
   base, so the PR scope can't show a span). */
function pickDiffLayer(d, it, i, extend) {
  const slug = it.slug;
  const branch = d.layers[i].branch;
  // The last header clicked while it is still shown (picked elsewhere since: the shown layer).
  const span = diffLayerSpan(d);
  let anchorAt = d.layers.findIndex(l => l.branch === diffSpanAnchor[slug]);
  if (!span || anchorAt < span[0] || anchorAt > span[1]) anchorAt = d.layers.findIndex(l => l.branch === d.branch);
  if (!extend || anchorAt < 0 || anchorAt === i) {
    diffSpanAnchor[slug] = branch;
    setSelectedBranch(slug, branch);
    return;
  }
  const low = Math.min(anchorAt, i), high = Math.max(anchorAt, i);
  const base = low === 0 ? d.layerTrunk : d.layers[low - 1].branch;
  pickBranch(slug, d.layers[high].branch);
  const choice = diffChoice[slug] || {};
  diffChoice[slug] = { scope: "commits", base, rebase: choice.rebase };
  if (mode === "chat" && chatSlug === slug) { renderChatSide(); syncDiffPane(); }
}

/* ------- file layer circles ------- */
/* ①④⑤ on a file header: the layers whose own diff touches the file. */
function diffFileLayerCircles(f) {
  const d = diffView.data;
  const at = d && d.fileLayers && d.layers && d.fileLayers[f.path];
  if (!at || !at.length) return "";
  const it = items.find(i => i.slug === diffView.slug);
  const chain = it && (chainOf(it, d.branch) || {}).chain;
  return `<span class="d-layers">` + at.map(i => {
    const layer = d.layers[i];
    const facts = chain && chain.layers[i] && chain.layers[i].branch === layer.branch ? chain.layers[i] : {};
    return `<span class="d-layer-circle ${layerStatus(facts)}" title="${esc(layer.branch)}">${circled(i + 1)}</span>`;
  }).join("") + `</span>`;
}
