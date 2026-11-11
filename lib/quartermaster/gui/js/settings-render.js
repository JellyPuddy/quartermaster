"use strict";

/* ------- Settings view: the page (projects × features grid, the document, the side column) ------- */
/* Drawn from the schema payload: which keys a section holds, their order and
   which go in a "More" fold all come from ConfigSchema; only the sections'
   titles and order live here. Folds (project cards, More, Rarely changed)
   are <details data-fold> whose open state settingsFolds keeps across renders
   (settings.js updates it on every toggle). */
const SETTINGS_PROJECT_SECTIONS = [["basics", "Basics"], ["dev_server", "Dev server"], ["worktrees", "Worktrees"],
  ["pull_requests", "Pull requests"], ["epics", "Epics from issues"], ["issue_links", "Links from issues"], ["ide", "IDE override"], ["benchmarks", "Benchmarks"]];
const SETTINGS_FEATURES = { dev_server: ["dev server", "dev_server"], test_db: ["test db", "worktrees"],
  review: ["review", "pull_requests"], ships_by_release: ["ships by release", "pull_requests"],
  benchmarks: ["benchmarks", "benchmarks"], ide: ["IDE", "ide"] };
const settingsFolds = new Set();

const settingsOpen = key => settingsFolds.has(key) ? " open" : "";
const settingsSchemaKeys = prefix => settings.payload.schema.keys.filter(k => k.path.startsWith(prefix));
const settingsProjectNames = () => Object.keys(settingsGet(["projects"]) || {});
const settingsCount = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

/* The theme lives in the browser, not config.yml: it applies at once and is
   outside Save, Revert and the Check. */
function settingsTheme() {
  const now = themeChoice();
  return `<div class="segmented st-theme" role="group" aria-label="Theme">` +
    [["system", "System"], ["light", "Light"], ["dark", "Dark"]].map(([k, label]) =>
      `<button type="button" data-theme-choice="${k}" aria-pressed="${now === k}">${label}</button>`).join("") + `</div>`;
}

function settingsPage() {
  const s = settings;
  if (!s.payload) return `<div class="col-empty">${esc(s.error || "loading…")}</div>`;
  const head = `<div class="st-head"><h2>Settings</h2><span class="st-file" title="Every save rewrites this file in qm's layout; the previous one is kept as config.yml.bak">${esc(s.payload.path)}</span>${settingsTheme()}</div>`;
  if (s.broken) {
    return `${head}<div class="st-card st-broken"><b>config.yml doesn't parse</b>, so the form can't show it and saving would overwrite it.` +
      `<div class="st-msg error">✕ ${esc(s.broken)}</div><p class="st-sub">Fix the file by hand (or <code>qm config</code>), then reopen Settings.</p></div>`;
  }
  const names = settingsProjectNames();
  const grid = names.length ? `<div class="st-matrix">${settingsMatrix(names)}</div>` : "";
  const doc = `<div class="st-doc">${settingsGlobal("general", "General")}${settingsGlobal("ide", "IDE")}` +
    `<div class="st-group">Projects</div>${names.map(settingsProject).join("")}${settingsAddProject(names.length)}` +
    `<details class="st-rare" data-fold="rare" data-anchor="#rare"${settingsOpen("rare")}>` +
    `<summary>Rarely changed: loose-chat starters, API prices, phone page</summary><div class="st-rare-body">` +
    `${settingsGlobal("starters", "Loose-chat starters")}${settingsGlobal("prices", "API prices")}${settingsGlobal("phone", "Phone page")}` +
    `</div></details></div>`;
  return `${head}${grid}${doc}<aside class="st-side">${settingsSaveBox()}${settingsToc(names)}</aside>`;
}

/* ------- the projects × features grid ------- */
function settingsMatrix(names) {
  const features = settings.payload.schema.features;
  const th = features.map(f => `<th>${esc((SETTINGS_FEATURES[f] || [f])[0])}</th>`).join("");
  const rows = names.map(name => {
    const cells = (settings.features[name] || {});
    const root = settingsGet(["projects", name, "root"]);
    const tds = features.map(f => {
      const cell = cells[f] || { state: "off" };
      const label = cell.state === "off" ? "off" : (cell.value || cell.state);
      return `<td data-project="${esc(name)}" data-section="${(SETTINGS_FEATURES[f] || [])[1] || "basics"}">` +
        `<span class="st-feat ${esc(cell.state)}" title="${esc(cell.title || "")}">${esc(label)}</span></td>`;
    }).join("");
    const errors = settingsIssuesUnder(["projects", name]).filter(i => i.level === "error").length;
    const flag = errors ? ` <span class="st-bad" title="${settingsCount(errors, "error")}">✕</span>` : "";
    return `<tr><td class="st-name" data-project="${esc(name)}">${esc(name)}${settingsProjectDirty(name) ? ' <span class="st-dot">●</span>' : ""}${flag}` +
      `<small>${esc(root || "no root")}</small></td>${tds}<td class="st-items" data-project="${esc(name)}" data-section="basics">${settings.payload.items[name] || 0}</td></tr>`;
  }).join("");
  return `<table><tr><th>project</th>${th}<th>items</th></tr>${rows}</table>`;
}

/* ------- the document ------- */
function settingsGlobal(section, title) {
  let body;
  if (section === "prices") body = settingsPrices();
  else if (section === "starters") body = settingsStarters();
  else body = settingsFields(settings.payload.schema.keys.filter(k => !k.path.includes("*") && k.section === section), []);
  return `<section class="st-card" data-anchor="#${section}"><h3>${esc(title)}</h3>${body}</section>`;
}

/* A key list's fields, the collapsed (rarely changed) ones in a More fold. */
function settingsFields(keys, base, fold) {
  const concrete = k => base.concat(k.path.split(".").slice(base.length));
  const common = keys.filter(k => !k.collapsed);
  const rare = keys.filter(k => k.collapsed);
  let html = common.map(k => settingsField(k, concrete(k))).join("");
  if (rare.length && common.length) {
    const set = rare.some(k => settingsGet(concrete(k)) != null);
    html += `<details class="st-more" data-fold="${esc(fold)}"${settingsOpen(fold)}><summary>More: ` +
      `${esc(rare.map(settingsLabel).join(", ").toLowerCase())}${set ? " · set" : ""}</summary>` +
      `${rare.map(k => settingsField(k, concrete(k))).join("")}</details>`;
  } else html += rare.map(k => settingsField(k, concrete(k))).join("");
  return html;
}

function settingsProject(name) {
  const base = ["projects", name];
  const errors = settingsIssuesUnder(base).filter(i => i.level === "error").length;
  const warnings = settingsIssuesUnder(base).filter(i => i.level === "warning").length;
  const keys = settingsSchemaKeys("projects.*.");
  const sections = SETTINGS_PROJECT_SECTIONS.map(([sec, title]) => {
    const mine = keys.filter(k => k.section === sec);
    if (!mine.length) return "";
    const anchor = `projects.${name}#${sec}`;
    const fold = `project:${name}:${sec}`;
    if (mine.every(k => k.collapsed)) {
      const set = mine.some(k => settingsGet(base.concat(k.path.split(".").slice(2))) != null);
      return `<details class="st-more st-sec" data-fold="${esc(fold)}" data-anchor="${esc(anchor)}"${settingsOpen(fold)}>` +
        `<summary>${esc(title)}${set ? " · set" : ""}</summary>${settingsFields(mine, base, fold)}</details>`;
    }
    return `<section class="st-sec" data-anchor="${esc(anchor)}"><h4>${esc(title)}</h4>${settingsFields(mine, base, `${fold}:more`)}</section>`;
  }).join("");
  const fold = `project:${name}`;
  const badges = (errors ? `<span class="st-feat error">${settingsCount(errors, "error")}</span>` : "") +
    (warnings ? `<span class="st-feat warning">${settingsCount(warnings, "warning")}</span>` : "");
  return `<details class="st-card st-proj" data-fold="${esc(fold)}" data-anchor="${esc(`projects.${name}`)}"${settingsOpen(fold)}>` +
    `<summary><h3>${esc(name)}${settingsProjectDirty(name) ? ' <span class="st-dot" title="unsaved changes">●</span>' : ""}</h3>${badges}` +
    `<span class="st-sub mono">${esc(settingsGet([...base, "root"]) || "no root")} · ${settingsCount(settings.payload.items[name] || 0, "item")}</span></summary>` +
    `${sections}<div class="st-remove">${settingsRemoveProject(name)}</div></details>`;
}

/* Removing a project says how many work items name it: they keep the name
   but lose its root and features. Renaming is remove + add. */
function settingsRemoveProject(name) {
  if (settingsUi.confirmRemove !== name) return `<button type="button" class="st-danger" data-ask-remove="${esc(name)}">Remove project…</button>`;
  const n = settings.payload.items[name] || 0;
  const what = n ? `<b>${settingsCount(n, "work item")}</b> use “${esc(name)}”: they keep the name but lose its root and features.`
                 : `No work items use “${esc(name)}”.`;
  return `<div class="st-confirm"><span>${what}</span><button type="button" class="act" data-remove="${esc(JSON.stringify(["projects", name]))}">Remove</button>` +
    `<button type="button" class="act" data-ask-remove="">Cancel</button></div>`;
}

function settingsAddProject(count) {
  if (!settingsUi.adding && count) return `<button type="button" class="st-ghost" data-adding="1">+ Add project</button>`;
  return `<div class="st-card st-new">${count ? "" : `<h3>Add your first project</h3><p class="st-sub">A project is a repo qm knows: sessions in it or its worktrees get its name, and its dev server, test DB and review skill drive the buttons.</p>`}` +
    `<div class="st-fld"><label>Name<code>projects.&lt;name&gt;</code></label><div class="st-ctl"><input class="st-in" id="st-new-name" placeholder="my-app"></div>` +
    `<div class="st-help">Can't be renamed later: work items store it.</div></div>` +
    `<div class="st-fld"><label>Repo root<code>root</code></label><div class="st-ctl"><input class="st-in mono" id="st-new-root" placeholder="~/code/my-app"></div></div>` +
    `<div class="st-add"><button type="button" class="btn primary" data-add="project">Add project</button>` +
    (count ? `<button type="button" class="btn" data-adding="">Cancel</button>` : "") + `</div></div>`;
}

function settingsStarters() {
  const starters = settingsGet(["loose_starters"]) || {};
  const keys = settingsSchemaKeys("loose_starters.*.");
  return Object.keys(starters).map(name =>
    `<div class="st-entry" data-field="${esc(`loose_starters.${name}`)}"><div class="st-entry-head"><b class="mono">${esc(name)}</b>` +
    `<button type="button" class="st-danger" data-remove="${esc(JSON.stringify(["loose_starters", name]))}">Remove</button></div>` +
    `${settingsFields(keys, ["loose_starters", name], `starter:${name}`)}</div>`).join("") +
    settingsAddRow("loose_starters", "starter key, e.g. backlog", "Add starter");
}

/* ------- the side column: save, the check, the table of contents ------- */
function settingsSaveBox() {
  const s = settings;
  const changed = settingsChanges().length;
  const errors = s.issues.filter(i => i.level === "error");
  const blocked = !changed || errors.length || s.saving;
  const why = errors.length ? "Fix the errors below first" : !changed ? "Nothing to save" : "Write config.yml (⌘S)";
  const status = s.saving ? "saving…" : changed ? `<span class="st-dot">●</span> ${settingsCount(changed, "unsaved change")}` : "All saved";
  const issues = s.issues.length
    ? `<div class="st-issues">${s.issues.map(settingsIssueRow).join("")}</div>`
    : `<span class="st-sub">${s.checking ? "checking…" : "✓ qm understands every setting."}</span>`;
  return `<div class="st-box st-save"><div class="st-row st-sub">${status}</div>` +
    `<div class="st-row"><button type="button" class="btn primary" data-save="1"${blocked ? " disabled" : ""} title="${esc(why)}">Save <kbd>⌘S</kbd></button>` +
    `<button type="button" class="btn" data-revert="1"${changed ? "" : " disabled"}>Revert</button></div>` +
    `<div class="st-title">Check${s.checking && s.issues.length ? " · checking…" : ""}</div>${issues}</div>`;
}

/* A key qm doesn't know (a typo under a project) can't be fixed in a field,
   so its issue offers to drop it. */
function settingsIssueRow(issue) {
  const path = issue.path ? issue.path.split(".") : [];
  const unknown = issue.level === "error" && path.length && !settingsKnown(path) && settingsGet(path) !== undefined;
  const drop = unknown ? `<button type="button" class="st-danger" data-remove="${esc(JSON.stringify(path))}">Remove key</button>` : "";
  return `<div class="st-issue ${esc(issue.level)}"><button type="button" class="st-jump" data-jump="${esc(issue.path)}">` +
    `<b>${esc(issue.level)}</b><span>${esc(issue.message)}<br><code>${esc(issue.path || "config.yml")}</code></span></button>${drop}</div>`;
}

function settingsToc(names) {
  const link = (anchor, label, cls = "") => `<a href="#" class="${cls}" data-goto="${esc(anchor)}">${esc(label)}</a>`;
  const globalDirty = ["default_project", "ide_command", "ide_label"].some(k => settingsDirty([k]));
  return `<nav class="st-box st-toc"><div class="st-title">On this page</div>${link("#general", "General & IDE", globalDirty ? "dirty" : "")}` +
    names.map(n => link(`projects.${n}`, n, settingsProjectDirty(n) ? "dirty" : "")).join("") +
    link("#rare", "Rarely changed…", "rare") + `</nav>`;
}
