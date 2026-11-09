"use strict";

/* ------- PRs view -------
   Open PRs the user wrote, is asked to review, or is assigned (PrInbox). The
   server caches GitHub's answer and refetches it on a thread; while it does,
   the view polls /api/prs until the fresh list lands. */
let prs = [];
let prsMeta = { fetchedAt: null, error: null, refreshing: false };
let prFocus = 0;
let prsTimer = null;
const PR_GROUPS = [
  { key: "review", label: "Review requested" },
  { key: "author", label: "Yours" },
  { key: "assignee", label: "Assigned to you" },
];
const prGroup = pr => pr.roles.includes("review") ? "review" : pr.roles.includes("author") ? "author" : "assignee";
const REVIEW_BADGE = {
  APPROVED: ["merged", "approved"],
  CHANGES_REQUESTED: ["degrading", "changes requested"],
  REVIEW_REQUIRED: ["stale", "review required"],
};
/* A group's PRs as stacks: a PR whose base is another listed PR's head (same
   repo) sits on that one. Each chain runs bottom first (merge order); chains
   keep the place of their most recently updated PR; a lone PR is a chain of one. */
function prChains(key) {
  const list = prs.filter(pr => prGroup(pr) === key);
  const byHead = new Map(list.map(pr => [`${pr.repo}:${pr.head}`, pr]));
  const kids = new Map();
  const roots = [];
  list.forEach(pr => {
    const parent = byHead.get(`${pr.repo}:${pr.base}`);
    if (parent && parent !== pr) kids.set(parent, (kids.get(parent) || []).concat(pr));
    else roots.push(pr);
  });
  const seen = new Set();
  const walk = (pr, chain) => { if (seen.has(pr)) return chain; seen.add(pr); chain.push(pr); (kids.get(pr) || []).forEach(k => walk(k, chain)); return chain; };
  const chains = roots.map(root => walk(root, []));
  list.forEach(pr => { if (!seen.has(pr)) chains.push(walk(pr, [])); }); // a base cycle: shown, unordered
  const first = chain => Math.min(...chain.map(pr => list.indexOf(pr)));
  return chains.sort((a, b) => first(a) - first(b));
}
const prRows = () => PR_GROUPS.flatMap(g => prChains(g.key).flat());

function agoText(iso) {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (!(s >= 0)) return "";
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

async function loadPrs(force = false) {
  clearTimeout(prsTimer);
  try {
    const res = await (await fetch("/api/prs" + (force ? "?refresh=1" : ""))).json();
    if (!res.ok) { toast(res.error || "could not list PRs", false); return; }
    prs = res.prs;
    prsMeta = { fetchedAt: res.fetchedAt, error: res.error, refreshing: res.refreshing,
                prerequisitesRefreshing: res.prerequisitesRefreshing };
  } catch (e) { toast("could not reach qm — is the tab still connected?", false); return; }
  // Also while the deploy check runs, so its verdicts replace the "?" chips.
  if (prsMeta.refreshing || prsMeta.prerequisitesRefreshing) prsTimer = setTimeout(loadPrs, 2000);
  renderPrs();
}

/* The toggle's tally: the user's own PRs by review state (drafts left out),
   then the ones waiting on him — review requested, or assigned and not a draft. */
function renderPrsBadge() {
  const mine = prs.filter(pr => prGroup(pr) === "author" && !pr.draft);
  const count = decision => mine.filter(pr => pr.reviewDecision === decision).length;
  const approved = count("APPROVED"), changes = count("CHANGES_REQUESTED");
  const open = mine.length - approved - changes;
  // Assigned drafts aren't ready for the user yet — unless they ask for their review outright.
  const waiting = prs.filter(pr => pr.roles.includes("review") || (prGroup(pr) === "assignee" && !pr.draft)).length;
  const parts = [];
  if (approved) parts.push(`<span class="ok">✓${approved}</span>`);
  if (changes) parts.push(`<span class="bad">✗${changes}</span>`);
  if (open) parts.push(`<span class="open">${open}</span>`);
  if (waiting) parts.push(`${parts.length ? '<span class="sep"></span>' : ""}<span class="you">${waiting}</span>`);
  const badge = $("#prs-badge");
  badge.className = parts.length ? "prs-tally" : "";
  badge.innerHTML = parts.join("");
  badge.parentElement.title = "Open PRs (p)\nYours: " +
    `${approved} approved, ${changes} changes requested, ${open} awaiting review` +
    `\nWaiting on you: ${waiting} review requested, or assigned (drafts left out)`;
}

function renderPrs() {
  renderPrsBadge();
  if (mode !== "prs") return;
  const body = $("#prs-body");
  keepScroll(body.closest(".prs-wrap"), () => {
    body.innerHTML = "";
    $("#prs-count").textContent = prs.length;
    const fetched = $("#prs-fetched");
    fetched.className = "prs-fetched" + (prsMeta.error && !prsMeta.refreshing ? " bad" : "");
    fetched.textContent = prsMeta.refreshing ? "fetching from GitHub…"
      : prsMeta.error ? `last fetch failed: ${prsMeta.error}`
      : prsMeta.fetchedAt ? `fetched ${agoText(prsMeta.fetchedAt)}` : "";
    const rows = prRows();
    if (!rows.length) { body.appendChild(el("div", "col-empty", prsMeta.refreshing ? "fetching…" : "no open PRs")); return; }
    prFocus = Math.max(0, Math.min(prFocus, rows.length - 1));
    PR_GROUPS.forEach(g => {
      const chains = prChains(g.key);
      const n = chains.flat().length;
      if (!n) return;
      body.appendChild(el("div", "att-group", `${esc(g.label)} · ${n}`));
      chains.forEach(chain => {
        if (chain.length === 1) { body.appendChild(prRow(chain[0], rows.indexOf(chain[0]) === prFocus)); return; }
        const box = el("div", "pr-stack");
        box.appendChild(prStackHead(chain));
        chain.forEach((pr, i) => box.appendChild(prRow(pr, rows.indexOf(pr) === prFocus, `${i + 1}/${chain.length}`)));
        body.appendChild(box);
      });
    });
  });
}

function prStackHead(chain) {
  const count = d => chain.filter(pr => pr.reviewDecision === d).length;
  const approved = count("APPROVED"), changes = count("CHANGES_REQUESTED");
  const head = el("div", "pr-stack-head");
  head.appendChild(el("span", "", `stack · ${chain.length} PRs onto <span class="branch">${esc(chain[0].base)}</span>`));
  if (approved) head.appendChild(el("span", "ok", `✓${approved} approved`));
  if (changes) head.appendChild(el("span", "bad", `✗${changes} changes requested`));
  return head;
}

/* The head commit's checks like GitHub's PR list: ✓ 31 / 31, ✗ 28 / 31, ● while running. */
const CI_MARK = { SUCCESS: ["ok", "✓", "passed"], FAILURE: ["bad", "✗", "failed"], ERROR: ["bad", "✗", "errored"] };
function prCi(pr) {
  if (!pr.ci) return null;
  const [cls, mark, word] = CI_MARK[pr.ci.state] || ["", "●", "running"];
  const a = el("a", `pr-ci ${cls}`, `${mark} ${pr.ci.ok} / ${pr.ci.total}`);
  a.href = `${pr.url}/checks`; a.target = "_blank"; a.rel = "noopener";
  a.title = `CI ${word}: ${pr.ci.ok} of ${pr.ci.total} checks OK — open the checks on GitHub`;
  return a;
}

/* One chip per prerequisite (qm pr-requires): whether it is in the repo's
   latest release yet. A PR shows as #n, a commit as its 7-char sha; the
   chip links to it, its ✕ removes it. A chip with a note (--note) is
   marked 📝 and its body opens the note instead; the GitHub link moves
   into that popover. */
function prReqText(req) {
  const name = req.kind === "pr" ? "#" + req.ref.split("/").pop() : req.ref.slice(0, 7);
  switch (req.state) {
    case "deployed": return [`✓ ${name} deployed in ${req.tag}`, `in the latest release (${req.tag})`];
    case "pending": return [`⏳ needs ${name} — not in ${req.tag}`, `not in the latest release (${req.tag}) yet`];
    case "unmerged": return [`needs ${name} — not merged`, "not merged yet"];
    case "closed": return [`needs ${name} — closed`, "closed without merging, so it will never deploy"];
    default: return [`needs ${name} — ?`, "not checked against the latest release yet"];
  }
}
function prReqUrl(req) {
  return req.kind === "pr" ? req.ref : `https://github.com/${req.repo}/commit/${req.ref}`;
}
/* Show only: notes are written with `qm pr-requires … --note`. Esc and an
   outside click close it like every popover. */
function prReqNote(anchor, req) {
  popAt(anchor, p => {
    p.appendChild(el("div", "pop-label", "Before merging"));
    p.appendChild(el("div", "pop-note", esc(req.note)));
    const link = el("a", "pop-link", `Open ${req.kind === "pr" ? "#" + req.ref.split("/").pop() : req.ref.slice(0, 7)} on GitHub ↗`);
    link.href = prReqUrl(req); link.target = "_blank"; link.rel = "noopener";
    p.appendChild(link);
  });
  openPop.querySelector(".pop-link").focus({ preventScroll: true });
}
function prReqs(pr) {
  return (pr.prerequisites || []).map(req => {
    const [text, tip] = prReqText(req);
    const chip = el("span", "pr-req " + (req.state || "unknown"));
    let a;
    if (req.note) {
      a = el("button", "pr-req-note", `${esc(text)} 📝`);
      a.dataset.ref = req.ref;
      a.title = `Must be deployed before this PR merges: ${tip} — click for its note`;
    } else {
      a = el("a", "", esc(text));
      a.href = prReqUrl(req);
      a.target = "_blank"; a.rel = "noopener";
      a.title = `Must be deployed before this PR merges: ${tip}`;
    }
    const x = el("button", "pr-req-x", "✕");
    x.dataset.ref = req.ref;
    x.title = "Remove this prerequisite";
    x.setAttribute("aria-label", `Remove prerequisite: ${text}`);
    chip.append(a, x);
    return chip;
  });
}

function prRow(pr, focused, pos) {
  const row = el("div", "pr-row" + (focused ? " focused" : ""));
  row.tabIndex = 0;
  row.dataset.url = pr.url;
  const main = el("div", "pr-main");
  const line1 = el("div", "pr-line1");
  if (pos) line1.appendChild(el("span", "pr-pos", pos));
  const label = el("a", "slug pr-link", esc(pr.label));
  label.href = pr.url; label.target = "_blank"; label.rel = "noopener";
  label.title = "Open the PR on GitHub";
  line1.appendChild(label);
  if (pr.draft) line1.appendChild(el("span", "badge draft", "draft"));
  const decision = REVIEW_BADGE[pr.reviewDecision];
  if (decision) line1.appendChild(el("span", `badge ${decision[0]}`, decision[1]));
  const ci = prCi(pr);
  if (ci) line1.appendChild(ci);
  prReqs(pr).forEach(chip => line1.appendChild(chip));
  const job = jobFor(pr.jobKey);
  if (job) line1.appendChild(el("span", "badge distilling", esc(job.label)));
  main.appendChild(line1);
  const title = el("div", "pr-title", esc(pr.title));
  title.title = pr.title;
  main.appendChild(title);
  const meta = el("div", "pr-meta");
  const bit = html => { if (meta.childNodes.length) meta.appendChild(el("span", "sep", "·")); meta.appendChild(el("span", "", html)); };
  bit(`@${esc(pr.author)}`);
  bit(`<span class="branch">${esc(pr.head)} → ${esc(pr.base)}</span>`);
  if (pr.updatedAt) bit(`updated ${agoText(pr.updatedAt)}`);
  if (pr.worktree) bit(`🌳 ${esc(pr.worktree)}`);
  if (pr.served) bit(`🖥 ${devCmd()} serves it`);
  if (pr.item) bit(`<button class="item-link" data-slug="${esc(pr.item)}" title="Open this item's chat">${esc(pr.item)}</button>${pr.pane ? " (live)" : ""}`);
  if (pr.reviewItem) bit(`review: <button class="item-link" data-slug="${esc(pr.reviewItem)}" title="Open the review's chat">${esc(pr.reviewItem)}</button>`);
  main.appendChild(meta);
  row.appendChild(main);

  const acts = el("div", "pr-acts");
  const btn = (key, label, tip, enabled = true) => {
    const b = el("button", "act", label);
    b.dataset.act = key; b.title = tip; b.disabled = !enabled;
    acts.appendChild(b);
  };
  btn("gh", "GitHub ↗", "Open the PR on GitHub (o)");
  btn("chat", "Chat", pr.item ? `Open ${pr.item}'s chat (⏎)` : "Start a chat about this PR in a new work item (⏎)");
  btn("review", "Review", `Run ${pr.reviewSkill || "/code-review"} in a new chat (w)`);
  if (pr.ide) btn("ide", pr.ide, `Open ${pr.head} in ${pr.ide}${pr.worktree ? "" : " (creates a worktree)"}`, !job);
  if (pr.devServer) btn("pf", pr.devServer, pf.off || `Serve ${pr.head} with ${pr.devServer}${pr.worktree ? "" : " (creates a worktree)"}`, !job && !jobs.some(j => j.pf) && !pf.off);
  row.appendChild(acts);
  return row;
}

function focusedPr() { return prRows()[prFocus]; }
function movePr(d) {
  const rows = prRows();
  if (!rows.length) return;
  prFocus = Math.max(0, Math.min(rows.length - 1, prFocus + d));
  renderPrs();
  const row = $("#prs-body .pr-row.focused");
  if (row) { row.focus({ preventScroll: true }); row.scrollIntoView({ block: "nearest" }); }
}

function prAction(a, pr) {
  switch (a) {
    case "gh": window.open(pr.url, "_blank", "noopener"); break;
    case "chat": case "review":
      act(a === "chat" ? "pr-chat" : "pr-review", { args: { url: pr.url } }).then(r => {
        if (!r.ok || !r.slug) return;
        toast(r.attached ? `${r.slug}: its chat is already running` : a === "review" ? `review started in ${r.slug}` : `chat for ${pr.label} in ${r.slug}`);
        if (!panes.includes(r.slug)) panes = panes.concat(r.slug);
        const it = items.find(i => i.slug === r.slug);
        if (it) openChat(it);
        loadPrs();
      });
      break;
    case "ide": case "pf":
      act(`pr-${a}`, { args: { url: pr.url } }).then(r => {
        if (r.ok) { toast(`${pr.label}: ${a === "pf" ? `switching ${pr.devServer}` : `opening ${pr.ide}`}…`); renderPrs(); }
      });
      break;
  }
}

$("#prs-body").addEventListener("click", e => {
  const row = e.target.closest(".pr-row");
  if (!row) return;
  const pr = prs.find(p => p.url === row.dataset.url);
  if (!pr) return;
  prFocus = prRows().indexOf(pr);
  if (e.target.closest(".pr-req a, .pr-link")) return;
  const noted = e.target.closest(".pr-req-note");
  if (noted) {
    const req = (pr.prerequisites || []).find(r => r.ref === noted.dataset.ref);
    if (req) prReqNote(noted, req);
    return;
  }
  const unrequire = e.target.closest(".pr-req-x");
  if (unrequire) {
    act("pr-unrequire", { args: { url: pr.url, ref: unrequire.dataset.ref } }).then(r => { if (r.ok) loadPrs(); });
    return;
  }
  const link = e.target.closest(".item-link");
  if (link) { const it = items.find(i => i.slug === link.dataset.slug); if (it) openChat(it); return; }
  const b = e.target.closest(".act");
  if (b) prAction(b.dataset.act, pr); else renderPrs();
});
$("#prs-refresh").addEventListener("click", () => loadPrs(true));

function prsKey(e) {
  const pr = focusedPr();
  switch (e.key) {
    case "j": case "ArrowDown": e.preventDefault(); movePr(1); break;
    case "k": case "ArrowUp":   e.preventDefault(); movePr(-1); break;
    case "c": e.preventDefault(); newItemModal(); break;
    // Enter on a focused button or link inside the row is that control's own
    // click (a chip's ✕ removes a prerequisite); it must not also open the chat.
    case "Enter": if (pr && !e.target.closest(".pr-row button, .pr-row a")) prAction("chat", pr); break;
    case "w": if (pr) prAction("review", pr); break;
    case "o": if (pr) prAction("gh", pr); break;
  }
}

function setMode(m) {
  if (m === "settings" && mode !== "settings") settingsReturnMode = mode;
  mode = m;
  document.body.dataset.mode = m;
  document.querySelectorAll("#modes button").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.mode === m)));
  $("#settings-btn").setAttribute("aria-pressed", String(m === "settings"));
  try { localStorage.setItem("qm-mode", m); } catch (e) { /* storage blocked: the mode just isn't remembered */ }
  closePop();
  if (m === "chat") { renderChat(); pulseTick(); }
  else if (m === "prs") { renderPrs(); loadPrs(); }
  else if (m === "issues") { renderIssueList(); loadIssueIndex(); }
  else if (m === "settings") openSettings();
  else render();
}
/* Opening an item from the board lands in its chat. */
function openChat(it) { chatSlug = it.slug; setMode("chat"); selectChat(it.slug, { focusTerm: true }); }

/* About once a second, poll the hook logs' sizes. On the chat view, refetch
   the state only when they moved. Anywhere else, or in a hidden tab (which
   browsers throttle to about once a minute), refetch only whose move it is
   when hook events landed: the tab title's count and the notifications. The
   pulse also tells the server whether this page is visible, focused and on
   which chat — so it leaves notifications to the page (TurnNotifier). A
   page-side poll, not a server liveness timer (see docs/areas/gui-shell.md): the server
   never notices it stopping. */
let lastPulse = null;
let lastEvents = null;
let lastIssues = null;
let pulseBusy = false;
async function pulseTick() {
  if (pulseBusy) return;
  pulseBusy = true;
  const onChat = mode === "chat" && !document.hidden;
  try {
    const q = new URLSearchParams({ visible: document.hidden ? "0" : "1", focused: document.hasFocus() ? "1" : "0",
                                    chat: mode === "chat" && chatSlug ? chatSlug : "" });
    const r = await fetch("/api/pulse?" + q);
    const { pulse, events, issues } = await r.json();
    const eventsMoved = events !== lastEvents;
    const issuesMoved = lastIssues !== null && issues !== lastIssues;
    lastEvents = events;
    lastIssues = issues;
    // An issue file changed: the Issues tab's count, in every mode (the chat
    // view's own refresh below covers it there), and the Issues view's rows.
    if (issuesMoved && !onChat) await refresh();
    if (issuesMoved && mode === "issues") loadIssueIndex();
    if (!onChat) { if (eventsMoved) await refreshAttention(); }
    else if (pulse !== lastPulse) await refresh();
    // A dropped pane (GUI restarted, laptop slept) reattaches; connect() throttles.
    // The aside logs no events, so it never moves the pulse: check it here too.
    else if (chatSlug && ((panes.includes(chatSlug) && !chatTerm.ws) ||
                          (panes.includes(asideName(chatSlug)) && !asideTerm.ws))) renderChatMain();
  } catch (e) { /* the next tick tries again; refresh() toasts real outages */ }
  finally { pulseBusy = false; }
  if (onChat) document.querySelectorAll(".att-wait[data-since]").forEach(w => { if (w.dataset.since) w.textContent = waitedFor(w.dataset.since); });
}
setInterval(pulseTick, 1000);
document.addEventListener("visibilitychange", pulseTick);
