"use strict";

/* ------- an item's chains and its one selected branch -------
   it.chains (GhStack.chains): every gh-stack holding one of the item's
   branches, bottom → top, then each other linked branch as a loose chain
   of one. One branch per item is selected: it drives both the diff pane's
   branch and the Workspace target (pf, the IDE, Terminal, Work on this).
   An explicit pick is remembered per slug for the browser tab; without one
   the default is the branch the chat runs on when a chain holds it, else
   the top of the first chain — the server works that out with the
   workspace fetch (defaultBranch), since only it can ask where the chat runs. */
let branchPicks = {}; // slug → the branch picked in the rails or the diff bar ("": the chat's own folder)
try { branchPicks = JSON.parse(sessionStorage.getItem("qm-branch-picks") || "{}") || {}; } catch (e) { /* storage blocked or garbled: defaults */ }
const chatBranches = {}; // slug → { chat, def }: where the chat runs and the default selection, from /api/workspace

const itemChains = it => (it && it.chains) || [];
const chainBranches = it => itemChains(it).flatMap(c => c.layers.map(l => l.branch));
const chainTop = chain => chain.layers[chain.layers.length - 1].branch;
/* A pick counts while it still names the chat's folder (""), one of the
   item's branches or where the chat runs; an unlinked one falls back to the default. */
function hasPick(slug) {
  if (!Object.prototype.hasOwnProperty.call(branchPicks, slug)) return false;
  const b = branchPicks[slug];
  const it = items.find(i => i.slug === slug);
  return b === "" || (chatBranches[slug] || {}).chat === b || !!(it && (it.branches || []).includes(b));
}

/* The item's selected branch, or null (no chains, or the chat's folder picked). */
function selectedBranch(it) {
  if (!it) return null;
  if (hasPick(it.slug)) return branchPicks[it.slug] || null;
  const known = chatBranches[it.slug];
  if (known) return known.def || null;
  const first = itemChains(it)[0];
  return first ? chainTop(first) : null;
}

/* The branch the diff pane asks for: null leaves it to the server, whose
   default is the chat's own checkout — so the default selection, when that
   is where the chat runs, costs no reload once the workspace answer lands. */
function diffBranchFor(slug) {
  if (hasPick(slug)) return branchPicks[slug] || null;
  const known = chatBranches[slug];
  return known && known.def && known.def !== known.chat ? known.def : null;
}

/* The branch the workspace fetch and its actions name: only a chain's (the
   server refuses a branch the item doesn't link); none → its default. */
function workspaceBranchFor(it) {
  const picked = hasPick(it.slug) ? branchPicks[it.slug] : null;
  return picked && chainBranches(it).includes(picked) ? picked : null;
}

/* Remember a pick without re-rendering anything. */
function pickBranch(slug, branch) {
  branchPicks[slug] = branch || "";
  try { sessionStorage.setItem("qm-branch-picks", JSON.stringify(branchPicks)); } catch (e) { /* this page only */ }
}

/* Select a branch from the rails or the diff bar: the side panel and the
   diff pane follow. The diff keeps its scope unless that needs a checkout
   the branch lacks; a selected run of commits belonged to the old branch. */
function setSelectedBranch(slug, branch) {
  pickBranch(slug, branch);
  const choice = diffChoice[slug] || {};
  const scope = diffNeedsCheckout(choice.scope) && !branchHasCheckout(slug, branch) ? "branch" : choice.scope;
  diffChoice[slug] = { scope, rebase: choice.rebase };
  if (mode === "chat" && chatSlug === slug) { renderChatSide(); syncDiffPane(); }
}

function branchHasCheckout(slug, branch) {
  const d = diffView.slug === slug ? diffView.data : null;
  if (d && d.branches) {
    const entry = diffBranchEntry(d, branch);
    if (entry.branch !== undefined) return entry.checkout !== false;
  }
  const it = items.find(i => i.slug === slug);
  return !branch || !!(it && it.worktrees && it.worktrees[branch]) || (chatBranches[slug] || {}).chat === branch;
}

/* ------- layer facts the rails, the chats list and (later) the diff strip share ------- */
const circled = n => n >= 1 && n <= 20 ? String.fromCharCode(0x2460 + n - 1) : `(${n})`;

/* The stack's common branch-name prefix up to a - or /, so each layer reads by its own part. */
function chainPrefix(chain) {
  const names = chain.layers.map(l => l.branch);
  if (names.length < 2) return "";
  let p = names[0];
  names.forEach(n => { while (!n.startsWith(p)) p = p.slice(0, -1); });
  const cut = Math.max(p.lastIndexOf("-"), p.lastIndexOf("/"));
  return cut > 0 ? p.slice(0, cut + 1) : "";
}

/* The PR's review state comes from the PRs view's list (the user's own open
   PRs carry reviewDecision and draft); the layer itself only knows
   OPEN/MERGED/CLOSED. */
function layerStatus(layer) {
  if (layer.merged) return "merged";
  if (!layer.prState) return "none";
  if (layer.prState !== "OPEN") return layer.prState.toLowerCase();
  const pr = layer.pr_url && prs.find(p => p.url === layer.pr_url);
  if (pr && pr.draft) return "draft";
  if (pr && pr.reviewDecision === "APPROVED") return "approved";
  if (pr && pr.reviewDecision === "CHANGES_REQUESTED") return "changes";
  if (pr && pr.reviewDecision === "REVIEW_REQUIRED") return "review";
  return "open";
}
const LAYER_STATUS_LABEL = {
  merged: "merged", closed: "closed", draft: "draft", approved: "approved",
  changes: "changes requested", review: "review required", open: "open", none: "no PR",
};

/* The #PR + state chip of a layer (rail nodes, the diff's layer headers), or null without a PR. */
function layerPrChip(l) {
  if (!l.pr_number && !l.prState) return null;
  const status = layerStatus(l);
  const label = (l.pr_number ? `#${l.pr_number} ` : "") + LAYER_STATUS_LABEL[status];
  const chip = el(l.pr_url ? "a" : "span", "pr-chip " + status, esc(label.trim()));
  if (l.pr_url) { chip.href = l.pr_url; chip.target = "_blank"; chip.rel = "noreferrer"; chip.onclick = e => e.stopPropagation(); }
  return chip;
}

/* The selected rail node's buttons: the diff bar's 📊 and 🏁, then Diff ›.
   A click acts without reaching the node (whose click selects). */
function railTools(it, branch) {
  const tools = el("span", "rail-tools");
  tools.onclick = e => e.stopPropagation();
  [branchStatsButton(it.slug, branch), benchmarkButton(it, branch)].forEach(b => {
    if (b) { b.classList.add("rail-icon"); tools.appendChild(b); }
  });
  const link = el("button", "rail-diff", "Diff ›");
  link.title = `Open the diff pane on ${branch}`;
  link.onclick = () => { if (!diffOpen) toggleDiff(); };
  tools.appendChild(link);
  return tools;
}

/* The chain holding a branch, with the branch's 0-based layer index, or null. */
function chainOf(it, branch) {
  for (const c of itemChains(it)) {
    const at = c.layers.findIndex(l => l.branch === branch);
    if (at >= 0) return { chain: c, at };
  }
  return null;
}

/* Open stack layers behind their parent: the ⟳ count. */
const restackLayers = it => itemChains(it).filter(c => c.kind === "stack")
  .flatMap(c => c.layers.filter(l => l.needsRestack && !l.merged));

/* "pf serves ③ while the chat is on ⑤" when pf serves a lower layer of the
   chat's own stack, else null. */
function stalePfText(it) {
  const chat = (chatBranches[it.slug] || {}).chat;
  if (!it.servedBranch || !chat) return null;
  for (const c of itemChains(it)) {
    if (c.kind !== "stack") continue;
    const at = b => c.layers.findIndex(l => l.branch === b);
    const served = at(it.servedBranch), on = at(chat);
    if (served >= 0 && on >= 0 && served < on) return `${devCmd()} serves ${circled(served + 1)} while the chat is on ${circled(on + 1)}`;
  }
  return null;
}

/* The restack chip's action: only ever on a click. */
function restackStack(it, branch) {
  act("restack", { slug: it.slug, args: { branch } }).then(r => {
    if (r.ok) toast(r.mode === "start" ? `${it.slug}: a new chat restacks the stack` : `${it.slug}: restack asked in its chat`);
  });
}

/* The chats list's thin bar under the title: one segment per
   stack layer and per loose chain, a gap between chains, coloured by PR state. */
function chainSegmentBar(it) {
  const chains = itemChains(it);
  if (!chains.length) return null;
  const bar = el("div", "seg-bar");
  chains.forEach(c => {
    const group = el("span", "seg-chain");
    group.style.flexGrow = String(c.layers.length); // every segment the same width
    c.layers.forEach((l, i) => {
      const status = layerStatus(l);
      const s = el("span", "seg " + status + (l.needsRestack && !l.merged ? " restack" : ""));
      s.title = `${c.kind === "stack" ? circled(i + 1) + " " : ""}${l.branch} · ${LAYER_STATUS_LABEL[status]}` +
        (l.needsRestack && !l.merged ? " · needs a restack" : "");
      group.appendChild(s);
    });
    bar.appendChild(group);
  });
  return bar;
}

/* The chats list row meta's amber "⟳ n", or null. */
function restackCount(it) {
  const behind = restackLayers(it);
  if (!behind.length) return null;
  const r = el("span", "restack-count", `⟳ ${behind.length}`);
  r.title = `${behind.length} stack layer${behind.length === 1 ? "" : "s"} behind ${behind.length === 1 ? "its parent" : "their parents"}: ` +
    behind.map(l => l.branch).join(", ");
  return r;
}
