"use strict";

/* ------- the pending review: posting GitHub drafts, outdated drafts ------- */
/* Post as pending review (the tray's GitHub group, D4) asks review-preview
   for the numbers — a gh query and a fetch — and confirms them in a modal;
   review-post then runs as the item's job (PendingReview: one GitHub call per
   draft), its result a toast. A draft GitHub didn't take stays, marked
   failed (d.failed).
   The PR scope's payload says where each of the item's GitHub drafts on that
   PR would post now (reviewRoutes, ReviewPlan). An outdated one — its line
   changed since a push, or its commit left the PR (D10, D11) — is a card at
   the top of its file in the whole PR's view: Place on a line, Comment on
   the file, Comment on the old commit, Delete. Elsewhere (a selected run,
   or its file left the PR) the card lives in the tray, without Place on a
   line, and without Comment on the file when the file is gone. */
let diffPlacing = null; // the draft "Place on a line" puts on the next line clicked, or null

/* Where the shown PR scope says the draft posts now, or null when the pane
   shows another PR, another scope or nothing. */
function reviewRoute(d) {
  const data = diffView.data;
  if (!data || diffView.slug !== chatSlug || data.scope !== "pr" || !data.pr || !data.reviewRoutes) return null;
  if (Number(data.pr.number) !== Number(d.number) || String(data.pr.repo).toLowerCase() !== String(d.repo).toLowerCase()) return null;
  return data.reviewRoutes[d.id] || null;
}
const isOutdatedDraft = d => { const r = reviewRoute(d); return !!(r && r.route === "outdated"); };

/* Cards go at the top of their file in the whole PR's view — its lines are
   the head's, so Place on a line can use them — and in the tray otherwise. */
const outdatedInDiff = d => {
  const data = diffView.data;
  const r = reviewRoute(d);
  return !!(r && r.route === "outdated" && !r.fileGone && !data.range && data.files.some(f => f.path === d.path));
};

function renderOutdatedCards(box, f) {
  itemDrafts().filter(d => isGithubDraft(d) && d.path === f.path && outdatedInDiff(d))
    .forEach(d => box.appendChild(outdatedCard(d, reviewRoute(d))));
}

/* The draft as it was: the reason, its old line with a few around it, the
   comment, and what can still be done with it. */
function outdatedCard(d, r, inTray = false) {
  const card = el("div", "d-outdated");
  card.dataset.id = d.id;
  const sha = String(d.commit || "").slice(0, 7);
  card.appendChild(el("div", "d-outdated-head",
    `<b>Outdated</b> ${esc(d.path)}:${esc(diffLinesLabel(d))} @${esc(sha)} — ${esc(r.reason || "")}`));
  if (!inTray && Array.isArray(r.context) && r.context.length) {
    const pre = el("div", "d-outdated-code");
    r.context.forEach(l => {
      const kind = l.t === "+" ? "add" : l.t === "-" ? "del" : "ctx";
      pre.appendChild(el("div", `d-outdated-line ${kind}${l.at ? " at" : ""}`, `${esc(l.t || " ")} ${esc(l.s)}`));
    });
    card.appendChild(pre);
  }
  if (!inTray) card.appendChild(el("div", "d-outdated-comment", esc(d.comment))); // the tray entry shows it already
  const acts = el("div", "d-comment-acts");
  if (!inTray) {
    const place = el("button", "primary gh", "Place on a line");
    place.title = "Then click the line of this diff the comment belongs on";
    place.onclick = () => startPlacingDraft(d);
    acts.appendChild(place);
  }
  if (!r.fileGone) {
    const file = el("button", "", "Comment on the file");
    file.title = `Post it as a comment on ${d.path} as a whole`;
    file.onclick = () => placeDraft(d, { how: "file" });
    acts.appendChild(file);
  }
  if (r.oldCommit) {
    const old = el("button", inTray ? "primary gh" : "", "Comment on the old commit");
    old.title = `Post it on ${r.oldCommit.slice(0, 7)}, the commit it was written on — GitHub shows it as outdated there`;
    old.onclick = () => placeDraft(d, { how: "commit" });
    acts.appendChild(old);
  }
  const del = el("button", "danger", "Delete");
  del.title = "Delete this draft";
  del.onclick = () => deleteDraft(d);
  acts.appendChild(del);
  card.appendChild(acts);
  return card;
}

/* From the tray: the card at the top of its file, the file opened. */
function revealOutdatedCard(d) {
  const card = document.querySelector(`#diff-body .d-outdated[data-id="${CSS.escape(d.id)}"]`);
  if (!card) return;
  const box = card.closest("details");
  if (box && !box.open) box.open = true;
  flashDiffTarget(card, "center");
}

function startPlacingDraft(d) {
  diffPlacing = d;
  document.body.classList.add("diff-placing");
  toast("Click the line to put the comment on — Esc cancels");
}

function stopPlacingDraft() {
  diffPlacing = null;
  document.body.classList.remove("diff-placing");
}

/* The click a Place on a line waited for: true when it took the click. */
function placeDraftOnRow(tr) {
  if (!diffPlacing) return false;
  const d = diffPlacing;
  stopPlacingDraft();
  const a = diffRowAddress(tr);
  placeDraft(d, { how: "line", path: a.path, side: a.side, line: a.line, code: a.code });
  return true;
}

/* draft-place moves the draft (the server checks GitHub takes it there);
   the diff reloads for its new route. */
async function placeDraft(d, args) {
  const pr = diffPrScope();
  const res = await act("draft-place", { slug: chatSlug, args: { id: d.id, commit: pr && pr.headSha, base: pr && pr.baseSha, ...args } });
  if (res.ok) {
    toast(args.how === "commit" ? `It will go on ${String(d.commit || "").slice(0, 7)}` : "Placed — it posts there now");
    loadDiff();
  }
}

document.addEventListener("keydown", e => {
  if (diffPlacing && e.key === "Escape" && !(e.target.closest && e.target.closest(".term-host"))) { e.preventDefault(); e.stopPropagation(); stopPlacingDraft(); toast("Not placed"); }
}, true);

/* ------- Post as pending review ------- */
async function postPendingReview(repo, number, ids) {
  const slug = chatSlug;
  const label = `${String(repo).split("/").pop()}#${number}`;
  modal(m => { m.innerHTML = `<h2>Post to ${esc(label)}</h2><p class="sub">Checking the pull request on GitHub…</p>`; });
  const res = await act("review-preview", { slug, args: { repo, number, ids } });
  if (!res.ok) { closeModal(); return res; }
  reviewConfirmModal(slug, repo, number, ids, res.preview);
  return res;
}

function reviewConfirmModal(slug, repo, number, ids, p) {
  const posting = p.head + p.commit + (p.replies || 0);
  modal(m => {
    const lines = [];
    const one = n => n === 1;
    if (p.commit) lines.push(`${p.commit} ${one(p.commit) ? "goes" : "go"} on the commit ${one(p.commit) ? "it was" : "they were"} written on — if GitHub refuses that, as a file comment quoting the line`);
    if (p.replies) lines.push(`${p.replies} thread ${one(p.replies) ? "reply goes" : "replies go"} into ${one(p.replies) ? "its thread" : "their threads"}`);
    if (p.moved) lines.push(`${plural(p.moved, "draft")} moved with a push or rebase and ${one(p.moved) ? "posts" : "post"} where the line is now`);
    if (p.outdated) lines.push(`${p.outdated} ${one(p.outdated) ? "draft is" : "drafts are"} outdated and won't be posted — ${one(p.outdated) ? "it stays" : "they stay"} in the tray`);
    lines.push(p.pending != null ? `Adds to the pending review you already have there (${plural(p.pending, "comment")})`
                                 : "Starts a pending review — submit it on GitHub with your verdict");
    m.innerHTML = `<h2>${esc(plural(posting, "comment"))} → pending review on ${esc(p.pr)}</h2>` +
      `<p class="sub review-confirm-link"><a href="${esc(p.url)}" target="_blank" rel="noopener">${esc(p.url)}</a></p>` +
      `<ul class="review-confirm">${lines.map(l => `<li>${esc(l)}</li>`).join("")}</ul>`;
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel");
    cancel.onclick = closeModal;
    const go = el("button", "btn primary", posting ? `Post ${plural(posting, "comment")}` : "Nothing to post");
    go.disabled = !posting;
    go.onclick = async () => {
      closeModal();
      const res = await act("review-post", { slug, args: { repo, number, ids } });
      if (res.ok) toast(`posting ${plural(posting, "comment")} to ${p.pr}…`);
    };
    bar.append(cancel, go);
    m.appendChild(bar);
    setTimeout(() => go.focus(), 0);
  });
}

/* The job's toast comes from jobFinished; posted drafts left the store, so
   the tray and the diff's routes follow. */
function reviewPostFinished(r) {
  if (!r.review) return;
  draftsChanged();
  if (diffOpen && diffView.data && diffView.data.scope === "pr" && diffView.slug === r.key) loadDiff();
}
