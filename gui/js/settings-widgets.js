"use strict";

/* ------- Settings view: one widget per schema type ------- */
/* A field is drawn from its schema key (GET /api/settings' schema) and the
   draft's value at a concrete path (an array of segments: project names may
   hold anything). Every widget's control carries data-path (the JSON path)
   and data-widget, which settings.js's delegated listeners read. A test
   (tests/gui_settings.rs) reads SETTINGS_WIDGETS' keys and checks every schema type has a widget, so
   keep one type per line. */
const SETTINGS_WIDGETS = {
  string: (path, value, key) => settingsInput(path, value, key, ""),
  path: (path, value, key) => settingsInput(path, value, key, "mono"),
  text: (path, value) =>
    `<textarea class="st-in mono" rows="3" ${settingsAttrs(path, "text")}>${esc(value == null ? "" : value)}</textarea>`,
  bool: (path, value) =>
    `<label class="st-toggle"><input type="checkbox" ${value ? "checked" : ""} ${settingsAttrs(path, "bool")}> ${value ? "on" : "off"}</label>`,
  number: (path, value, key) =>
    `<input class="st-in mono st-num" inputmode="decimal" value="${esc(value == null ? "" : value)}" placeholder="${esc(settingsPlaceholder(path, key))}" ${settingsAttrs(path, "number")}>`,
  string_list: (path, value) => settingsChips(path, value, false),
  argv: (path, value) => settingsChips(path, value, true),
  enum: (path, value, key) => settingsSelect(path, value, key),
};

const settingsAttrs = (path, widget) => `data-path="${esc(JSON.stringify(path))}" data-widget="${widget}"`;

function settingsInput(path, value, key, cls) {
  return `<input class="st-in ${cls}" value="${esc(value == null ? "" : value)}" placeholder="${esc(settingsPlaceholder(path, key))}" ${settingsAttrs(path, "string")}>`;
}

/* What an unset field falls back to, as its placeholder: the key it inherits
   (a project's IDE from the global one) or its default. */
function settingsPlaceholder(path, key) {
  if (key.inherits) {
    const inherited = settingsGet(key.inherits.split("."));
    if (inherited != null && inherited !== "") return `${Array.isArray(inherited) ? inherited.join(" ") : inherited} (global)`;
  }
  return key.default != null ? `${key.default} (default)` : "";
}

/* A chip list: Enter adds what was typed, Backspace in the empty box removes
   the last chip, × removes one. An argv highlights its PATH chip and shows
   the command it runs under a field. */
function settingsChips(path, value, argv) {
  const list = Array.isArray(value) ? value : [];
  const chips = list.map((x, i) =>
    `<span class="st-chip${argv && String(x).includes("PATH") ? " ph" : ""}">${esc(x)}` +
    `<button type="button" data-chip="${i}" title="Remove">×</button></span>`).join("");
  let html = `<div class="st-chips" ${settingsAttrs(path, "chips")}>${chips}` +
    `<input class="st-chip-in" placeholder="${argv ? "add an argument, ⏎" : "add, ⏎"}" ${settingsAttrs(path, "chips")}></div>`;
  if (argv && list.length) {
    const root = path[0] === "projects" ? settingsGet(["projects", path[1], "root"]) : settingsFirstRoot();
    html += `<div class="st-preview">→ ${esc(list.map(x => String(x).replace("PATH", root || "~/code/example")).join(" "))}</div>`;
  }
  return html;
}

function settingsFirstRoot() {
  const projects = settingsGet(["projects"]) || {};
  const first = Object.values(projects)[0];
  return first && first.root;
}

/* An enum's options are its fixed options, or the values its options_from
   names: a sibling list (a dev server's modes) or a map's keys (the project
   names). A value not among them is still shown, so the check's error points
   at something. */
function settingsEnumOptions(path, key) {
  if (key.options) return key.options.slice();
  const concrete = key.options_from.split(".").map((seg, i) => seg === "*" ? path[i] : seg);
  const source = settingsGet(concrete);
  return Array.isArray(source) ? source.map(String) : Object.keys(source || {});
}

function settingsSelect(path, value, key) {
  const options = settingsEnumOptions(path, key);
  if (value != null && value !== "" && !options.includes(String(value))) options.push(String(value));
  const none = key.options ? "(off)" : key.path === "default_project" ? "(the first project)" : "(the first mode)";
  return `<select class="st-in" ${settingsAttrs(path, "enum")}><option value="">${none}</option>` +
    options.map(o => `<option${o === String(value) ? " selected" : ""}>${esc(o)}</option>`).join("") + `</select>`;
}

/* The label a key shows: its last segment as words, the first capitalised
   and acronyms in capitals. */
const SETTINGS_ACRONYMS = { ide: "IDE", db: "DB", pr: "PR", url: "URL", api: "API" };
function settingsLabel(key) {
  const words = key.path.split(".").pop().split("_").map(w => SETTINGS_ACRONYMS[w] || w);
  const text = words.join(" ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/* One field row: label (with the key's dotted name), widget, help, and the
   check's messages for exactly this path. */
function settingsField(key, path) {
  const dotted = path.join(".");
  const mine = settings.issues.filter(i => i.path === dotted);
  const widget = SETTINGS_WIDGETS[key.type] || SETTINGS_WIDGETS.string;
  const cls = ["st-fld", settingsDirty(path) && "dirty", mine.some(i => i.level === "error") && "has-error",
               mine.length && !mine.some(i => i.level === "error") && "has-warning"].filter(Boolean).join(" ");
  const shown = key.path.replace(/^projects\.\*\./, "").replace(/^(loose_starters|prices)\.\*\./, "");
  return `<div class="${cls}" data-field="${esc(dotted)}">` +
    `<label>${esc(settingsLabel(key))}<code>${esc(shown)}</code></label>` +
    `<div class="st-ctl">${widget(path, settingsGet(path), key)}</div>` +
    (key.help ? `<div class="st-help">${esc(key.help)}</div>` : "") +
    mine.map(i => `<div class="st-msg ${i.level}">${i.level === "error" ? "✕" : "⚠"} ${esc(i.message)}</div>`).join("") +
    `</div>`;
}

/* The API prices: every model qm prices by default plus the ones the file
   adds, five number cells each; qm's default shows grey as a placeholder,
   a filled cell is an override, and only overrides are written. */
function settingsPrices() {
  const defaults = settings.payload.priceDefaults || {};
  const fields = settingsSchemaKeys("prices.*.").map(k => k.path.split(".").pop());
  const draft = settingsGet(["prices"]) || {};
  const models = [...new Set([...Object.keys(defaults), ...Object.keys(draft)])];
  const head = `<tr><th>model</th>${fields.map(f => `<th>${esc(f.replace(/_/g, " "))}</th>`).join("")}<th></th></tr>`;
  const rows = models.map(m => {
    const custom = !defaults[m];
    const cells = fields.map(f => {
      const path = ["prices", m, f];
      const v = draft[m] && draft[m][f];
      const bad = settings.issues.some(i => i.path === path.join("."));
      const def = defaults[m] && defaults[m][f];
      return `<td data-field="${esc(path.join("."))}" class="${bad ? "has-error" : ""}">` +
        `<input class="mono" inputmode="decimal" value="${esc(v == null ? "" : v)}" placeholder="${esc(def == null ? "—" : def)}" ${settingsAttrs(path, "number")}></td>`;
    }).join("");
    const remove = custom ? `<button type="button" class="st-x" data-remove="${esc(JSON.stringify(["prices", m]))}" title="Remove this model">×</button>` : "";
    return `<tr class="${custom ? "custom" : ""}" data-field="${esc(`prices.${m}`)}"><td>${esc(m)}</td>${cells}<td>${remove}</td></tr>`;
  }).join("");
  return `<p class="st-sub">USD per million tokens. Grey numbers are qm's defaults; type to override a cell, clear it to go back.</p>` +
    `<div class="st-prices-scroll"><table class="st-prices">${head}${rows}</table></div>` +
    settingsAddRow("prices", "model key, e.g. claude-foo-1", "Add model");
}

/* An inline "add" row: a name box and a button, for a map's new entry. */
function settingsAddRow(map, placeholder, label) {
  return `<div class="st-add"><input class="st-in mono" data-add-name="${map}" placeholder="${esc(placeholder)}">` +
    `<button type="button" class="btn" data-add="${map}">${esc(label)}</button></div>`;
}
