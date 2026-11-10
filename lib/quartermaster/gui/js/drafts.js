"use strict";

/* ------- drafts: diff comments, page annotations and issue comments, sent to the chat as one message ------- */
/* The item's drafts live on the server (Drafts, drafts/<slug>.json) and come
   with every state as items[].drafts, so every tab sees the same ones and a
   restart keeps them. Three kinds: a diff comment on a line (written in the
   diff body, diff-comments.js), a page annotation (relayed from a dev server's page overlay) and an
   issue comment on a block of an issue draft (written in the Issues pane,
   issues.js). This file is the tray under whichever of the two panes is
   open, the chat header's chip, the arrival toast and the one-time import of
   browser-kept comments. Changes show at once (patchLocalDrafts) and the
   action's state refresh confirms them. */
let trayOpen = false;     // the tray's list: collapsed to its summary line until opened
let trayEdit = null;      // { id, value, focus } while a tray entry's editor is open
const draftDetailsOpen = new Set(); // annotation ids whose element details are folded open
const PAGE_ICON = '<svg class="pg-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true">' +
  '<rect x="1.5" y="2.5" width="13" height="11" rx="1.6"/><path d="M1.5 5.6h13"/>' +
  '<circle cx="3.6" cy="4.05" r=".45" fill="currentColor"/><circle cx="5.2" cy="4.05" r=".45" fill="currentColor"/></svg>';

/* A diff line's draft is for the chat ("diff-comment") or, made in the PR
   scope, for the pending review on GitHub ("github-comment"). */
const isDiffComment = d => d.kind === "diff-comment" || d.kind === "github-comment";
const isGithubDraft = d => d.kind === "github-comment";
/* A PR's GitHub group: its review summary, then what posts with the
   pending review — GitHub comments and thread replies. */
const isReviewDraft = d => isGithubDraft(d) || isThreadReply(d) || isReviewSummary(d);
const reviewRank = d => (isReviewSummary(d) ? 0 : isThreadReply(d) ? 2 : 1);
const isChatDraft = d => !isReviewDraft(d);
const isAnnotation = d => d.kind === "annotation";
const isIssueComment = d => d.kind === "issue-comment";
const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
const byText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const byLine = (a, b) => byText(a.path, b.path) || Number(a.line) - Number(b.line);
const draftPrLabel = d => `${String(d.repo || "").split("/").pop()}#${d.number}`;

function itemDrafts(slug = chatSlug) {
  const it = items.find(i => i.slug === slug);
  return it && Array.isArray(it.drafts) ? it.drafts : [];
}

/* The tray's order: the review drafts per PR — its summary, comments by
   path:line, then thread replies — then the chat's in the message's order: diff
   comments by path:line, then annotations as they arrived, then issue
   comments by issue file. */
function trayOrder(drafts) {
  const github = drafts.filter(isReviewDraft).sort((a, b) => byText(draftPrLabel(a), draftPrLabel(b)) ||
    reviewRank(a) - reviewRank(b) || byLine(a, b));
  const comments = drafts.filter(d => isDiffComment(d) && !isGithubDraft(d)).sort(byLine);
  const issueComments = drafts.filter(isIssueComment).sort((a, b) => byText(a.file, b.file));
  return github.concat(comments, drafts.filter(isAnnotation), issueComments);
}

/* What Send pastes into the chat: neither GitHub drafts nor thread replies,
   which go to GitHub with the pending review. */
const chatDrafts = drafts => drafts.filter(isChatDraft);

/* "1 review comment · 2 comments · 1 annotation · 1 issue comment · 1 thread reply" */
function draftMix(drafts) {
  const reviews = drafts.filter(isGithubDraft).length;
  const comments = drafts.filter(d => isDiffComment(d) && !isGithubDraft(d)).length;
  const annotations = drafts.filter(isAnnotation).length;
  const issueComments = drafts.filter(isIssueComment).length;
  const replies = drafts.filter(isThreadReply).length;
  const summaries = drafts.filter(isReviewSummary).length;
  return [summaries && `${summaries} review summar${summaries === 1 ? "y" : "ies"}`,
    reviews && plural(reviews, "review comment"), comments && plural(comments, "comment"),
    annotations && plural(annotations, "annotation"),
    issueComments && plural(issueComments, "issue comment"),
    replies && `${replies} thread repl${replies === 1 ? "y" : "ies"}`].filter(Boolean).join(" · ");
}

function patchLocalDrafts(slug, change) {
  const it = items.find(i => i.slug === slug);
  if (it) it.drafts = change(Array.isArray(it.drafts) ? it.drafts : []);
}

/* After a change: the tray and, when what they show moved, the diff body
   and the Issues pane. The chip follows with the chat render the action's
   refresh brings. */
function draftsChanged() {
  if (diffOpen && diffView.data && diffView.slug === chatSlug && diffView.drafts !== diffDraftsShown()) renderDiffPane();
  else renderDiffTray();
  if (issuesShown() && issuesView.data && issuesView.slug === chatSlug && issuesView.drafts !== issueDraftsShown()) renderIssuesPane();
}

/* A failed action toasts (act) and the server's drafts come back. */
async function draftAction(cmd, slug, args) {
  const res = await act(cmd, { slug, args });
  if (!res.ok) { await refresh(); draftsChanged(); }
  return res;
}

function editDraft(d, comment) {
  const slug = chatSlug;
  if (trayEdit && trayEdit.id === d.id) trayEdit = null;
  if (!comment.trim()) return deleteDraft(d);
  patchLocalDrafts(slug, drafts => drafts.map(x => x.id === d.id ? { ...x, comment } : x));
  draftsChanged();
  return draftAction("draft-edit", slug, { id: d.id, comment });
}

/* The chip on a PR-scope draft (D5): to the review or to the chat. The
   server refuses the review for a line GitHub won't take at its commit. */
function moveDraft(d, to) {
  const slug = chatSlug;
  // A diff row saved a moment ago may still hold its local stand-in
  // (pending:<key>); the stored draft on that line is the one to move.
  if (String(d.id).startsWith("pending:")) d = itemDrafts(slug).find(x => isDiffComment(x) && diffAddressKey(x) === diffAddressKey(d)) || d;
  const kind = to === "github" ? "github-comment" : "diff-comment";
  patchLocalDrafts(slug, drafts => drafts.map(x => x.id === d.id ? { ...x, kind } : x));
  draftsChanged();
  return draftAction("draft-move", slug, { id: d.id, to });
}

function draftMoveChip(d) {
  const github = isGithubDraft(d);
  const chip = el("button", "dt-move" + (github ? "" : " gh"), github ? "→ chat" : "→ review");
  chip.title = github ? "Ask the chat about it instead of posting it to GitHub"
                      : `Add it to your pending review on ${draftPrLabel(d)} instead`;
  chip.onclick = e => { e.stopPropagation(); moveDraft(d, github ? "chat" : "github"); };
  return chip;
}

function deleteDraft(d) {
  const slug = chatSlug;
  if (trayEdit && trayEdit.id === d.id) trayEdit = null;
  patchLocalDrafts(slug, drafts => drafts.filter(x => x.id !== d.id));
  draftsChanged();
  return draftAction("draft-delete", slug, { id: d.id });
}

/* Why Send can't go now, or null. The server refuses mid-turn text anyway;
   the button just says so up front. */
function diffSendBlocker() {
  if (!panes.includes(chatSlug)) return "Open the chat in qm first — drafts are pasted into its terminal";
  const a = attention.find(x => x.slug === chatSlug);
  if (a && a.state === "working") return "The chat is working — send once it is your turn";
  if (a && a.state === "blocked") return "The chat is waiting on a permission prompt — answer it first";
  return null;
}

/* The tray under the diff, or under the Issues pane while that holds the
   slot (the one element moves between them): every draft waiting to go,
   collapsed to its summary line, with Send and Discard. Re-rendered on every
   chat render, so Send follows the chat's turn; an entry's open editor keeps
   its text and focus across that. */
function renderDiffTray() {
  const tray = $("#diff-tray");
  const inIssues = issuesShown();
  const host = $(inIssues ? "#issues-pane" : "#diff-pane");
  if (tray.parentElement !== host) host.appendChild(tray);
  const drafts = (diffOpen || inIssues) && chatSlug ? trayOrder(itemDrafts()) : [];
  const typing = document.activeElement && document.activeElement.closest && document.activeElement.closest("#diff-tray textarea");
  const caret = typing ? [typing.selectionStart, typing.selectionEnd] : null;
  if (trayEdit && !drafts.some(d => d.id === trayEdit.id)) trayEdit = null;
  tray.hidden = !drafts.length;
  keepScroll(tray, () => {
    tray.innerHTML = "";
    if (!drafts.length) return;
    const list = el("details", "dt-list");
    list.open = trayOpen;
    list.addEventListener("toggle", () => { trayOpen = list.open; });
    list.appendChild(el("summary", "", `${drafts.length} to send · ${esc(draftMix(drafts))}`));
    const anchors = diffAnchors();
    const chat = drafts.filter(isChatDraft);
    drafts.forEach((d, n) => {
      const prev = n ? drafts[n - 1] : null;
      if (isReviewDraft(d) && !(prev && isReviewDraft(prev) && draftPrLabel(prev) === draftPrLabel(d))) {
        list.appendChild(trayReviewGroup(drafts.filter(x => isReviewDraft(x) && draftPrLabel(x) === draftPrLabel(d))));
      }
      if (isChatDraft(d) && prev && isReviewDraft(prev)) list.appendChild(el("div", "dt-group", "For the chat"));
      if (isIssueComment(d) && !(prev && isIssueComment(prev))) list.appendChild(el("div", "dt-group", "On the issue drafts"));
      list.appendChild(isIssueComment(d) ? issueTrayEntry(d) : isThreadReply(d) ? replyTrayEntry(d)
        : isReviewSummary(d) ? summaryTrayEntry(d) : trayEntry(d, anchors.get(d.id)));
    });
    tray.appendChild(list);
    if (chat.length) {
      const blocker = diffSendBlocker();
      const btns = el("div", "diff-tray-btns");
      const send = el("button", "primary", "Send to chat");
      send.disabled = !!blocker;
      send.title = blocker || `Paste the ${plural(chat.length, "chat draft")} into the chat as one message`;
      send.onclick = sendDrafts;
      const discard = el("button", "", "Discard");
      discard.title = "Throw the chat drafts away";
      discard.onclick = discardDrafts;
      btns.append(send, discard);
      tray.appendChild(btns);
    }
  });
  const box = tray.querySelector("textarea");
  if (box && (caret || trayEdit.focus)) {
    box.focus();
    if (caret) box.setSelectionRange(caret[0], caret[1]);
    trayEdit.focus = false;
  }
}

/* One tray entry: where it points, its comment (✎ or a click edits it), ✕
   deletes it; an annotation also has its page and its element's details.
   An annotation anchored in the diff is shown there, so here it is one
   line that jumps to its row (or its file's header) — unless its editor is
   open. */
function trayEntry(d, anchor) {
  const annotation = isAnnotation(d);
  if (annotation && anchor && !(trayEdit && trayEdit.id === d.id)) return anchoredTrayEntry(d, anchor);
  const entry = el("div", `dt-entry ${annotation ? "annot" : "comment"}`);
  if (isGithubDraft(d)) entry.classList.add("gh");
  entry.dataset.id = d.id;
  const top = el("div", "dt-top");
  if (annotation) {
    top.insertAdjacentHTML("beforeend", PAGE_ICON + annotationWhere(d));
    const page = d.page || d.url || "";
    top.appendChild(el("span", "dt-page", esc(pagePath(page)))).title = page;
  } else {
    const github = isGithubDraft(d);
    const where = el("span", "dt-where", `${github && d.author === "claude" ? "🤖 " : ""}${esc(d.path)}:${esc(diffLinesLabel(d))}` +
      `${d.side === "old" ? " (removed)" : ""}${github && d.subject === "file" ? " · file comment" : ""}` +
      `${!github && d.number ? ` on ${esc(draftPrLabel(d))} @${esc(String(d.commit || "").slice(0, 7))}` : ""}${esc(diffRangeNote(d))}`);
    where.title = github && d.author === "claude" ? "Written by Claude — yours once you edit it. Show this line in the diff"
                                                  : "Show this line in the diff";
    where.onclick = () => (github && outdatedInDiff(d) ? revealOutdatedCard(d) : revealDiffComment(d));
    top.appendChild(where);
    if (github && isOutdatedDraft(d)) top.appendChild(el("span", "dt-tag outdated", "outdated")).title = reviewRoute(d).reason || "";
    if (github && d.failed) top.appendChild(el("span", "dt-tag failed", "not posted")).title = d.failed;
    top.appendChild(el("span", "grow"));
    if (d.number) top.appendChild(draftMoveChip(d));
  }
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the comment";
  edit.onclick = () => openTrayEdit(d);
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this draft";
  del.onclick = () => deleteDraft(d);
  top.append(edit, del);
  entry.appendChild(top);
  entry.appendChild(trayEdit && trayEdit.id === d.id ? trayEditor(d) : trayComment(d));
  if (annotation) entry.appendChild(annotationDetails(d));
  if (isGithubDraft(d) && d.failed) entry.appendChild(el("div", "dt-failed", `GitHub didn't take it: ${esc(d.failed)}`));
  // An outdated draft whose card has no file to sit in: its actions here (D10).
  if (isGithubDraft(d) && isOutdatedDraft(d) && !outdatedInDiff(d)) entry.appendChild(outdatedCard(d, reviewRoute(d), true));
  return entry;
}

function anchoredTrayEntry(d, anchor) {
  const entry = el("div", "dt-entry annot anchored");
  entry.dataset.id = d.id;
  const top = el("div", "dt-top");
  const where = `${esc(shortFile(anchor.path))}${anchor.at === "line" ? `:${esc(anchor.line)}` : ""}`;
  const link = el("span", "dt-jump", `${PAGE_ICON}<span class="dt-where annot">${where}</span><span class="dt-line">${esc(d.comment)}</span>`);
  link.title = anchor.at === "line" ? `Show it under ${anchor.path}:${anchor.line} in the diff`
                                    : `Show ${anchor.path} in the diff — its element is in that file, but no line shown here is known to be its source`;
  link.onclick = () => revealDiffAnnotation(d);
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the comment";
  edit.onclick = () => openTrayEdit(d);
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this draft";
  del.onclick = () => deleteDraft(d);
  top.append(link, edit, del);
  entry.appendChild(top);
  return entry;
}

/* From a file header's badge: the tray open at that entry, flashed. */
function revealTrayEntry(id) {
  trayOpen = true;
  renderDiffTray();
  const entry = document.querySelector(`#diff-tray .dt-entry[data-id="${CSS.escape(id)}"]`);
  if (entry) flashDiffTarget(entry, "nearest");
}

/* A thread reply: its PR and line (a click shows the thread), then the
   reply like any other entry. */
function replyTrayEntry(d) {
  const entry = el("div", "dt-entry reply");
  entry.dataset.id = d.id;
  const top = el("div", "dt-top");
  const where = el("span", "dt-jump", `<span class="dt-where">${esc(`${String(d.repo || "").split("/").pop()}#${d.number}`)}</span>` +
    `<span class="dt-line">${esc(`${d.path || ""}${d.line != null ? `:${d.line}` : ""}`)}</span>`);
  where.title = "Show the thread in the diff's PR scope";
  where.onclick = () => revealPrThread(d);
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the reply";
  edit.onclick = () => openTrayEdit(d);
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this draft";
  del.onclick = () => deleteDraft(d);
  top.append(where, edit, del);
  entry.appendChild(top);
  entry.appendChild(trayEdit && trayEdit.id === d.id ? trayEditor(d) : trayComment(d));
  return entry;
}

/* An issue comment: its issue's title and block (a click shows it in the
   Issues pane), then the comment like any other entry. */
function issueTrayEntry(d) {
  const entry = el("div", "dt-entry issue");
  entry.dataset.id = d.id;
  const top = el("div", "dt-top");
  const where = el("span", "dt-jump", `<span class="dt-where">${esc(d.title || d.file)}</span>` +
    `<span class="dt-line">${d.block ? esc(issueBlockSnippet(d.block)) : "the whole issue"}</span>`);
  where.title = `Show it in the Issues pane — ${d.file}`;
  where.onclick = () => revealIssueComment(d);
  const edit = el("button", "dt-x", "✎");
  edit.title = "Edit the comment";
  edit.onclick = () => openTrayEdit(d);
  const del = el("button", "dt-x del", "✕");
  del.title = "Delete this draft";
  del.onclick = () => deleteDraft(d);
  top.append(where, edit, del);
  entry.appendChild(top);
  entry.appendChild(trayEdit && trayEdit.id === d.id ? trayEditor(d) : trayComment(d));
  return entry;
}

function openTrayEdit(d) {
  trayEdit = { id: d.id, value: d.comment, focus: true };
  renderDiffTray();
}

function trayComment(d) {
  const text = el("div", "dt-comment", esc(d.comment));
  text.title = "Edit the comment";
  text.onclick = () => openTrayEdit(d);
  return text;
}

function trayEditor(d) {
  const box = el("div", "dt-edit");
  const input = el("textarea");
  input.rows = 3;
  input.value = trayEdit.value;
  input.placeholder = "⌘⏎ saves, Esc cancels — saving it empty deletes the draft";
  input.addEventListener("input", () => { if (trayEdit) trayEdit.value = input.value; });
  const save = () => editDraft(d, input.value);
  const cancel = () => { trayEdit = null; renderDiffTray(); };
  input.addEventListener("keydown", e => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancel(); }
  });
  const acts = el("div", "d-comment-acts");
  const ok = el("button", "primary", "Save");
  ok.onclick = save;
  const no = el("button", "", "Cancel");
  no.onclick = cancel;
  acts.append(ok, no);
  box.append(input, acts);
  return box;
}

const pagePath = url => { try { const u = new URL(url); return u.pathname + u.search; } catch (e) { return String(url || ""); } };
const shortFile = path => String(path || "").split("/").pop();
const ownerLabel = o => `${o.name || "?"}${o.as ? ` (as ${o.as})` : ""} · ${o.via === "definition" ? "defined in" : "JSX in"} ${o.file || "?"}${o.line ? `:${o.line}` : ""}`;

/* An annotation's innermost owner, as file:line; the element otherwise. */
function annotationWhere(d) {
  const o = (Array.isArray(d.owners) ? d.owners : []).find(x => x && x.file);
  if (o) return `<span class="dt-where annot" title="${esc(ownerLabel(o))}">${esc(shortFile(o.file))}${o.line ? `:${esc(o.line)}` : ""}</span>`;
  return `<span class="dt-where annot">${esc(d.component || d.selector || "element")}</span>`;
}

/* What the overlay captured about the element, read-only, folded by default. */
function annotationDetails(d) {
  const det = el("details", "dt-details");
  det.open = draftDetailsOpen.has(d.id);
  det.addEventListener("toggle", () => { if (det.open) draftDetailsOpen.add(d.id); else draftDetailsOpen.delete(d.id); });
  const rows = [["page", d.page || d.url], ["title", d.title], ["selector", d.selector], ["text", d.text],
    ["component", Array.isArray(d.components) && d.components.length ? d.components.join(" › ") : d.component]];
  const owners = (Array.isArray(d.owners) ? d.owners : []).filter(Boolean);
  det.innerHTML = "<summary>element</summary><dl>" +
    rows.filter(([, v]) => v != null && String(v).trim()).map(([k, v]) => `<dt>${k}</dt><dd>${esc(v)}</dd>`).join("") +
    (owners.length ? `<dt>rendered by</dt><dd>${owners.map(o => `<div class="owner">${esc(ownerLabel(o))}</div>`).join("")}</dd>` : "") +
    "</dl>";
  return det;
}

/* A PR's GitHub group header is trayReviewGroup (review-submit.js). */
async function discardDraftGroup(drafts, what) {
  const slug = chatSlug;
  if (!drafts.length || !confirm(`Discard ${what}?`)) return;
  trayEdit = null;
  const res = await act("drafts-discard", { slug, args: { ids: drafts.map(x => x.id) } });
  if (res.ok && chatSlug === slug) draftsChanged();
}

/* One message for every chat draft the tray shows; the server removes only
   those it sent, so one that arrives or changes meanwhile stays. GitHub
   drafts never go to the chat. */
async function sendDrafts() {
  const slug = chatSlug;
  const drafts = chatDrafts(itemDrafts(slug));
  if (!drafts.length || diffSendBlocker()) return;
  const d = diffView.slug === slug ? diffView.data : null;
  const args = { ids: drafts.map(x => x.id) };
  if (d) {
    args.branch = d.branch;
    args.base = d.scope === "uncommitted" ? "HEAD" : d.base && d.base.ref;
  }
  const res = await act("drafts-send", { slug, args });
  if (!res.ok) return;
  toast(`${plural(res.sent, "draft")} sent to the chat as one message`);
  if (chatSlug === slug) draftsChanged();
}

async function discardDrafts() {
  const slug = chatSlug;
  const drafts = itemDrafts(slug).filter(isChatDraft);
  if (!drafts.length || !confirm(`Discard ${plural(drafts.length, "draft")}?`)) return;
  trayEdit = null;
  const res = await act("drafts-discard", { slug, args: { ids: drafts.map(x => x.id) } });
  if (res.ok && chatSlug === slug) draftsChanged();
}

/* The chat header's "N drafts" chip beside Diff: opens the tray expanded,
   under the pane that is open — the Issues pane when only issue comments
   wait, the diff otherwise. Violet when annotations wait, the accent for
   comments only. */
function draftsChip(it) {
  const drafts = Array.isArray(it.drafts) ? it.drafts : [];
  const chip = action("drafts", `drafts-chip${drafts.some(isAnnotation) ? "" : " comments-only"}`, plural(drafts.length, "draft"), "");
  chip.title = `${draftMix(drafts)} waiting in the drafts tray`;
  chip.tabIndex = -1;
  return chip;
}

function openDraftsTray() {
  trayOpen = true;
  const issuesOnly = itemDrafts().every(isIssueComment) && itemIssues(items.find(i => i.slug === chatSlug));
  if (diffOpen || issuesShown()) renderDiffTray();
  else if (issuesOnly) setIssuesOpen(true);
  else toggleDiff();
  const tray = $("#diff-tray");
  if (!tray.hidden) tray.scrollIntoView({ block: "nearest" });
}

/* ------- 📋 load: annotations a page overlay copied ------- */
/* Beside Diff, always: the clipboard is how annotations cross the read-only
   tunnel. The server parses the text and fills the owners' code; the page
   only reads the clipboard (127.0.0.1 is a secure context) and toasts. The
   ids it added count as seen, so no "arrived" toast doubles the "loaded" one,
   and the diff stays as it is — the chip appears with the refresh. */
function clipboardLoadButton() {
  const b = action("drafts-load", "load-btn", "📋 load", "");
  b.title = "Load the page annotations a dev server's page overlay copied to the clipboard into this item's drafts";
  return b;
}

async function loadClipboardAnnotations(slug) {
  let text;
  try { text = await navigator.clipboard.readText(); } catch (e) {
    toast(`couldn't read the clipboard: ${(e && e.message) || e}`, false);
    return;
  }
  const res = await postQuietly("drafts-load", slug, { text });
  if (!res.ok) { toast(res.error || "loading the annotations failed", false); return; }
  if (draftsSeen.ids) (res.ids || []).forEach(id => (draftsSeen.ids[slug] = draftsSeen.ids[slug] || new Set()).add(id));
  draftsSeen.counts[slug] = (draftsSeen.counts[slug] || 0) + (res.loaded || 0);
  toast(`${plural(res.loaded || 0, "annotation")} loaded`);
  await refresh();
  draftsChanged();
}

/* ------- drafts arriving: a toast, never a view switch ------- */
/* From a state, new annotation ids (a page writes those only by 📋 load,
   which marks its own as seen); off the chat view /api/attention brings only counts, and a
   rise there is news. A slug toasted from counts is re-baselined, not
   toasted again, by the next state. */
const draftsSeen = { ids: null, counts: {} }; // ids: slug → Set of annotation ids, null before the first state

function noticeDraftsInState(list) {
  const first = draftsSeen.ids === null;
  const ids = draftsSeen.ids || {};
  (list || []).forEach(it => {
    const drafts = Array.isArray(it.drafts) ? it.drafts : [];
    const now = drafts.filter(isAnnotation).map(d => d.id);
    const before = ids[it.slug];
    const fresh = !first && before ? now.filter(id => !before.has(id)).length : 0;
    ids[it.slug] = new Set(now);
    draftsSeen.counts[it.slug] = drafts.length;
    if (fresh) toastDraftsArrived(it.slug, plural(fresh, "annotation"));
  });
  draftsSeen.ids = ids;
}

function noticeDraftCounts(counts) {
  if (!counts || draftsSeen.ids === null) return;
  const known = draftsSeen.counts;
  Object.keys(known).forEach(slug => { if (!(slug in counts)) known[slug] = 0; });
  Object.entries(counts).forEach(([slug, n]) => {
    if (n > (known[slug] || 0)) {
      toastDraftsArrived(slug, plural(n - (known[slug] || 0), "draft"));
      delete draftsSeen.ids[slug];
    }
    known[slug] = n;
  });
}

function toastDraftsArrived(slug, what) {
  const here = mode === "chat" && chatSlug === slug;
  toast(`${what} arrived for ${slug}${here ? (diffOpen || issuesShown() ? " — in the drafts tray" : " — the drafts chip opens them") : ""}`);
}

/* ------- once: diff comments this browser kept before the store ------- */
/* They lived in localStorage (qm-diff-comments:<slug>). Each is put into the
   store (keyed by its line, so a second tab importing too changes nothing),
   and a key goes once all of its comments made it. A key of an item this
   state doesn't know stays. */
const LEGACY_DRAFTS_PREFIX = "qm-diff-comments:";

async function importLegacyDiffDrafts() {
  let keys = [];
  try { keys = Object.keys(localStorage).filter(k => k.startsWith(LEGACY_DRAFTS_PREFIX)); } catch (e) { return; }
  let moved = 0;
  for (const key of keys) {
    const slug = key.slice(LEGACY_DRAFTS_PREFIX.length);
    if (!items.some(i => i.slug === slug)) continue;
    let drafts = [];
    try { drafts = JSON.parse(localStorage.getItem(key) || "[]"); } catch (e) { /* unreadable: nothing to move */ }
    let failed = false;
    for (const d of Array.isArray(drafts) ? drafts : []) {
      if (!d || !d.path || !String(d.comment || "").trim()) continue;
      const args = { path: d.path, side: d.side, line: d.line, code: d.code, range: d.range, comment: d.comment };
      if ((await postQuietly("draft-put", slug, args)).ok) moved++; else failed = true;
    }
    if (!failed) try { localStorage.removeItem(key); } catch (e) { /* tried again next load */ }
  }
  if (!moved) return;
  await refresh();
  toast(`${plural(moved, "diff comment draft")} moved from this browser into qm`);
}

/* An action without act()'s refresh and toasts: the import posts many. */
async function postQuietly(cmd, slug, args) {
  try {
    const r = await fetch("/api/action", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cmd, slug, args }),
    });
    return (await r.json()) || { ok: false };
  } catch (e) { return { ok: false }; }
}
