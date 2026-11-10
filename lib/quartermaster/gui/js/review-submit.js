"use strict";

/* ------- submitting the review with a verdict, and the PR's tray group ------- */
/* Submit review… (the PR scope's diff bar, and each PR's GitHub group in the
   tray) opens one form: Approve / Comment / Request changes — never
   pre-selected, a verdict is always a deliberate pick — a summary
   pre-filled from the PR's review-summary draft (Claude's suggestion, its
   verdict a hint beside the radios), and what goes with it, from
   review-preview (submit: true). Submit runs review-submit as the item's
   job; its toast arrives via jobFinished and reviewPostFinished refreshes
   the tray and the PR scope. The server refuses what the form disables:
   approving or requesting changes on your own PR, a change request without
   a summary, a comment review with neither a summary nor a line comment. */
const REVIEW_VERDICTS = [["APPROVE", "approve", "Approve"], ["COMMENT", "comment", "Comment"],
  ["REQUEST_CHANGES", "request-changes", "Request changes"]];
const isReviewSummary = d => d.kind === "review-summary";
const verdictLabel = v => (REVIEW_VERDICTS.find(([, word]) => word === v) || [])[2] || "";

function submitReviewButton(repo, number, ids) {
  const b = el("button", "primary gh", "Submit review…");
  b.title = `Submit your review on ${String(repo).split("/").pop()}#${number} with a verdict — the drafts here go with it`;
  b.onclick = () => openSubmitReview(repo, number, ids);
  return b;
}

async function openSubmitReview(repo, number, ids) {
  const slug = chatSlug;
  const label = `${String(repo).split("/").pop()}#${number}`;
  modal(m => { m.innerHTML = `<h2>Review ${esc(label)}</h2><p class="sub">Checking the pull request on GitHub…</p>`; });
  const res = await act("review-preview", { slug, args: { repo, number, ids, submit: true } });
  if (!res.ok) { closeModal(); return res; }
  submitReviewModal(slug, repo, number, ids, res.preview);
  return res;
}

/* What goes with the verdict, in the form's words. */
function submitReviewLines(p, posting) {
  const one = n => n === 1;
  const lines = [];
  if (posting) lines.push(`${plural(posting, "draft")} from the tray ${one(posting) ? "is" : "are"} posted with it`);
  if (p.pending) lines.push(`Includes ${plural(p.pending, "comment")} already pending on GitHub`);
  if (p.outdated) lines.push(`${p.outdated} outdated ${one(p.outdated) ? "draft won't be posted — it stays" : "drafts won't be posted — they stay"} in the tray`);
  if (!lines.length) lines.push("No line comments — just the verdict and the summary");
  return lines;
}

function submitReviewModal(slug, repo, number, ids, p) {
  const posting = p.head + p.commit + (p.replies || 0);
  const comments = posting + (p.pending || 0);
  const summary = p.summary || null;
  const ownReason = "GitHub doesn't let you approve or request changes on your own pull request";
  modal(m => {
    m.classList.add("rv-submit");
    m.innerHTML = `<h2>Submit your review on ${esc(p.pr)}</h2>` +
      `<p class="sub review-confirm-link"><a href="${esc(p.url)}" target="_blank" rel="noopener">${esc(p.url)}</a></p>`;
    const verdicts = el("div", "rv-verdicts");
    REVIEW_VERDICTS.forEach(([event, , text]) => {
      const off = p.viewerIsAuthor && event !== "COMMENT";
      const opt = el("label", `rv-verdict${off ? " off" : ""}`, `<input type="radio" name="rv-verdict" value="${event}"${off ? " disabled" : ""}> ${esc(text)}`);
      if (off) opt.title = ownReason;
      verdicts.appendChild(opt);
    });
    if (summary && summary.verdict) {
      const hint = el("span", "rv-hint", `🤖 Claude suggests: ${esc(verdictLabel(summary.verdict))}`);
      hint.title = "From Claude's review summary in the tray — pick the verdict yourself";
      verdicts.appendChild(hint);
    }
    m.appendChild(verdicts);
    if (p.viewerIsAuthor) m.appendChild(el("p", "rv-own", esc(`Your own pull request: only Comment. ${ownReason}.`)));
    const field = el("div", "field");
    field.appendChild(el("label", "", "Summary"));
    const body = el("textarea");
    body.rows = 6;
    body.value = summary ? summary.comment || "" : "";
    body.placeholder = "The review's summary comment — needed to request changes, and to comment without line comments";
    field.appendChild(body);
    m.appendChild(field);
    m.appendChild(el("ul", "review-confirm", submitReviewLines(p, posting).map(l => `<li>${esc(l)}</li>`).join("")));
    const why = el("p", "rv-why");
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel");
    cancel.onclick = closeModal;
    const go = el("button", "btn primary", "Submit review");
    const picked = () => { const r = m.querySelector('input[name="rv-verdict"]:checked'); return r ? r.value : null; };
    const blocker = () => {
      const event = picked();
      if (!event) return "Pick a verdict";
      if (body.value.trim()) return null;
      if (event === "REQUEST_CHANGES") return "Say what to change in the summary";
      if (event === "COMMENT" && !comments) return "A comment review without line comments needs a summary";
      return null;
    };
    const check = () => {
      const b = blocker();
      go.disabled = !!b;
      why.textContent = b && picked() ? b : "";
      const event = picked();
      go.textContent = event ? `${REVIEW_VERDICTS.find(([e]) => e === event)[2]}${comments ? ` · ${plural(comments, "comment")}` : ""}` : "Submit review";
    };
    verdicts.addEventListener("change", check);
    body.addEventListener("input", check);
    go.onclick = async () => {
      if (blocker()) return;
      const event = picked();
      go.disabled = true;
      const res = await act("review-submit", { slug, args: { repo, number, ids, event, body: body.value } });
      if (!res.ok) { check(); return; } // the toast says why; the form keeps what was typed
      closeModal();
      toast(`submitting your review on ${p.pr}…`);
    };
    bar.append(cancel, go);
    m.append(why, bar);
    check();
    setTimeout(() => { const first = m.querySelector('input[name="rv-verdict"]:not([disabled])'); if (first) first.focus(); }, 0);
  });
}

/* The GitHub group of one PR: its header names the PR, with "Post as
   pending review" (D4) when comments wait, "Submit review…" and a Discard
   for just these drafts. */
function trayReviewGroup(drafts) {
  const d = drafts[0];
  const posted = drafts.filter(x => !isReviewSummary(x));
  const head = el("div", "dt-group gh", `GitHub · ${esc(draftPrLabel(d))} — ${esc(draftMix(drafts))}`);
  head.title = `Drafts for your review on ${d.repo}#${d.number}`;
  const btns = el("span", "dt-group-btns");
  if (posted.length) {
    const post = el("button", "", "Post as pending review");
    post.title = `Add these to your pending review on ${draftPrLabel(d)} — submit it later, here or on GitHub`;
    post.onclick = () => postPendingReview(d.repo, d.number, posted.map(x => x.id));
    btns.appendChild(post);
  }
  btns.appendChild(submitReviewButton(d.repo, d.number, posted.map(x => x.id)));
  const discard = el("button", "", "Discard");
  discard.title = "Throw these review drafts away";
  discard.onclick = () => discardDraftGroup(drafts, `${plural(drafts.length, "review draft")} for ${draftPrLabel(d)}`);
  btns.appendChild(discard);
  head.appendChild(btns);
  return head;
}

/* The PR's review summary atop its group: the suggested verdict (🤖 while
   Claude's) and the body, edited and deleted like any entry — editing
   makes it the user's. */
function summaryTrayEntry(d) {
  const entry = el("div", "dt-entry gh summary");
  entry.dataset.id = d.id;
  const top = el("div", "dt-top");
  const claude = d.author === "claude" ? "🤖 " : "";
  const where = el("span", "dt-where", esc(`${claude}${d.verdict ? `Suggested verdict: ${verdictLabel(d.verdict)}` : "Review summary"}`));
  where.title = `${claude ? "Written by Claude — yours once you edit it. " : ""}Submit review… starts its summary from this; the verdict stays your pick`;
  top.append(where, el("span", "grow"));
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the summary";
  edit.onclick = () => openTrayEdit(d);
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this summary";
  del.onclick = () => deleteDraft(d);
  top.append(edit, del);
  entry.appendChild(top);
  entry.appendChild(trayEdit && trayEdit.id === d.id ? trayEditor(d) : trayComment(d));
  return entry;
}
