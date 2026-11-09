"use strict";

/* ------- start work from a GitHub issue (IssueStart) -------
   Every entry point — the ＋ New item modal's "From issue" row, `#1234` /
   `project#1234` in the search box, a created draft's Start work — ends in
   one confirmation modal: issue-preview reads the issue (gh, read-only) and
   the modal shows its title, state, project and the branch Start would make.
   Start is issue-start: an item that already holds the issue gets its chat
   opened, otherwise a background job makes the worktree and the item and
   opens the chat; its finish (jobFinished) lands this tab in that chat. */
const issueStarting = new Set(); // job keys (new items' slugs) this tab started

/* "#123" or "my-app#123" as the whole text → { number, project }; the
   project is null when the text names none. */
function issueRef(text) {
  const m = String(text || "").trim().match(/^([A-Za-z][\w.-]*)?#([1-9]\d*)$/);
  if (!m) return null;
  return { number: Number(m[2]), project: m[1] ? projectNamed(m[1]) : null };
}
const projectNamed = (name) => PROJECTS.find(p => p.toLowerCase() === name.toLowerCase()) || name;
const issueProjects = () => PROJECTS.filter(p => p !== "No project");

/* The project a bare #123 means: the open chat's or sheet's item, else the
   focused card's; null lets the server fall back to config.yml's default
   project (DEFAULT_PROJECT). */
function contextProject() {
  const slug = mode === "chat" ? chatSlug : detailSlug || (mode === "board" && focusedItem() || {}).slug;
  const it = slug && items.find(i => i.slug === slug);
  return it && issueProjects().includes(it.project) ? it.project : null;
}

/* The search box's "Start work on #1234" (⏎ while the text is an issue ref). */
function startFromSearch() {
  const ref = issueRef(query);
  if (!ref) return;
  $("#search").blur();
  issueStartModal(ref.number, ref.project || contextProject());
}

/* The preview, straight from the action endpoint: it changes nothing, so no
   state refresh, and a failure belongs in the modal, not a toast. */
async function issuePreview(number, project) {
  try {
    const r = await fetch("/api/action", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cmd: "issue-preview", slug: null, args: { number, project } }),
    });
    return await r.json();
  } catch (e) { return { ok: false, error: "could not reach qm" }; }
}

/* from: the drafting item's slug (a created draft's Start work), which the
   server notes with what the issue became. */
function issueStartModal(number, project, { from = null } = {}) {
  let box = null;
  modal(m => {
    m.classList.add("issue-start-modal");
    m.innerHTML = `<h2>Start work on #${esc(number)}</h2><p class="sub">${esc(project || DEFAULT_PROJECT || "No project")} · looking up the issue…</p>`;
    box = m;
  });
  const shown = openModal;
  issuePreview(number, project).then(res => {
    if (openModal !== shown) return; // closed or replaced while gh answered
    if (!res.ok) renderIssueStartError(box, number, res.error || "issue lookup failed");
    else renderIssueStartPreview(box, res.issue, from);
  });
}

function renderIssueStartError(m, number, error) {
  m.innerHTML = `<h2>Start work on #${esc(number)}</h2>`;
  m.appendChild(el("div", "is-error", esc(error)));
  const bar = el("div", "modal-actions");
  const close = el("button", "btn", "Close"); close.onclick = closeModal;
  bar.appendChild(close); m.appendChild(bar);
  close.focus();
}

/* A3: what Start would do. An item already holding the issue (A4) turns
   Start into "Open its chat"; a closed issue warns but stays startable. */
function renderIssueStartPreview(m, iss, from) {
  m.innerHTML = `<h2>Start work on #${esc(iss.number)}</h2><p class="sub">${esc(iss.repo)}#${esc(iss.number)}</p>`;
  const title = el("a", "is-title", esc(iss.title));
  title.href = iss.url; title.target = "_blank"; title.rel = "noopener";
  title.title = "Open the issue on GitHub";
  m.appendChild(title);
  const facts = el("dl", "is-facts");
  const fact = (label, html) => facts.append(el("dt", "", esc(label)), el("dd", "", html));
  fact("State", `<span class="is-state ${iss.closed ? "closed" : "open"}">${esc(iss.state)}</span>`);
  fact("Project", esc(iss.project));
  if (iss.existing) fact("Work item", `<span class="mono">${esc(iss.existing.slug)}</span> · ${esc(stateLabel(iss.existing.state))}`);
  else fact("Branch", `<span class="mono">${esc(iss.branch)}</span>${iss.reuse_branch ? " · reuses this local branch" : " · new, off origin's default branch"}`);
  m.appendChild(facts);
  if (iss.closed) m.appendChild(el("div", "is-warn", "This issue is closed on GitHub. You can still start work on it."));
  if (iss.existing) m.appendChild(el("div", "is-note", `Already tracked as <b>${esc(iss.existing.slug)}</b>: Start opens its chat instead of making a second item.`));
  else m.appendChild(el("div", "is-note", "Start creates the work item and its worktree, then opens a chat that reads the issue and proposes a plan."));
  const bar = el("div", "modal-actions");
  const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
  const go = el("button", "btn primary", iss.existing ? "Open its chat" : "Start");
  go.onclick = () => { go.disabled = true; startIssue(m, iss, from).then(started => { if (!started) go.disabled = false; }); };
  bar.append(cancel, go); m.appendChild(bar);
  go.focus();
}

/* True once the server took it: the chat is open (existing) or the job runs,
   its label shown in the modal until it finishes (or the modal is hidden —
   the job carries on and its finish still opens the chat). */
async function startIssue(m, iss, from) {
  const shown = openModal;
  // Marked before asking: act's own state refresh may already carry the finish.
  if (!iss.existing) issueStarting.add(iss.slug);
  const r = await act("issue-start", { args: { number: iss.number, project: iss.project, from } });
  if (!r.ok) { issueStarting.delete(iss.slug); return false; }
  if (r.existing) {
    if (openModal === shown) closeModal();
    toast(`#${iss.number} is already ${r.slug}: opened its chat`);
    openItemChat(r.slug);
    return true;
  }
  if (r.slug !== iss.slug) { issueStarting.delete(iss.slug); issueStarting.add(r.slug); }
  if (!issueStarting.has(r.slug)) { // already finished, chat on its way
    if (openModal === shown) closeModal();
    return true;
  }
  if (openModal === shown) showIssueStartProgress(m, iss, r.slug);
  else toast(`starting #${iss.number} as ${r.slug}…`);
  return true;
}

function showIssueStartProgress(m, iss, slug) {
  const bar = m.querySelector(".modal-actions");
  const line = el("div", "is-progress", `<span class="is-spin"></span><span class="is-label"></span>`);
  bar.replaceWith(line);
  const hide = el("button", "btn", "Hide");
  hide.title = "The job carries on; its chat opens when it is done";
  hide.onclick = closeModal;
  const actions = el("div", "modal-actions");
  actions.appendChild(hide);
  m.appendChild(actions);
  hide.focus();
  const tick = () => {
    const job = jobFor(slug);
    line.querySelector(".is-label").textContent = job ? job.label : `starting #${iss.number}…`;
  };
  tick();
  const timer = setInterval(tick, 400);
  openModal.dataset.issueJob = slug;
  openModal.onClose = () => clearInterval(timer);
}

/* From jobFinished: a job this tab started lands in the new item's chat. A
   failure was toasted there already. */
function issueStartFinished(r) {
  if (!issueStarting.delete(r.key)) return;
  if (openModal && openModal.dataset.issueJob === r.key) closeModal();
  if (r.ok) setTimeout(() => openItemChat(r.slug || r.key), 0);
}

async function openItemChat(slug) {
  if (!items.some(i => i.slug === slug)) await refresh();
  const it = items.find(i => i.slug === slug);
  if (!it) { toast(`${slug} is not a work item any more`, false); return; }
  closeDetail();
  openChat(it);
}

/* The ＋ New item modal's "From issue" row: number and project, then the
   confirmation in place of the modal. */
function issueFromNewItemRow() {
  const projects = issueProjects();
  const preferred = contextProject() || (projects.includes(DEFAULT_PROJECT) ? DEFAULT_PROJECT : projects[0]);
  const row = el("div", "field is-from",
    `<label>From issue <span style="text-transform:none;color:var(--faint)">(a GitHub issue → item, worktree and chat)</span></label>
     <div class="is-from-row"><input type="text" inputmode="numeric" placeholder="#1234">
     <select>${projects.map(p => `<option${p === preferred ? " selected" : ""}>${esc(p)}</option>`).join("")}</select>
     <button class="btn" type="button">Look up</button></div>`);
  const input = row.querySelector("input");
  const go = () => {
    const ref = issueRef(input.value.trim().replace(/^(?=\d)/, "#"));
    if (!ref) { input.focus(); return; }
    issueStartModal(ref.number, ref.project || row.querySelector("select").value || null);
  };
  row.querySelector("button").onclick = go;
  input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); go(); } });
  return row;
}

/* ------- a created draft: Start work, or the item it became (A9) ------- */
/* The drafting item's "#N started as <slug>" note, else an item holding the
   issue by A4's rule (its issue/N branch in the project, or the URL in its
   description), unresolved first. The drafting item itself never counts. */
function issueBecame(fromSlug, number, repo) {
  const exists = slug => items.some(i => i.slug === slug);
  const from = items.find(i => i.slug === fromSlug);
  const noted = from && (from.notes || []).map(n => String(n.text).match(/^#(\d+) started as (\S+)$/))
    .find(m => m && Number(m[1]) === Number(number) && exists(m[2]));
  if (noted) return noted[2];
  const url = repo ? `https://github.com/${repo}/issues/${number}` : null;
  const branch = b => b === `issue/${number}` || b.startsWith(`issue/${number}-`);
  const holds = it => it.slug !== fromSlug && (
    (from && it.project === from.project && (it.branches || []).some(branch)) ||
    (url && new RegExp(url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(?!\\d)").test(it.description || "")));
  const hit = items.filter(holds).sort((a, b) => (a.state === "resolved") - (b.state === "resolved"))[0];
  return hit ? hit.slug : null;
}

/* The control a created draft shows: a link to the item it became, else
   Start work. cls: the button's class where it sits. */
function draftStartControl(fromSlug, issue, repo, cls = "") {
  const became = issueBecame(fromSlug, issue.number, repo);
  if (became) {
    const a = el("a", "is-became", `→ ${esc(became)}`);
    a.href = "#"; a.title = `#${issue.number} is work item ${became}: open its chat`;
    a.onclick = e => { e.preventDefault(); e.stopPropagation(); openItemChat(became); };
    return a;
  }
  const b = el("button", ("is-start " + cls).trim(), "Start work");
  b.type = "button";
  b.title = `Start work on #${issue.number}: a new work item with its own worktree and chat`;
  b.onclick = e => { e.stopPropagation(); startDraftIssue(fromSlug, issue.number); };
  return b;
}

function startDraftIssue(fromSlug, number) {
  const from = items.find(i => i.slug === fromSlug);
  const project = from && issueProjects().includes(from.project) ? from.project : null;
  issueStartModal(number, project, { from: fromSlug });
}
