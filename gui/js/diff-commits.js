"use strict";

/* ------- recently shown commits: Next commit → and back without a wait ------- */
/* The diffs of selected commits (Commits and PR scopes) the pane showed or
   prefetched in the last minute, newest last. A commit's diff doesn't
   change, but its list and the PR around it may: they all go on ↻, at a
   turn's end, on another chat and when the pane opens. An entry holds the
   request (res once it answered ok), so a click during a prefetch waits on
   that same request. */
const DIFF_CACHE_SIZE = 8;
const DIFF_CACHE_MS = 60 * 1000;
const diffCache = new Map(); // diffKey → { at, promise, res }

const diffKeepable = choice => !!choice.from && diffHasCommitList(choice.scope);

function diffCacheGet(key) {
  const kept = diffCache.get(key);
  if (!kept) return null;
  diffCache.delete(key);
  if (Date.now() - kept.at > DIFF_CACHE_MS) return null;
  diffCache.set(key, kept); // the most recently used goes last
  return kept;
}

function diffCachePut(key, promise) {
  const kept = { at: Date.now(), promise, res: null };
  diffCache.delete(key);
  diffCache.set(key, kept);
  while (diffCache.size > DIFF_CACHE_SIZE) diffCache.delete(diffCache.keys().next().value);
  promise.then(res => {
    if (res.ok) kept.res = res;
    else if (diffCache.get(key) === kept) diffCache.delete(key); // a failure is asked again
  });
}

/* With one commit selected, the next one's diff loads in the background —
   without fresh=1 or review threads: the server's plain answer. */
function prefetchNextDiff() {
  const next = diffNextCommit(diffView.data);
  if (!next) return;
  const slug = diffView.slug;
  const choice = diffCommitChoice(slug, next.sha);
  const key = diffKey(slug, choice);
  if (!diffCache.has(key)) diffCachePut(key, fetchDiff(slug, diffParams(slug, choice)));
}

const DIFF_SCOPES = [
  ["branch", "Branch", "Everything since the base: commits, uncommitted and untracked work"],
  ["commits", "Commits", "Committed work since the base, as the PR shows it — pick commits from the list to narrow it"],
  ["uncommitted", "Uncommitted", "Only what is not committed yet"],
  ["prompt", "Since prompt", "What changed in the chat's worktree since one of its prompts (committed or not) — the last prompt unless you pick another"],
  ["pr", "PR", "The pull request as GitHub shows it: its pushed head against its base — pick commits from the list to narrow it"],
];

/* Uncommitted and Since prompt read a working tree: a branch offered only
   as a ref (checkout: false) has none, so they are off for it. */
const diffNeedsCheckout = scope => scope === "uncommitted" || scope === "prompt";

/* The payload's entry for a branch name (null: detached HEAD), or {}. */
const diffBranchEntry = (d, branch) => d.branches.find(b => (b.branch || null) === (branch || null)) || {};

/* A stack span's lower end: the server honours base= under Branch and Commits only. */
const diffSpanBase = choice => (choice.scope === "commits" || choice.scope === "branch") && choice.base || null;

/* Commits and PR both start with a commit list to narrow the diff by. */
const diffHasCommitList = scope => scope === "commits" || scope === "pr";

const diffPrLabel = pr => `${(pr.repo || "").split("/").pop()}#${pr.number}`;

/* The PR the pane shows in its PR scope, or null. */
const diffPrScope = () => diffView.data && diffView.data.scope === "pr" && diffView.data.pr ? diffView.data.pr : null;

/* What a draft made in the PR scope stores about its PR (D7): the PR, its
   base and the commit the view anchors to — the head, or a selected run's
   last commit (GitHub has no range anchor). */
function diffPrFields() {
  const pr = diffPrScope();
  return pr ? { repo: pr.repo, number: pr.number, base: pr.baseSha, commit: diffView.data.anchor } : {};
}

/* Since prompt: the chat session's prompts, newest first. The newest stays
   unpicked in diffChoice, so the scope follows each new prompt. */
function renderDiffPrompts(d) {
  const pick = el("select", "diff-prompt");
  pick.title = "Diff from the snapshot taken when this prompt was sent";
  d.prompts.forEach(c => {
    const o = el("option", "", esc(`${agoText(c.at)} · ${c.prompt || "(prompt text not in the transcript)"}`));
    o.value = c.id;
    o.selected = c.id === d.prompt;
    o.title = `${c.at}\n${c.prompt || ""}`;
    pick.appendChild(o);
  });
  pick.onchange = () => {
    const choice = diffChoice[chatSlug] || {};
    const newest = pick.value === d.prompts[0].id;
    diffChoice[chatSlug] = { scope: "prompt", prompt: newest ? null : pick.value, moved: choice.moved,
      rebase: choice.rebase };
    loadDiff();
  };
  return pick;
}

/* Since prompt: the chat's folder (its snapshot diff), or one of the repo's
   branches that moved since the prompt — a sub-agent's worktree, say — as
   the commits it gained. */
function renderDiffMoved(d) {
  const pick = el("select", "diff-moved");
  pick.title = "Diff the chat's folder, or a branch that moved since this prompt (its commits only)";
  const folder = el("option", "", "chat folder");
  folder.value = "";
  pick.appendChild(folder);
  d.movedBranches.forEach(b => {
    const o = el("option", "", esc(`${b.branch} · ${b.commits} commit${b.commits === 1 ? "" : "s"}`));
    o.value = b.branch;
    o.selected = b.branch === d.movedBranch;
    pick.appendChild(o);
  });
  pick.onchange = () => {
    const choice = diffChoice[chatSlug] || {};
    diffChoice[chatSlug] = { scope: "prompt", prompt: choice.prompt, moved: pick.value || null,
      rebase: choice.rebase };
    loadDiff();
  };
  return pick;
}

/* Since prompt, only when the branch was rebased since the prompt: hide the
   upstream changes the rebase brought in (the default) or show them. */
function renderDiffRebase(d) {
  const n = d.rebase.commits;
  const b = el("button", "diff-rebase", esc(`hide rebase (${n} upstream commit${n === 1 ? "" : "s"})`));
  const hidden = !(diffChoice[chatSlug] || {}).rebase;
  b.setAttribute("aria-pressed", String(hidden));
  b.title = `The branch moved onto a newer ${d.rebase.onto} since this prompt: ` +
    (d.rebase.hidden ? "showing only the chat's own changes — click to include the rebase's"
      : hidden ? "it couldn't be hidden, so its changes are included"
      : "the rebase's changes are included — click to hide them");
  b.onclick = () => {
    const choice = diffChoice[chatSlug] || {};
    diffChoice[chatSlug] = { ...choice, scope: "prompt", rebase: hidden ? "show" : null };
    loadDiff();
  };
  return b;
}

const DIFF_STATUS = { added: "A", deleted: "D", renamed: "R", modified: "M" };

/* Branch scope only: the server marks each line and file by whether it is
   committed yet (line.uncommitted, file.commitStatus). */
const diffHasUncommittedLines = d => d.files.some(f => f.hunks.some(h => h.lines.some(l => l.uncommitted)));

function diffCommitBadge(f) {
  if (f.commitStatus === "uncommitted") return '<span class="d-unc-badge" title="None of this file\'s changes are committed">uncommitted</span>';
  if (f.commitStatus === "mixed") return '<span class="d-unc-badge partly" title="Some of this file\'s changes are not committed yet">partly uncommitted</span>';
  return "";
}

/* ------- commit list (Commits scope): pick one commit, or shift-click a contiguous run ------- */
let commitsOpen = true; // the list's fold, kept across re-renders

function renderDiffCommits(d) {
  const box = el("details", "diff-commits");
  box.open = commitsOpen;
  box.addEventListener("toggle", () => { commitsOpen = box.open; });
  const sel = diffCommitSelection(d);
  const summary = el("summary", "", `${d.commitCount} commit${d.commitCount === 1 ? "" : "s"}` +
    (d.range ? ` · showing ${esc(d.range.label)}` : " · click one, ⇧-click a run"));
  if (d.range) {
    const all = el("button", "diff-clear", "Show all");
    all.title = d.scope === "pr" ? "Back to every commit of the pull request" : "Back to every commit of the branch";
    all.onclick = e => { e.preventDefault(); selectDiffCommits(null); };
    summary.appendChild(all);
  }
  box.appendChild(summary);
  if (d.commitCount > d.commits.length) {
    box.appendChild(el("div", "diff-note", `Only the newest ${d.commits.length} of ${d.commitCount} are listed.`));
  }
  const list = el("div", "diff-commit-list");
  d.commits.forEach((c, i) => {
    const row = el("div", "diff-commit-row" + (sel && i >= sel[0] && i <= sel[1] ? " sel" : ""),
      `<span class="d-sha">${esc(c.short)}</span><span class="d-subject">${esc(c.subject)}</span>` +
      `<span class="d-commit-stat">${diffStat(c.add, c.del)}</span><span class="d-when">${esc(agoText(c.time))}</span>`);
    row.title = `${c.sha}\n${c.subject}`;
    row.onmousedown = e => { if (e.shiftKey) e.preventDefault(); }; // no text selection on ⇧-click
    row.onclick = e => pickDiffCommit(d, i, e.shiftKey);
    list.appendChild(row);
  });
  box.appendChild(list);
  return box;
}

/* The selected commits' full messages, above the files: one commit's open,
   a run's in a fold (kept across re-renders like the list's). */
let commitMessagesOpen = false;

function diffCommitMessage(m) {
  const box = el("div", "diff-message",
    `<div class="d-msg-head"><span class="d-sha">${esc(m.short)}</span><span>${esc(m.author)}</span>` +
    `<span class="d-when" title="${esc(m.date)}">${esc(agoText(m.date))}</span></div>`);
  box.appendChild(el("pre", "d-msg-body", esc(m.body)));
  return box;
}

function renderDiffMessages(messages) {
  if (messages.length === 1) {
    const box = el("div", "diff-messages");
    box.appendChild(diffCommitMessage(messages[0]));
    return box;
  }
  const box = el("details", "diff-messages");
  box.open = commitMessagesOpen;
  box.addEventListener("toggle", () => { commitMessagesOpen = box.open; });
  box.appendChild(el("summary", "", `${messages.length} commit messages`));
  messages.forEach(m => box.appendChild(diffCommitMessage(m)));
  return box;
}

/* The selected run as [first, last] list indices, or null for all commits. */
function diffCommitSelection(d) {
  if (!d.range) return null;
  const from = d.commits.findIndex(c => c.sha === d.range.from);
  const to = d.commits.findIndex(c => c.sha === d.range.to);
  return from < 0 || to < 0 ? null : [from, to];
}

/* A click selects that one commit (or, on the selected one, all again); a
   shift-click stretches from the last clicked commit to this one. */
function pickDiffCommit(d, i, extend) {
  const choice = diffChoice[chatSlug] || {};
  const sel = diffCommitSelection(d);
  const sha = d.commits[i].sha;
  if (extend && sel) {
    let anchor = d.commits.findIndex(c => c.sha === choice.anchor);
    if (anchor < 0) anchor = sel[0];
    selectDiffCommits(d.commits[Math.min(anchor, i)].sha, d.commits[Math.max(anchor, i)].sha, d.commits[anchor].sha);
  } else if (sel && sel[0] === i && sel[1] === i) {
    selectDiffCommits(null);
  } else {
    selectDiffCommits(sha, sha, sha);
  }
}

/* After the last file of a single selected commit: step to the commit after
   it in the list (oldest first), as a click there would, and start at the top. */
function renderDiffNextCommit(d) {
  const c = diffNextCommit(d);
  if (!c) return null;
  const next = el("button", "diff-next-commit",
    `Next commit → <span class="d-sha">${esc(c.short)}</span><span class="d-subject">${esc(c.subject)}</span>`);
  next.title = `${c.sha}\n${c.subject}`;
  next.onclick = () => {
    selectDiffCommits(c.sha, c.sha, c.sha);
    $("#diff-body").scrollTop = 0;
  };
  return next;
}

/* The commit after the single selected one, or null. */
function diffNextCommit(d) {
  if (!d || !diffHasCommitList(d.scope)) return null;
  const sel = diffCommitSelection(d);
  if (!sel || sel[0] !== sel[1] || sel[1] + 1 >= d.commits.length) return null;
  return d.commits[sel[1] + 1];
}

function selectDiffCommits(from, to = from, anchor = from) {
  diffChoice[chatSlug] = diffCommitChoice(chatSlug, from, to, anchor);
  loadDiff();
}

/* The item's choice with these commits selected (from null: all of them). */
function diffCommitChoice(slug, from, to = from, anchor = from) {
  const choice = diffChoice[slug] || {};
  // The scope the list belongs to, also when the server picked it (a Review item's PR).
  const scope = choice.scope || (diffView.data && diffView.data.scope);
  return from ? { ...choice, scope, from, to, anchor } : { scope, rebase: choice.rebase, base: choice.base };
}

/* A draft's range names commits by short sha: the full one when the shown
   list has it (the selection and ⇧-click compare full shas), else the short
   one, which the server resolves too. */
function diffCommitSha(short) {
  const c = ((diffView.data && diffView.data.commits) || []).find(c => c.short === short || c.sha.startsWith(short));
  return c ? c.sha : short;
}
