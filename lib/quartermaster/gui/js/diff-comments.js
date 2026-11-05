"use strict";

/* ------- diff comments: drafts on lines ------- */
/* A diff comment is a draft in the server store (drafts.js holds the store
   side and the tray). A line is addressed by path + side + number: a removed
   line by its number in the base ("old"), anything else by its number in the
   branch ("new"). */

/* Under a selected run of commits the numbers are that run's, so the
   address carries its label: such a draft shows only on that selection. In
   the PR scope it carries the PR's number too: those numbers are the PR
   head's (or the run's), not the branch's, so PR drafts show only there.
   A line GitHub won't take at the view's anchor commit (gh: false, a
   selected run only) is noGh — never sent, the editor's D8 check. */
function diffLineAddress(path, line) {
  const side = line.t === "-" ? "old" : "new";
  const address = { path, side, line: side === "old" ? line.o : line.n, code: line.s };
  const range = diffView.data && diffView.data.range;
  if (range) address.range = range.label;
  if (diffView.data && diffView.data.branch) address.branch = diffView.data.branch;
  if (diffView.data && diffView.data.checkout === false) address.committed = true;
  const pr = diffPrScope();
  if (pr) address.number = pr.number;
  if (line.gh === false) address.noGh = true;
  return address;
}

/* The address of a rendered diff line, from what its row carries. */
function diffRowAddress(tr) {
  return diffLineAddress(tr.dataset.path, {
    t: tr.dataset.kind === "del" ? "-" : tr.dataset.kind === "add" ? "+" : " ",
    o: tr.dataset.old == null ? null : Number(tr.dataset.old),
    n: tr.dataset.new == null ? null : Number(tr.dataset.new),
    s: tr.dataset.code,
    gh: tr.dataset.gh === "0" ? false : undefined,
  });
}

const diffAddressKey = a => `${a.number ? `#${a.number}/` : ""}${a.range ? a.range + "@" : ""}${a.side}:${a.line}:${a.path}`;
const diffRangeNote = d => d.range ? ` · on ${d.range.includes("..") ? "commits" : "commit"} ${d.range}` : "";

/* "12", "12-15" for a range of lines on one side, "old 12-new 15" across. */
function diffLinesLabel(d) {
  if (d.start_line == null) return String(d.line);
  const startSide = d.start_side || d.side;
  return startSide === d.side ? `${d.start_line}-${d.line}` : `${startSide} ${d.start_line}-${d.side} ${d.line}`;
}

function diffDraftAt(address) {
  const key = diffAddressKey(address);
  return itemDrafts().find(d => isDiffComment(d) && diffAddressKey(d) === key) || null;
}

/* What the diff body shows of the drafts (comments, and annotations, which
   may anchor in it): when another tab, a send, an arrival or an edit in the
   tray moves it, the body is rebuilt (open editors survive). */
const diffDraftsShown = () => itemDrafts().filter(d => !isIssueComment(d)).map(d => `${isDiffComment(d) ? diffAddressKey(d) + d.kind : d.id}\n${d.comment}`).sort().join("\0");

/* Saves the line's draft as a chat draft ("diff-comment") or a GitHub one
   ("github-comment", PR scope only); a PR-scope chat draft keeps its PR so
   the message can name it. Saved empty, it is deleted. */
function putDiffDraft(address, comment, kind = "diff-comment", subject) {
  const slug = chatSlug;
  const key = diffAddressKey(address);
  const { noGh, suggest, ...where } = address;
  const fields = { ...where, ...diffPrFields(), kind };
  if (kind === "github-comment") fields.subject = subject || "line";
  patchLocalDrafts(slug, drafts => {
    const old = drafts.find(d => isDiffComment(d) && diffAddressKey(d) === key);
    const rest = drafts.filter(d => d !== old);
    return comment.trim() ? rest.concat([{ id: `pending:${key}`, ...(old || {}), ...fields, comment }]) : rest;
  });
  return draftAction("draft-put", slug, { ...fields, comment });
}

/* The address an editor saves to: a click on the last line of a saved
   range draft edits that range, not the one line — rebuilt from its rows
   when they are shown, so its suggestion and D8 mark are the range's. */
function diffEditAddress(address, draft) {
  if (address.start_line != null || !draft || draft.start_line == null) return address;
  const row = a => document.querySelector(`#diff-body tr.d-line[data-key="${CSS.escape(diffAddressKey(a))}"]`);
  const start = row({ ...address, side: draft.start_side || draft.side, line: draft.start_line });
  const end = row(address);
  const range = start && end && start.closest("tbody") === end.closest("tbody") ? diffRangeAddress(start, end) : null;
  return range ? range.address : { ...address, start_line: draft.start_line, start_side: draft.start_side, code: draft.code };
}

/* The tag before a saved draft in the PR scope: where it goes, who wrote
   it (🤖 until the user edits it) and the chip that moves it (D5). */
function diffDraftTag(draft) {
  if (!draft.number) return null;
  const github = isGithubDraft(draft);
  const tag = el("div", "d-comment-tag" + (github ? " gh" : ""),
    `${github ? (draft.author === "claude" ? "🤖 " : "") + "review" : "chat"}` +
    `${github && draft.subject === "file" ? " · file comment" : ""}${draft.start_line != null ? ` · lines ${esc(diffLinesLabel(draft))}` : ""}`);
  tag.appendChild(draftMoveChip(draft));
  return tag;
}

/* The row under a line: its saved comment, or the editor while it is open. */
function renderDiffCommentRow(address, editing = false) {
  const draft = diffDraftAt(address);
  const tr = el("tr", "d-comment" + (draft && isGithubDraft(draft) ? " gh" : ""));
  tr.dataset.key = diffAddressKey(address);
  tr.appendChild(el("td", "d-num", ""));
  tr.appendChild(el("td", "d-num", ""));
  const td = el("td", "d-comment-cell");
  if (!editing && draft) {
    const tag = diffDraftTag(draft);
    if (tag) td.appendChild(tag);
    else if (draft.start_line != null) td.appendChild(el("div", "d-comment-tag", `lines ${esc(diffLinesLabel(draft))}`));
    const text = el("div", "d-comment-text", esc(draft.comment));
    text.title = "Edit this comment";
    text.onclick = () => tr.replaceWith(renderDiffCommentRow(address, true));
    td.appendChild(text);
  } else {
    tr.diffAddress = diffEditAddress(address, draft);
    td.appendChild(diffCommentEditor(tr, tr.diffAddress, draft));
  }
  tr.appendChild(td);
  return tr;
}

/* The editor. In the PR scope it saves "Add to review" (⌘⏎, a GitHub
   draft) or "Ask chat" (⌥⏎); elsewhere "Save" (⌘⏎ or ⌥⏎), a chat draft.
   Adding a line GitHub won't take at the view's commit (D8) says so and
   offers Ask chat or a file comment instead. "Suggest change" puts a
   ```suggestion block of the line(s) at the caret (added/context lines). */
function diffCommentEditor(tr, address, draft) {
  const wrap = el("div", "d-comment-edit");
  const pr = diffPrScope();
  const box = el("textarea", "d-comment-input");
  box.rows = 3;
  const lines = address.start_line != null ? `lines ${diffLinesLabel(address)}` : "this line";
  box.placeholder = pr ? `Comment on ${lines} — ⌘⏎ adds to the review, ⌥⏎ asks the chat, Esc cancels`
                       : `Comment on ${lines} — ⌘⏎ saves, Esc cancels`;
  box.value = draft ? draft.comment : "";
  const close = () => closeDiffComment(tr, address);
  // Closed at once; a save the server refuses comes back open with its text.
  const save = (kind, subject) => {
    const text = box.value;
    putDiffDraft(address, text, kind, subject).then(res => {
      if (!res.ok && text.trim()) reopenDiffComment(diffAddressKey(address), text, address);
    });
    close();
  };
  const askChat = () => save("diff-comment");
  // The D8 offer is showing, or the draft is a file comment already: ⌘⏎
  // saves a file comment.
  let refused = !!(draft && isGithubDraft(draft) && draft.subject === "file");
  const addToReview = () => {
    if (!box.value.trim()) { askChat(); return; } // emptied: deleted, like every save
    if (refused) { save("github-comment", "file"); return; }
    if (!address.noGh) { save("github-comment"); return; }
    refused = true;
    showDiffRefusal(acts, pr, askChat, () => save("github-comment", "file"), close);
  };
  box.addEventListener("keydown", e => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); pr ? addToReview() : askChat(); }
    else if (e.key === "Enter" && e.altKey) { e.preventDefault(); askChat(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
  });
  const acts = el("div", "d-comment-acts");
  if (pr) {
    const add = el("button", "primary gh", "Add to review");
    add.title = `A draft for your pending review on ${diffPrLabel(pr)} (⌘⏎)`;
    add.onclick = addToReview;
    const ask = el("button", "", "Ask chat");
    ask.title = "A draft for the chat instead (⌥⏎)";
    ask.onclick = askChat;
    acts.append(add, ask);
  } else {
    const ok = el("button", "primary", "Save");
    ok.onclick = askChat;
    acts.appendChild(ok);
  }
  const suggest = diffSuggestion(address);
  if (suggest != null) {
    const sug = el("button", "", "Suggest change");
    sug.title = "Insert a ```suggestion block with the line(s), to edit into what they should be";
    sug.onclick = () => insertSuggestion(box, suggest);
    acts.appendChild(sug);
  }
  const no = el("button", "", "Cancel");
  no.onclick = close;
  acts.appendChild(no);
  if (draft) {
    const del = el("button", "danger", "Delete");
    del.onclick = () => { putDiffDraft(address, ""); close(); };
    acts.appendChild(del);
  }
  wrap.append(box, acts);
  setTimeout(() => box.focus(), 0);
  return wrap;
}

/* D8: the line isn't in the PR's diff up to the anchor commit, so GitHub
   won't take a comment on it there. */
function showDiffRefusal(acts, pr, askChat, fileComment, cancel) {
  acts.innerHTML = "";
  const sha = String(diffView.data.anchor || "").slice(0, 7);
  acts.appendChild(el("div", "d-comment-refusal",
    `GitHub can't take a comment on this line at ${esc(sha)}: it isn't among the lines ${esc(diffPrLabel(pr))}'s diff shows up to that commit.`));
  const file = el("button", "primary gh", "Save as file comment");
  file.title = "A comment on the whole file that quotes the line (⌘⏎)";
  file.onclick = fileComment;
  const ask = el("button", "", "Ask chat");
  ask.title = "A draft for the chat instead (⌥⏎)";
  ask.onclick = askChat;
  const no = el("button", "", "Cancel");
  no.onclick = cancel;
  acts.append(file, ask, no);
}

/* The text a suggestion starts from: the range's (or line's) added and
   context lines; null when it ends or starts on a removed line, which
   GitHub can't suggest on. */
function diffSuggestion(address) {
  if (address.side !== "new" || (address.start_side && address.start_side !== "new")) return null;
  return address.suggest != null ? address.suggest : address.code;
}

function insertSuggestion(box, text) {
  const at = box.selectionStart;
  const before = box.value.slice(0, at);
  const block = `${before && !before.endsWith("\n") ? "\n" : ""}\`\`\`suggestion\n${text}\n\`\`\`\n`;
  box.value = before + block + box.value.slice(box.selectionEnd);
  const caret = before.length + block.length - "\n```\n".length; // at the end of the lines to edit
  box.focus();
  box.setSelectionRange(caret, caret);
}

/* Back to the saved comment, or no row at all when there is none. */
function closeDiffComment(row, address) {
  document.querySelectorAll("#diff-body tr.d-range-sel").forEach(r => r.classList.remove("d-range-sel"));
  if (diffDraftAt(address)) row.replaceWith(renderDiffCommentRow(address));
  else row.remove();
  diffView.drafts = diffDraftsShown();
  draftsChanged();
}

/* ------- ranges: ⇧-click a second line ------- */
/* A click on a line remembers it; a ⇧-click on another line of the same
   hunk makes the two and everything between one range (D6, every scope):
   the editor goes under the later line — where GitHub shows a range — and
   the rows between are marked. */
let diffRangeFrom = null; // the d-line row clicked last

function diffRangeAddress(a, b) {
  const rows = [...a.closest("tbody").children];
  let [i, j] = [rows.indexOf(a), rows.indexOf(b)];
  if (i > j) [i, j] = [j, i];
  const span = rows.slice(i, j + 1);
  if (span.some(r => r.classList.contains("d-hunk") || r.classList.contains("d-expand"))) return null;
  const lines = span.filter(r => r.classList.contains("d-line"));
  const first = diffRowAddress(lines[0]);
  const last = diffRowAddress(lines[lines.length - 1]);
  const address = { ...last, start_line: first.line, start_side: first.side, code: lines.map(r => r.dataset.code).join("\n") };
  address.suggest = lines.filter(r => r.dataset.kind !== "del").map(r => r.dataset.code).join("\n");
  if (first.noGh || last.noGh) address.noGh = true;
  lines.forEach(r => r.classList.add("d-range-sel"));
  return { address, end: lines[lines.length - 1], start: lines[0] };
}

/* A click on a line opens its comment editor — unless it ended a text
   selection, which is someone copying code. */
$("#diff-body").addEventListener("mousedown", e => {
  if (e.shiftKey && e.target.closest("tr.d-line")) e.preventDefault(); // no text selection on ⇧-click
});
$("#diff-body").addEventListener("click", e => {
  const tr = e.target.closest("tr.d-line");
  if (!tr) return;
  const sel = window.getSelection();
  if (sel && !sel.isCollapsed && tr.contains(sel.anchorNode)) return;
  if (placeDraftOnRow(tr)) return;
  if (e.shiftKey && diffRangeFrom && diffRangeFrom !== tr && diffRangeFrom.isConnected &&
      diffRangeFrom.closest("tbody") === tr.closest("tbody")) {
    openDiffRange(diffRangeFrom, tr);
    return;
  }
  diffRangeFrom = tr;
  const address = diffRowAddress(tr);
  const next = tr.nextElementSibling;
  if (next && next.classList.contains("d-comment") && next.dataset.key === diffAddressKey(address)) {
    const box = next.querySelector("textarea");
    if (box) box.focus(); else next.replaceWith(renderDiffCommentRow(address, true));
    return;
  }
  tr.after(renderDiffCommentRow(address, true));
});

function openDiffRange(from, to) {
  document.querySelectorAll("#diff-body tr.d-range-sel").forEach(r => r.classList.remove("d-range-sel"));
  const range = diffRangeAddress(from, to);
  if (!range) { toast("A range of lines stays inside one hunk", false); return; }
  // The first click's editor, still empty, makes way for the range's.
  [range.start, range.end, from].forEach(row => {
    const next = row.nextElementSibling;
    const box = next && next.classList.contains("d-comment") && next.querySelector("textarea");
    if (box && !box.value.trim() && !diffDraftAt(next.diffAddress || diffRowAddress(row))) next.remove();
  });
  // The end line's own row gives way to the range's editor, keeping
  // anything typed in it.
  const next = range.end.nextElementSibling;
  const typed = next && next.classList.contains("d-comment") && next.querySelector("textarea");
  if (next && next.classList.contains("d-comment")) next.remove();
  const editor = renderDiffCommentRow(range.address, true);
  if (typed && typed.value.trim()) editor.querySelector("textarea").value = typed.value;
  range.end.after(editor);
  diffRangeFrom = null;
}

/* Saved range drafts mark their lines, in a file just built. */
function markDiffDraftRanges(tbody, path) {
  itemDrafts().filter(d => isDiffComment(d) && d.path === path && d.start_line != null).forEach(d => {
    const row = key => tbody.querySelector(`tr.d-line[data-key="${CSS.escape(key)}"]`);
    const end = row(diffAddressKey(d));
    const start = row(diffAddressKey({ ...d, side: d.start_side || d.side, line: d.start_line }));
    if (!end || !start) return;
    for (let r = start; r; r = r.nextElementSibling) {
      if (r.classList.contains("d-line")) r.classList.add("d-in-range");
      if (r === end) break;
    }
  });
}

/* A refetch (the turn ended, ↻) rebuilds the diff: an editor that was open
   comes back with what was typed in it (its range too), when its line is
   still shown. */
function reopenDiffComment(key, value, address) {
  const line = document.querySelector(`#diff-body tr.d-line[data-key="${CSS.escape(key)}"]`);
  if (!line) return;
  const next = line.nextElementSibling;
  if (next && next.classList.contains("d-comment")) next.remove();
  const editor = renderDiffCommentRow(address || diffRowAddress(line), true);
  editor.querySelector("textarea").value = value;
  line.after(editor);
}

function revealDiffComment(d, follow = true) {
  const pr = diffPrScope();
  const viewing = diffView.data && diffView.data.range ? diffView.data.range.label : undefined;
  const elsewhere = String(d.number || "") !== String(pr ? pr.number : "") || (d.range || undefined) !== viewing
    || !!diffDraftBranch(d);
  if (elsewhere && follow) { showDraftView(d); return; }
  if (elsewhere) {
    toast(d.number && (!pr || String(d.number) !== String(pr.number)) ? `That comment is on pull request #${d.number}, which this branch's diff can't show`
      : d.range ? `That comment is on ${d.range.includes("..") ? "commits" : "commit"} ${d.range}, which is no longer on this branch`
      : "Couldn't show the diff that comment was written on", false);
    return;
  }
  const row = document.querySelector(`#diff-body tr.d-comment[data-key="${CSS.escape(diffAddressKey(d))}"]`);
  if (row) { showDiffRow(row); row.scrollIntoView({ block: "center" }); return; }
  const file = [...document.querySelectorAll("#diff-body details.diff-file")].find(f => f.dataset.path === d.path);
  if (!file) { toast(`${d.path} is not in this diff any more`, false); return; }
  file.open = true;
  if (file.fillRows) file.fillRows();
  const shown = document.querySelector(`#diff-body tr.d-comment[data-key="${CSS.escape(diffAddressKey(d))}"]`);
  if (shown) showDiffRow(shown);
  (shown || file).scrollIntoView({ block: shown ? "center" : "start" });
}

/* A comment written on another view (another of the item's branches, the
   PR scope, a selected run of commits, or neither) is shown by switching
   the pane to that view: its branch, scope and commits as the draft's
   address names them. */
async function showDraftView(d) {
  const choice = diffChoice[chatSlug] || {};
  const other = diffDraftBranch(d);
  if (other) pickBranch(chatSlug, other.branch);
  const current = choice.scope || (diffView.data && diffView.data.scope) || "branch";
  let scope = d.number ? "pr" : d.range ? "commits" : current === "pr" || current === "commits" ? "branch" : current;
  if (other && other.checkout === false && diffNeedsCheckout(scope)) scope = "branch";
  const [from, to = from] = d.range ? d.range.split("..").map(diffCommitSha) : [];
  diffChoice[chatSlug] = from ? { scope, from, to, anchor: from, rebase: choice.rebase }
                              : { scope, rebase: choice.rebase };
  if (other) renderChatSide();
  await loadDiff();
  revealDiffComment(d, false);
}

/* The picker entry of the branch a draft was written on, when that is
   another branch the pane can show; null for the shown one, a draft that
   names none (older than the field) and a branch no longer offered, which
   show where they are. */
function diffDraftBranch(d) {
  const data = diffView.data;
  if (!d.branch || !data || d.branch === data.branch) return null;
  return data.branches.find(b => b.branch === d.branch) || null;
}
