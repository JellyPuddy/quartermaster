"use strict";

/* ------- Issues view: every item's issue drafts (GET /api/issues) ------- */
/* Read-only: a row opens its item's chat with the Issues pane on that issue,
   where creating, deleting and commenting happen. Fetched when the view
   opens and when the pulse says an issue file changed. The tab's badge
   counts the drafts not yet on GitHub, from the state's items[].issues. */
let issueIndex = { items: null, error: null };
let issueListFocus = null; // "<slug>/<file>" of the focused row

/* Every row in display order: per item its issues as the server orders them
   (to create first, then created, filename order in each), then its broken files. */
function issueListRows() {
  return (issueIndex.items || []).flatMap(g =>
    g.issues.map(issue => ({ group: g, file: issue.file, issue }))
      .concat(g.errors.map(error => ({ group: g, file: error.file, error }))));
}
const issueRowKey = row => `${row.group.slug}/${row.file}`;

async function loadIssueIndex() {
  let res;
  try { res = await (await fetch("/api/issues")).json(); }
  catch (e) { res = { ok: false, error: "could not reach qm" }; }
  if (res.ok) issueIndex = { items: res.items, error: null };
  else issueIndex = { items: issueIndex.items, error: res.error || "reading the issue drafts failed" };
  renderIssueList();
}

function renderIssuesBadge() {
  const open = items.reduce((n, it) => n + ((it.issues && it.issues.open) || 0), 0);
  const badge = $("#issues-badge");
  badge.innerHTML = open ? `<span class="col-count">${open}</span>` : "";
  badge.parentElement.title = `Issue drafts across all items (⇧I)${open ? `\n${plural(open, "draft")} not yet created on GitHub` : ""}`;
}

function renderIssueList() {
  if (mode !== "issues") return;
  const body = $("#issue-list-body");
  keepScroll(body.closest(".il-wrap"), () => {
    body.innerHTML = "";
    const rows = issueListRows();
    $("#issue-list-count").textContent = rows.length;
    $("#issue-list-error").textContent = issueIndex.error || "";
    if (!issueIndex.items) { body.appendChild(el("div", "col-empty", issueIndex.error ? "" : "loading…")); return; }
    if (!rows.length) { body.appendChild(el("div", "col-empty", "no issue drafts")); return; }
    if (!rows.some(r => issueRowKey(r) === issueListFocus)) issueListFocus = issueRowKey(rows[0]);
    issueIndex.items.forEach(g => {
      const group = el("section", "il-group");
      group.appendChild(issueGroupHead(g));
      rows.filter(r => r.group === g).forEach(r => group.appendChild(issueListRow(r)));
      body.appendChild(group);
    });
  });
}

function issueGroupHead(g) {
  const head = el("div", "il-head");
  const state = el("span", "il-state");
  state.append(el("span", "col-dot dot-" + g.state), el("span", "", esc(stateLabel(g.state))));
  head.appendChild(state);
  const title = el("span", "il-title", esc(g.title));
  title.title = g.title;
  head.append(title, el("span", "slug", esc(g.slug)));
  const open = g.issues.filter(i => !i.created).length;
  const counts = [open && `${open} to create`, g.issues.length - open && `${g.issues.length - open} created`,
                  g.errors.length && `${g.errors.length} unreadable`].filter(Boolean).join(" · ");
  head.appendChild(el("span", "il-counts", esc(counts)));
  return head;
}

function issueListRow(r) {
  const row = el("div", "il-row" + (r.issue && r.issue.created ? " created" : "") + (r.error ? " broken" : ""));
  const key = issueRowKey(r);
  if (key === issueListFocus) row.classList.add("focused");
  row.tabIndex = 0;
  row.dataset.key = key;
  const n = (r.file.match(/^\d+/) || [""])[0];
  row.appendChild(el("span", "il-n", esc(n)));
  if (r.error) {
    row.appendChild(el("span", "il-name", `⚠ ${esc(r.file)}`));
    row.appendChild(el("span", "il-error", esc(r.error.error)));
    row.title = "Doesn't parse — open the item's Issues pane";
    return row;
  }
  const title = el("span", "il-name", esc(r.issue.title));
  title.title = `${r.issue.title}\n${r.file}`;
  row.append(title, kindPill(r.issue.kind));
  if (r.issue.created) {
    row.appendChild(issueNumberLink(r.issue.number, r.group.repo));
    if (r.issue.number) row.appendChild(draftStartControl(r.group.slug, r.issue, r.group.repo, "il-start"));
  }
  return row;
}

function issueNumberLink(number, repo) {
  if (!repo) return el("span", "il-number", `#${number}`);
  const a = el("a", "il-number", `#${number}`);
  a.href = `https://github.com/${repo}/issues/${number}`;
  a.target = "_blank"; a.rel = "noopener";
  a.title = `${repo}#${number} on GitHub`;
  return a;
}

/* The item's chat with the Issues pane on that issue; a broken file opens the
   pane on its first tab. An item newer than our last state is fetched first. */
async function openIssueRow(r) {
  if (!items.some(i => i.slug === r.group.slug)) await refresh();
  const it = items.find(i => i.slug === r.group.slug);
  if (!it) { toast(`${r.group.slug} is not a work item any more`, false); return; }
  openIssuesFor(it, r.error ? null : r.file);
}

function moveIssueList(d) {
  const rows = issueListRows();
  if (!rows.length) return;
  const at = Math.max(0, rows.findIndex(r => issueRowKey(r) === issueListFocus));
  issueListFocus = issueRowKey(rows[Math.max(0, Math.min(rows.length - 1, at + d))]);
  renderIssueList();
  const row = $("#issue-list-body .il-row.focused");
  if (row) { row.focus({ preventScroll: true }); row.scrollIntoView({ block: "nearest" }); }
}

$("#issue-list-body").addEventListener("click", e => {
  const node = e.target.closest(".il-row");
  if (!node) return;
  const r = issueListRows().find(x => issueRowKey(x) === node.dataset.key);
  if (!r) return;
  issueListFocus = node.dataset.key;
  if (e.target.closest("a, button")) return; // the #number's GitHub link, Start work, the item it became
  openIssueRow(r);
});

function issueListKey(e) {
  const r = issueListRows().find(x => issueRowKey(x) === issueListFocus);
  switch (e.key) {
    case "j": case "ArrowDown": e.preventDefault(); moveIssueList(1); break;
    case "k": case "ArrowUp":   e.preventDefault(); moveIssueList(-1); break;
    case "c": e.preventDefault(); newItemModal(); break;
    case "s": if (r && r.issue && r.issue.created && r.issue.number) { e.preventDefault(); startDraftIssue(r.group.slug, r.issue.number); } break;
    // Enter on the focused #number link is that link's own click.
    case "Enter": if (r && !e.target.closest(".il-row a")) { e.preventDefault(); openIssueRow(r); } break;
  }
}
