"use strict";

/* ------- Automations view: the list (left), one automation's detail (right) ------- */
/* Drawn from /api/automations and /api/automations/<slug>: schedules come
   from the server already read in local time (LocalSchedule); the page only
   picks weekdays and a time, which Apply sends for the server to turn into
   the UTC cron. */
const AU_DAYS = [[1, "Mon"], [2, "Tue"], [3, "Wed"], [4, "Thu"], [5, "Fri"], [6, "Sat"], [0, "Sun"]];

function renderAutomations() {
  if (mode !== "settings" || settingsTab !== "automations") return;
  const body = $("#au-body");
  const active = document.activeElement;
  const field = active && body.contains(active) && active.dataset.auField ? { name: active.dataset.auField, at: active.selectionStart } : null;
  keepScroll($(".st-wrap"), () => { body.innerHTML = automationsPage(); });
  if (!field) return;
  const again = body.querySelector(`[data-au-field="${field.name}"]`);
  if (!again) return;
  again.focus({ preventScroll: true });
  try { again.setSelectionRange(field.at, field.at); } catch (e) { /* not a text control */ }
}

function automationsPage() {
  const a = automations;
  if (!a.list) return `<div class="col-empty">${esc(a.error || "loading…")}</div>`;
  const remote = a.list.remote;
  const busy = a.busy.automations ? " busy" : "";
  const fetched = remote.fetchedAt ? `listed ${esc(agoText(remote.fetchedAt) || "just now")}` : "";
  const head = `<div class="au-head"><h2>Automations</h2><span class="st-sub">claude.ai routines qm manages</span>` +
    `<span class="au-fetched">${fetched}</span><button class="btn au-refresh${busy}" data-au="refresh" title="One list call to claude.ai">↻</button></div>`;
  return `${head}${automationsBanner(remote)}<div class="au-panes"><section class="au-list">${automationsList(a.list)}</section>` +
    `<section class="au-detail">${automationDetail()}</section></div>`;
}

/* Off and expired are states of the tab, said plainly with what to do. */
function automationsBanner(remote) {
  if (remote.state === "off") {
    return `<div class="au-banner"><b>Automations are off.</b> qm reaches your claude.ai routines with Claude Code's own login once you turn it on:` +
      `<code class="au-cmd">${esc(remote.command)}</code><span class="st-sub">Then reopen this tab. Local automations still show below.</span></div>`;
  }
  if (remote.state === "expired") {
    return `<div class="au-banner"><b>Can't reach claude.ai.</b> ${esc(remote.message)}` +
      `<span class="st-sub">qm never refreshes Claude Code's login itself. Then press ↻.</span></div>`;
  }
  if (remote.state === "error") return `<div class="au-banner error">${esc(remote.message)}</div>`;
  return "";
}

const auRunClass = status => {
  const s = String(status || "").toLowerCase();
  return /succe|complet|done/.test(s) ? "good" : /fail|error|cancel/.test(s) ? "bad" : /run|progress|pend|queue/.test(s) ? "busy" : "none";
};
const auRunLabel = status => String(status || "no runs yet").replace(/^ROUTINE_RUN_STATUS_/, "").toLowerCase();

function automationsList(list) {
  const a = automations;
  const projects = PROJECTS.filter(p => p !== "No project");
  const form = a.creating
    ? `<div class="au-new"><input id="au-new-title" type="text" placeholder="Title, e.g. Weekly shipped digest">` +
      `<select id="au-new-project"><option value="">Project…</option>${projects.map(p => `<option>${esc(p)}</option>`).join("")}</select>` +
      `<textarea id="au-new-description" rows="3" placeholder="What it should do (the chat starts from this)"></textarea>` +
      `<div class="au-actions"><button class="btn primary" data-au="create">Create and open its chat</button><button class="btn" data-au="new">Cancel</button></div></div>`
    : "";
  const rows = list.rows.map(r => {
    const run = r.lastRun || {};
    const busy = a.busy[`automation-${r.slug}`] ? `<span class="au-busy">${esc(a.busy[`automation-${r.slug}`])}…</span>` : "";
    return `<tr class="${r.slug === a.selected ? "sel" : ""}" data-au-row="${esc(r.slug)}">` +
      `<td><span class="au-dot ${auRunClass(run.status)}" title="last run: ${esc(auRunLabel(run.status))}"></span></td>` +
      `<td class="au-name">${esc(r.name)}${r.drift ? ' <span class="au-tag warn">changed outside qm</span>' : ""}${busy}<small>${esc(r.project || "no item")}</small></td>` +
      `<td>${esc(r.schedule ? r.schedule.label : "no schedule")}</td>` +
      `<td class="au-when">${esc(r.nextRunAt ? auTime(r.nextRunAt) : "–")}</td>` +
      `<td><button class="au-toggle${r.enabled ? " on" : ""}" data-au="toggle" data-slug="${esc(r.slug)}" data-enabled="${r.enabled}" ` +
      `title="${r.enabled ? "Pause" : "Resume"} (saves locally, then pushes)">${r.enabled ? "on" : "paused"}</button></td>` +
      `<td class="au-runner">${esc(r.runner)}</td></tr>`;
  }).join("");
  const table = list.rows.length
    ? `<table><tr><th></th><th>automation</th><th>schedule (local)</th><th>next run</th><th></th><th>runner</th></tr>${rows}</table>`
    : `<div class="col-empty">No automations yet. Start one, or adopt a routine below.</div>`;
  const unmanaged = list.unmanaged.length
    ? `<div class="st-group">Not managed by qm</div>${list.unmanaged.map(r =>
        `<div class="au-unmanaged"><div><b>${esc(r.name)}</b><small>${esc(r.schedule ? r.schedule.label : r.cron)} · <a href="${esc(r.routineUrl)}" target="_blank" rel="noopener">claude.ai</a></small></div>` +
        `<select data-adopt-project="${esc(r.id)}"><option value="">Project…</option>${projects.map(p => `<option>${esc(p)}</option>`).join("")}</select>` +
        `<button class="btn" data-au="adopt" data-id="${esc(r.id)}"${a.busy[`automation-adopt-${r.id}`] ? " disabled" : ""}>Adopt</button></div>`).join("")}`
    : "";
  return `<button class="btn au-new-btn" data-au="new">+ New automation</button>${form}${table}${unmanaged}`;
}

const auTime = iso => { const d = new Date(iso); return isNaN(d) ? iso : d.toLocaleString(undefined, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }); };

function automationDetail() {
  const a = automations;
  const d = a.detail;
  if (!d) return `<div class="col-empty">${a.selected ? "loading…" : "Pick an automation, or start a new one."}</div>`;
  const links = d.routineUrl ? `<a href="${esc(d.routineUrl)}" target="_blank" rel="noopener">open on claude.ai ↗</a>` : "not pushed yet: Push creates the routine";
  const drift = d.drift
    ? `<div class="au-drift"><b>Changed outside qm.</b> Pull takes claude.ai's version (your files are kept as .bak); Push overwrites it with yours.` +
      `<span class="au-actions"><button class="btn" data-au="pull">Pull</button><button class="btn" data-au="force-push">Push</button></span></div>`
    : d.missing ? `<div class="au-drift"><b>Its routine isn't on claude.ai any more.</b> Re-create makes a new one from your files; Delete… drops the automation.` +
      `<span class="au-actions"><button class="btn" data-au="recreate">Re-create on claude.ai</button></span></div>` : "";
  const confirm = a.confirmDelete === d.slug
    ? `<span class="au-confirm">Delete the routine and resolve the item? <button class="btn danger" data-au="delete">Delete</button><button class="btn" data-au="cancel-delete">Cancel</button></span>`
    : `<button class="btn" data-au="ask-delete">Delete…</button>`;
  return `<div class="au-title"><h3>${esc(d.name)}</h3><span class="au-tag">${esc(stateLabel(d.state || ""))}</span>${d.project ? `<span class="st-sub">${esc(d.project)}</span>` : ""}<span class="au-link">${links}</span></div>` +
    drift +
    `<div class="au-actions"><button class="btn" data-au="run"${d.routine ? "" : " disabled"}>Run now</button><button class="btn" data-au="chat">Edit with Claude</button>` +
    `${d.routine ? "" : '<button class="btn" data-au="push">Push</button>'}${confirm}</div>` +
    `<div class="st-title">Schedule</div>${automationSchedule(d)}` +
    `<div class="st-title">Prompt <small class="au-path">${esc(d.promptPath)}</small></div>` +
    `<textarea class="au-prompt" data-au-field="prompt" rows="12" spellcheck="false">${esc((automationEdit(false) || d).prompt)}</textarea>` +
    `<div id="au-apply-bar">${automationApplyBar()}</div>` +
    `<dl class="au-facts"><dt>model</dt><dd>${esc(d.model || "–")}</dd><dt>repos</dt><dd>${esc(d.repos.join(", ") || "–")}</dd>` +
    `<dt>connectors</dt><dd>${esc(d.connectors.join(", ") || "none")}</dd><dt>runner</dt><dd>${esc(d.runner)}</dd></dl>` +
    `<div class="st-title">Last runs</div>${automationRuns(d)}${automationItem(d)}`;
}

function automationSchedule(d) {
  const e = automationEdit(false) || { raw: !d.schedule || d.schedule.raw, days: (d.schedule && d.schedule.days) || [], time: (d.schedule && d.schedule.time) || "08:00", cron: d.cron || "" };
  const small = `<small class="au-utc">stored as <code>${esc(d.cron || "no cron")}</code> UTC${automationChanges() ? " · the new UTC cron is worked out on Apply" : ""}</small>`;
  if (e.raw) {
    return `<div class="au-sched"><input class="au-cron" data-au-field="cron" type="text" value="${esc(e.cron)}" placeholder="M H * * D (UTC)" spellcheck="false">` +
      `<button class="au-switch" data-au="raw">use weekdays and a time</button></div>${small}`;
  }
  const chips = AU_DAYS.map(([n, label]) => `<button class="au-day${e.days.includes(n) ? " on" : ""}" data-au="day" data-day="${n}">${label}</button>`).join("");
  return `<div class="au-sched">${chips}<input class="au-time" data-au-field="time" type="time" value="${esc(e.time)}">` +
    `<span class="st-sub">Amsterdam time</span><button class="au-switch" data-au="raw">raw cron</button></div>${small}`;
}

function automationApplyBar() {
  const d = automations.detail;
  if (!d || !automationChanges()) return "";
  const busy = automations.busy[`automation-${d.slug}`];
  return `<div class="au-apply"><span>Unapplied changes to this automation.</span>` +
    `<button class="btn primary" data-au="apply"${busy ? " disabled" : ""}>Apply</button><button class="btn" data-au="discard">Discard</button>` +
    `<span class="st-sub">saves the local files, then pushes to claude.ai</span></div>`;
}

function automationRuns(d) {
  if (!d.routine) return `<div class="au-empty">No runs: it has no routine yet.</div>`;
  if (d.runsState === "error") return `<div class="au-empty">Couldn't load its runs: ${esc(d.runsError)}</div>`;
  if (!d.runs) return `<div class="au-empty">${automations.busy[`automation-runs-${d.slug}`] ? "loading runs…" : "runs load from claude.ai when it can be reached"}</div>`;
  if (!d.runs.length) return `<div class="au-empty">No runs yet.</div>`;
  return `<ul class="au-runs">${d.runs.map(r =>
    `<li><span class="au-dot ${auRunClass(r.status)}"></span><a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.title || r.id)}</a>` +
    `<span class="au-when">${esc(r.created_at ? auTime(r.created_at) : "")}</span><span class="st-sub">${esc(auRunLabel(r.status))}</span></li>`).join("")}</ul>`;
}

function automationItem(d) {
  if (!d.item) return "";
  const notes = d.item.notes.map(n => `<li><span class="au-when">${esc(n.stamp)}</span> <span class="au-tag">${esc(n.kind)}</span> ${esc(n.text)}</li>`).join("");
  const draft = automations.describing && automations.describing.slug === d.slug ? automations.describing.text : null;
  const desc = draft === null
    ? `<div class="st-title">Description <button class="au-switch" data-au="edit-description" title="Edit the item's description (as qm describe does)">edit</button></div>` +
      `<div class="au-desc">${esc(d.item.description || "none yet")}</div>`
    : `<div class="st-title">Description</div><textarea class="au-prompt" data-au-field="description" rows="4">${esc(draft)}</textarea>` +
      `<div class="au-actions"><button class="btn primary" data-au="save-description">Save</button><button class="btn" data-au="cancel-description">Cancel</button>` +
      `<span class="st-sub">the item's description: qm's and the chat's, never pushed</span></div>`;
  return desc +
    `<div class="st-title">Notes</div>${notes ? `<ul class="au-notes">${notes}</ul>` : '<div class="au-empty">No notes yet.</div>'}`;
}
