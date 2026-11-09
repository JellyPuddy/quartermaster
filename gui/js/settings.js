"use strict";

/* ------- Settings view: edit config.yml (GET /api/settings, POST /api/settings/check|save) ------- */
/* The page never validates: every edit posts the draft to check (debounced)
   and draws the issues and the grid's cells the server answers. Save posts
   the draft with the digest it was loaded at; a file changed since is
   refused as stale and the page reloads it. The draft lives across mode
   switches, so leaving the view loses nothing. */
let settings = { payload: null, draft: null, issues: [], features: {}, error: null, broken: null,
                 checking: false, saving: false };
const settingsUi = { adding: false, confirmRemove: null };
let settingsCheckTimer = null;
let settingsCheckSeq = 0;

const settingsClone = v => JSON.parse(JSON.stringify(v == null ? {} : v));
const settingsSame = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function settingsGet(path, from = settings.draft) {
  return path.reduce((at, k) => (at == null || typeof at !== "object" ? undefined : at[k]), from);
}

/* Set a value at a path, creating mappings on the way. An unset value (blank
   text, an empty list, null) removes the key, and the emptied mappings above
   it, down to a map's entry (a project, a starter, a model), which stays. */
function settingsSet(path, value) {
  const blank = value == null || value === "" || (Array.isArray(value) && !value.length);
  let at = settings.draft;
  for (const k of path.slice(0, -1)) {
    if (at[k] == null || typeof at[k] !== "object" || Array.isArray(at[k])) { if (blank) return; at[k] = {}; }
    at = at[k];
  }
  if (!blank) { at[path[path.length - 1]] = value; return; }
  delete at[path[path.length - 1]];
  for (let n = path.length - 1; n > 2; n--) {
    const parent = settingsGet(path.slice(0, n - 1));
    const child = parent && parent[path[n - 1]];
    if (child && typeof child === "object" && !Object.keys(child).length) delete parent[path[n - 1]];
    else break;
  }
  if (path[0] === "prices") settingsDropEmptyDefaultPrice(path[1]);
}

/* A model qm prices by default keeps its row without an entry, so clearing
   its last override drops the entry (and an emptied prices:) instead of
   leaving an empty mapping that counts as a change. */
function settingsDropEmptyDefaultPrice(model) {
  const prices = settings.draft.prices;
  if (!prices || !(settings.payload.priceDefaults || {})[model]) return;
  if (prices[model] && !Object.keys(prices[model]).length) delete prices[model];
  if (!Object.keys(prices).length) delete settings.draft.prices;
}

function settingsRemove(path) {
  const parent = settingsGet(path.slice(0, -1));
  if (parent && typeof parent === "object") delete parent[path[path.length - 1]];
}

/* Every leaf path where the draft and the loaded file differ. */
function settingsChanges() {
  if (!settings.payload || !settings.draft) return [];
  const out = [];
  const walk = (a, b, path) => {
    const map = v => v && typeof v === "object" && !Array.isArray(v);
    if (map(a) && map(b)) new Set([...Object.keys(a), ...Object.keys(b)]).forEach(k => walk(a[k], b[k], [...path, k]));
    else if (!settingsSame(a, b)) out.push(path.join("."));
  };
  walk(settings.draft, settings.payload.config, []);
  return out;
}
const settingsUnder = (dotted, prefix) => dotted === prefix || dotted.startsWith(prefix + ".");
const settingsDirty = path => settingsChanges().some(c => settingsUnder(c, path.join(".")) || settingsUnder(path.join("."), c));
const settingsProjectDirty = name => settingsDirty(["projects", name]);
const settingsIssuesUnder = path => settings.issues.filter(i => settingsUnder(i.path || "", path.join(".")));

function settingsMatch(pattern, path) {
  const want = pattern.split(".");
  return want.length === path.length && want.every((w, i) => w === "*" || w === path[i]);
}
function settingsKnown(path) {
  const schema = settings.payload.schema;
  return schema.keys.some(k => settingsMatch(k.path, path)) || Object.keys(schema.containers).some(c => settingsMatch(c, path));
}

/* ------- loading, checking, saving ------- */
function settingsTake(payload) {
  settings.payload = payload;
  settings.draft = settingsClone(payload.config);
  settings.issues = payload.issues || [];
  settings.features = payload.features || {};
  const parse = settings.issues.find(i => i.level === "error" && !i.path);
  settings.broken = parse ? parse.message : null;
  settings.error = null;
  settingsUi.confirmRemove = null;
}

async function loadSettings() {
  try {
    const r = await fetch("/api/settings");
    settingsTake(await r.json());
  } catch (e) { settings.error = "could not reach qm"; }
  renderSettings();
}

/* The header cog, `,` and Esc toggle the view; leaving returns to the mode it was opened from. */
let settingsReturnMode = "board";
function toggleSettings() { setMode(mode === "settings" ? settingsReturnMode : "settings"); }

/* Opening the view reloads the file unless the draft holds unsaved edits. */
function openSettings() {
  renderSettings();
  if (!settings.payload || !settingsChanges().length) loadSettings();
}

function scheduleSettingsCheck() {
  clearTimeout(settingsCheckTimer);
  settings.checking = true;
  settingsCheckTimer = setTimeout(checkSettings, 300);
}

async function checkSettings() {
  const seq = ++settingsCheckSeq;
  let res;
  try {
    const r = await fetch("/api/settings/check", { method: "POST", headers: { "Content-Type": "application/json" },
                                                    body: JSON.stringify({ config: settings.draft }) });
    res = await r.json();
  } catch (e) { res = null; }
  if (seq !== settingsCheckSeq) return; // a newer edit's check is on its way
  settings.checking = false;
  if (res && res.issues) { settings.issues = res.issues; settings.features = res.features || {}; }
  else toast("could not check the settings — is qm still running?", false);
  renderSettings();
}

async function saveSettings() {
  const s = settings;
  if (!s.payload || s.broken || s.saving || !settingsChanges().length || s.issues.some(i => i.level === "error")) return;
  clearTimeout(settingsCheckTimer);
  settingsCheckSeq++;
  s.saving = true;
  renderSettings();
  let r, res;
  try {
    r = await fetch("/api/settings/save", { method: "POST", headers: { "Content-Type": "application/json" },
                                             body: JSON.stringify({ config: s.draft, digest: s.payload.digest }) });
    res = await r.json();
  } catch (e) { res = { ok: false, error: "could not reach qm" }; }
  s.saving = false;
  s.checking = false;
  if (res.ok) {
    settingsTake(res.settings);
    if (res.state) applyState(res.state);
    toast("Saved config.yml");
  } else if (res.stale) {
    settingsTake(res.settings);
    toast("config.yml changed on disk since you opened it: reloaded it, your edits were dropped", false);
  } else {
    if (res.issues) { s.issues = res.issues; s.features = res.features || s.features; }
    toast(res.error || "saving failed", false);
  }
  renderSettings();
}

function revertSettings() {
  settings.draft = settingsClone(settings.payload.config);
  settingsUi.confirmRemove = null;
  scheduleSettingsCheck();
  renderSettings();
}

/* ------- rendering ------- */
/* A full redraw keeps the scroll, the open folds, the caret of the field
   being typed in and what is typed in the add rows (which aren't the draft's). */
const SETTINGS_ADD_BOXES = "#st-new-name, #st-new-root, [data-add-name]";
const settingsAddBoxKey = node => node.id ? `#${CSS.escape(node.id)}` : `[data-add-name="${CSS.escape(node.dataset.addName)}"]`;

function renderSettings() {
  if (mode !== "settings") return;
  const body = $("#st-body");
  const active = document.activeElement;
  const typed = [...body.querySelectorAll(SETTINGS_ADD_BOXES)].filter(n => n.value).map(n => [settingsAddBoxKey(n), n.value]);
  const focus = !active || !body.contains(active) ? null
    : active.dataset.path ? { path: active.dataset.path, widget: active.dataset.widget, at: active.selectionStart }
    : active.matches(SETTINGS_ADD_BOXES) ? { box: settingsAddBoxKey(active), at: active.selectionStart } : null;
  keepScroll($(".st-wrap"), () => { body.innerHTML = settingsPage(); });
  typed.forEach(([key, value]) => { const n = body.querySelector(key); if (n) n.value = value; });
  if (!focus) return;
  const again = focus.path ? body.querySelector(`[data-path="${CSS.escape(focus.path)}"]${focus.widget === "chips" ? ".st-chip-in" : ""}`)
                           : body.querySelector(focus.box);
  if (!again) return;
  again.focus({ preventScroll: true });
  try { if (focus.at != null) again.setSelectionRange(focus.at, focus.at); } catch (e) { /* not a text control */ }
}

/* Typing redraws only the side column (the change count); the check's answer
   redraws the rest. */
function renderSettingsSide() {
  const side = $("#st-body .st-side");
  if (side) side.innerHTML = settingsSaveBox() + settingsToc(settingsProjectNames());
}

/* Open a project's card (and the fold holding `section`), then scroll there
   and flash it: the grid's names and cells, the table of contents. */
function openSettingsAnchor(anchor) {
  const project = anchor.match(/^projects\.(.+?)(?:#(\w+))?$/);
  if (project && !anchor.startsWith("#")) {
    settingsFolds.add(`project:${project[1]}`);
    if (project[2]) settingsFolds.add(`project:${project[1]}:${project[2]}`);
  }
  if (anchor === "#rare") settingsFolds.add("rare");
  renderSettings();
  const node = $(`#st-body [data-anchor="${CSS.escape(anchor)}"]`);
  if (node) settingsReveal(node, !!(project && project[2]));
}

/* An issue's path: the field itself, else the nearest thing above it shown. */
function jumpToSettingsIssue(dotted) {
  const path = dotted ? dotted.split(".") : [];
  if (path[0] === "projects" && path[1]) settingsFolds.add(`project:${path[1]}`);
  if (["loose_starters", "prices", "overview_artifact"].includes(path[0])) settingsFolds.add("rare");
  renderSettings();
  for (let n = path.length; n > 0; n--) {
    const at = path.slice(0, n).join(".");
    const node = $(`#st-body [data-field="${CSS.escape(at)}"]`) || $(`#st-body [data-anchor="${CSS.escape(at)}"]`);
    if (node) return settingsReveal(node, true);
  }
}

function settingsReveal(node, flash) {
  for (let d = node.closest("details"); d; d = d.parentElement.closest("details")) d.open = true;
  if (node.tagName === "DETAILS") node.open = true;
  node.scrollIntoView({ block: flash ? "center" : "start" });
  if (flash) { node.classList.remove("st-flash"); void node.offsetWidth; node.classList.add("st-flash"); }
}

/* ------- events ------- */
const settingsPathOf = node => JSON.parse(node.dataset.path);

function settingsEdited(node, value, redraw) {
  settingsSet(settingsPathOf(node), value);
  scheduleSettingsCheck();
  if (redraw) renderSettings();
  else { node.closest(".st-fld, td")?.classList.add("dirty"); renderSettingsSide(); }
}

function settingsNumber(text) {
  const t = text.trim();
  return /^-?(\d+\.?\d*|\.\d+)$/.test(t) ? Number(t) : t; // anything else goes to the check as typed
}

$("#st-body").addEventListener("input", e => {
  const node = e.target;
  if (!node.dataset || !node.dataset.path) return;
  if (node.dataset.widget === "string" || node.dataset.widget === "text") settingsEdited(node, node.value.trim() ? node.value : "", false);
  else if (node.dataset.widget === "number") settingsEdited(node, settingsNumber(node.value), false);
});

$("#st-body").addEventListener("change", e => {
  const node = e.target;
  if (!node.dataset || !node.dataset.path) return;
  if (node.dataset.widget === "bool") settingsEdited(node, node.checked || null, true);
  else if (node.dataset.widget === "enum") settingsEdited(node, node.value, true);
});

$("#st-body").addEventListener("keydown", e => {
  const node = e.target;
  if (node.classList.contains("st-chip-in")) {
    const path = settingsPathOf(node);
    const list = (settingsGet(path) || []).slice();
    if (e.key === "Enter" && !e.isComposing && node.value.trim()) {
      e.preventDefault();
      settingsSet(path, list.concat(node.value.trim()));
      node.value = "";
      scheduleSettingsCheck(); renderSettings();
    } else if (e.key === "Backspace" && !node.value && list.length) {
      e.preventDefault();
      settingsSet(path, list.slice(0, -1));
      scheduleSettingsCheck(); renderSettings();
    }
  } else if (e.key === "Enter" && node.dataset.addName) { e.preventDefault(); settingsAdd(node.dataset.addName); }
  else if (e.key === "Enter" && (node.id === "st-new-name" || node.id === "st-new-root")) { e.preventDefault(); settingsAdd("project"); }
});

$("#st-body").addEventListener("click", e => {
  const t = e.target;
  const hit = sel => t.closest(sel);
  let node;
  if ((node = hit("[data-chip]"))) {
    const holder = node.closest(".st-chips");
    const path = settingsPathOf(holder);
    const list = (settingsGet(path) || []).slice();
    list.splice(Number(node.dataset.chip), 1);
    settingsSet(path, list); scheduleSettingsCheck(); renderSettings();
  } else if ((node = hit(".st-chips")) && t === node) node.querySelector(".st-chip-in").focus();
  else if ((node = hit("td[data-project], td.st-name"))) {
    openSettingsAnchor(`projects.${node.dataset.project}${node.dataset.section ? "#" + node.dataset.section : ""}`);
  } else if ((node = hit("[data-goto]"))) { e.preventDefault(); openSettingsAnchor(node.dataset.goto); }
  else if ((node = hit("[data-jump]"))) jumpToSettingsIssue(node.dataset.jump);
  else if ((node = hit("[data-save]"))) saveSettings();
  else if ((node = hit("[data-revert]"))) revertSettings();
  else if ((node = hit("[data-ask-remove]"))) { settingsUi.confirmRemove = node.dataset.askRemove || null; renderSettings(); }
  else if ((node = hit("[data-remove]"))) {
    settingsRemove(JSON.parse(node.dataset.remove));
    settingsUi.confirmRemove = null;
    scheduleSettingsCheck(); renderSettings();
  } else if ((node = hit("[data-adding]"))) { settingsUi.adding = !!node.dataset.adding; renderSettings(); $("#st-new-name")?.focus(); }
  else if ((node = hit("[data-add]"))) settingsAdd(node.dataset.add);
});

/* A new map entry: a project needs a name and its root (the name can't
   change later), a starter or a model just its key. */
function settingsAdd(map) {
  if (map === "project") {
    const name = $("#st-new-name").value.trim();
    const root = $("#st-new-root").value.trim();
    if (!name || !root) { toast("a project needs a name and its repo root", false); return; }
    if (settingsGet(["projects", name])) { toast(`there is already a project called ${name}`, false); return; }
    settings.draft.projects = settings.draft.projects || {};
    settings.draft.projects[name] = { root };
    settingsUi.adding = false;
    scheduleSettingsCheck();
    openSettingsAnchor(`projects.${name}`);
    return;
  } else {
    const box = $(`#st-body [data-add-name="${map}"]`);
    const key = box.value.trim();
    if (!key) return;
    if (settingsGet([map, key])) { toast(`${key} is already there`, false); return; }
    settings.draft[map] = settings.draft[map] || {};
    settings.draft[map][key] = {};
    box.value = "";
  }
  scheduleSettingsCheck();
  renderSettings();
}

/* A fold's open state is remembered as the user (or a jump) toggles it, so a
   redraw draws it the same; toggle doesn't bubble, hence the capture. */
$("#st-body").addEventListener("toggle", e => {
  const d = e.target;
  if (!d.dataset || !d.dataset.fold) return;
  if (d.open) settingsFolds.add(d.dataset.fold); else settingsFolds.delete(d.dataset.fold);
}, true);

/* ⌘S saves wherever focus is, inputs included. */
document.addEventListener("keydown", e => {
  if (mode !== "settings" || !(e.metaKey || e.ctrlKey) || e.key !== "s") return;
  e.preventDefault();
  saveSettings();
});
window.addEventListener("beforeunload", e => { if (settingsChanges().length) { e.preventDefault(); e.returnValue = ""; } });
