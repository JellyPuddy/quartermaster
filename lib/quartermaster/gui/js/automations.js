"use strict";

/* ------- ⚙ area: the Settings | Automations tab strip, and the Automations view ------- */
/* The view reads /api/automations: the local files at once, merged with what
   the last list call saw. A ↻ (and opening the tab, and every action) starts
   one list call as a server job; the page learns it ended from the state
   poll (jobFinished → automationJobFinished) and reloads. Runs load only for
   the automation shown in the detail. Schedule and prompt edits stay in the
   page until Apply, which saves them locally and pushes — per automation,
   never a page-wide Save. */
let settingsTab = "settings";
try { if (localStorage.getItem("qm-settings-tab") === "automations") settingsTab = "automations"; } catch (e) { /* storage blocked */ }

const automations = { list: null, error: null, selected: null, detail: null, edits: {}, busy: {},
                      creating: false, confirmDelete: null, runsAsked: null };

function setSettingsTab(tab) {
  settingsTab = tab;
  document.body.dataset.stTab = tab;
  document.querySelectorAll("#st-tabs [data-st-tab]").forEach(b => b.setAttribute("aria-selected", String(b.dataset.stTab === tab)));
  try { localStorage.setItem("qm-settings-tab", tab); } catch (e) { /* the tab just isn't remembered */ }
  if (mode === "settings") openSettings();
}
setSettingsTab(settingsTab);

function openAutomations() {
  renderAutomations();
  loadAutomations().then(refreshAutomations);
}

async function loadAutomations() {
  const a = automations;
  try { a.list = await (await fetch("/api/automations")).json(); a.error = null; }
  catch (e) { a.error = "could not reach qm"; }
  const slugs = a.list ? a.list.rows.map(r => r.slug) : [];
  if (!slugs.includes(a.selected)) a.selected = slugs[0] || null;
  await loadAutomationDetail();
  renderAutomations();
}

async function loadAutomationDetail() {
  const a = automations;
  const slug = a.selected;
  a.detail = null;
  if (!slug) return;
  try {
    const r = await fetch(`/api/automations/${encodeURIComponent(slug)}`);
    a.detail = r.ok ? await r.json() : null;
  } catch (e) { a.detail = null; }
  const off = !a.list || ["off", "expired"].includes(a.list.remote.state);
  if (a.detail && a.detail.routine && a.detail.runsState === "idle" && a.runsAsked !== slug && !off) {
    a.runsAsked = slug;
    automationJob("runs", { slug }, `automation-runs-${slug}`);
  }
}

async function automationPost(verb, body) {
  try {
    const r = await fetch(`/api/automations/${verb}`, { method: "POST", headers: { "Content-Type": "application/json" },
                                                         body: JSON.stringify(body) });
    const res = await r.json();
    if (!res.ok) toast(res.error || `${verb} failed`, false);
    return res;
  } catch (e) { toast("could not reach qm", false); return { ok: false }; }
}

/* Starts a server job and the state poll that reports its end. */
async function automationJob(verb, body, key) {
  const res = await automationPost(verb, body);
  if (res.background) { automations.busy[key] = verb; renderAutomations(); refresh(); }
  return res;
}

async function refreshAutomations() {
  const res = await automationJob("refresh", {}, "automations");
  if (res.ok && !res.background) loadAutomations();
}

/* jobFinished hands every job here first; true when it was an automation's. */
function automationJobFinished(r) {
  const key = String(r.key || "");
  if (key !== "automations" && !key.startsWith("automation-")) return false;
  delete automations.busy[key];
  if (key.startsWith("automation-runs-")) automations.runsAsked = null;
  if (!r.quiet) toast(r.ok ? (r.message || `${key}: done`) : (r.error || `${key}: failed`), r.ok);
  if (r.ok && key.startsWith("automation-adopt-") && r.automation) automations.selected = r.automation;
  if (mode === "settings" && settingsTab === "automations") loadAutomations();
  return true;
}

function selectAutomation(slug) {
  automations.selected = slug;
  automations.confirmDelete = null;
  loadAutomationDetail().then(renderAutomations);
}

/* ------- edits: the detail's schedule and prompt until Apply ------- */
function automationEdit(create) {
  const d = automations.detail;
  if (!d) return null;
  if (!automations.edits[d.slug] && create) {
    const s = d.schedule || { raw: true };
    automations.edits[d.slug] = { raw: !!s.raw, days: (s.days || []).slice(), time: s.time || "08:00",
                                  cron: d.cron || "", prompt: d.prompt };
  }
  return automations.edits[d.slug] || null;
}

/* What Apply would send beyond the slug, or null when nothing changed. */
function automationChanges() {
  const d = automations.detail;
  const e = automationEdit(false);
  if (!d || !e) return null;
  const out = {};
  const s = d.schedule || { raw: true };
  if (e.raw) { if (e.cron.trim() !== (d.cron || "")) out.cron = e.cron.trim(); }
  else if (s.raw || e.time !== s.time || JSON.stringify([...e.days].sort()) !== JSON.stringify([...s.days].sort())) {
    out.days = e.days; out.time = e.time;
  }
  if (e.prompt !== d.prompt) out.prompt = e.prompt;
  return Object.keys(out).length ? out : null;
}

async function applyAutomation() {
  const d = automations.detail;
  const changes = automationChanges();
  if (!d || !changes) return;
  const res = await automationJob("apply", { slug: d.slug, ...changes }, `automation-${d.slug}`);
  if (res.ok) delete automations.edits[d.slug];
  renderAutomations();
}

/* ------- chats: new automation, Edit with Claude ------- */
async function openAutomationChat(slug) {
  const r = await act("automation-chat", { slug });
  if (!r.ok) return;
  if (r.attached) {
    try { await navigator.clipboard.writeText(r.brief); toast("its chat already runs — nothing typed; the brief is on the clipboard"); }
    catch (e) { toast("its chat already runs — nothing typed", true); }
  }
  openChat({ slug });
}

async function createAutomation() {
  const title = $("#au-new-title").value.trim();
  const project = $("#au-new-project").value;
  const description = $("#au-new-description").value.trim();
  if (!title || !project) { toast("a new automation needs a title and a project", false); return; }
  const res = await automationPost("new", { title, project, description });
  if (!res.ok) return;
  automations.creating = false;
  openAutomationChat(res.slug);
}

/* ------- events ------- */
document.querySelectorAll("#st-tabs [data-st-tab]").forEach(b => b.addEventListener("click", () => setSettingsTab(b.dataset.stTab)));

$("#au-body").addEventListener("click", e => {
  const node = e.target.closest("[data-au]");
  if (!node) { const row = e.target.closest("[data-au-row]"); if (row) selectAutomation(row.dataset.auRow); return; }
  const d = automations.detail;
  const slug = node.dataset.slug || (d && d.slug);
  const run = (verb, body = {}) => automationJob(verb, { slug, ...body }, `automation-${slug}`);
  switch (node.dataset.au) {
    case "refresh": refreshAutomations(); break;
    case "new": automations.creating = !automations.creating; renderAutomations(); if (automations.creating) $("#au-new-title").focus(); break;
    case "create": createAutomation(); break;
    case "toggle": e.stopPropagation(); run(node.dataset.enabled === "true" ? "pause" : "resume"); break;
    case "adopt": {
      const project = $(`#au-body [data-adopt-project="${CSS.escape(node.dataset.id)}"]`).value;
      if (!project) { toast("pick the project this automation concerns", false); break; }
      automationJob("adopt", { id: node.dataset.id, project }, `automation-adopt-${node.dataset.id}`);
      break;
    }
    case "day": {
      const edit = automationEdit(true);
      const day = Number(node.dataset.day);
      edit.days = edit.days.includes(day) ? edit.days.filter(x => x !== day) : edit.days.concat(day);
      renderAutomations(); break;
    }
    case "raw": { const edit = automationEdit(true); edit.raw = !edit.raw; renderAutomations(); break; }
    case "apply": applyAutomation(); break;
    case "discard": delete automations.edits[slug]; renderAutomations(); break;
    case "pull": run("pull"); break;
    case "push": run("push"); break;
    case "force-push": run("push", { force: true }); break;
    case "run": run("run"); break;
    case "chat": openAutomationChat(slug); break;
    case "ask-delete": automations.confirmDelete = slug; renderAutomations(); break;
    case "cancel-delete": automations.confirmDelete = null; renderAutomations(); break;
    case "delete": automations.confirmDelete = null; run("delete"); break;
  }
});

$("#au-body").addEventListener("input", e => {
  const t = e.target;
  if (!t.dataset.auField) return;
  const edit = automationEdit(true);
  edit[t.dataset.auField] = t.value;
  const bar = $("#au-apply-bar");
  if (bar) bar.innerHTML = automationApplyBar();
});
