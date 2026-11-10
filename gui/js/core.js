"use strict";

let items = [];
let inbox = [];
let PROJECTS = ["No project"];
let DEFAULT_PROJECT = null; // config.yml's default_project (else its first project): where a bare #123 starts
let LOOSE_STARTERS = [];    // config.yml's loose_starters: [{ key, label }], the loose-chat dialog's presets

let filter = "open";
let query = "";
let ask = null;        // { query, pending, hits: [{slug, why}] } while an ask answer is on the board
let focusIdx = -1;
let visibleSlugs = [];
let detailSlug = null;
let distilling = [];   // slugs whose transcripts are being distilled server-side
let attention = [];    // the chat view's list, in attention order (server-sorted)
let mode = "board";    // "board" | "chat" | "prs" | "issues" | "settings"
let chatSlug = null;   // the item the chat view shows, or a loose chat's tmux name
let looseChats = [];   // live loose chats (LooseChat): [{ name, id, session, title, project, state, since }]
let pf = { running: false };  // what the dev server serves (header badge); command null when none is configured
let caffeinate = { on: false, mode: "off" };  // the header's ☕ toggle: a `caffeinate -i` the GUI owns
let rateLimits = null;  // the header chip: the 5h/weekly limits the status line last wrote
let asideModels = ["sonnet"]; // the aside drawer's model picker; the first is the default
let panes = [];        // live tmux sessions on the GUI socket: item chats (by slug) and bin/update runs
let jobs = [];         // long actions running server-side: [{ key, label, pf }]
let buildProgress = {}; // slug → the newest on-demand build-progress estimate (BuildProgress)
let buildActive = [];   // slugs with a build task running or in review: only they get the button
let benchmarkBusy = null; // the live benchmark run, machine-wide: { id, slug, branch, state } (every 🏁 shows it)
let updateOffer = null; // { slug, path } after a pf switch: offer bin/update there
const wsCache = {};    // slug → /api/workspace answer (target worktree, pf mode) for the selected branch it names in query
const wsLoading = {};  // slug → the branch being fetched
const answerDrafts = {}; // "slug#doc_id" → half-typed board answer
const foldedBatches = new Set(); // "slug#batch" boards the user folded or unfolded against the default

const $ = (s, r = document) => r.querySelector(s);
const el = (tag, cls, html) => { const n = document.createElement(tag); if (cls) n.className = cls; if (html != null) n.innerHTML = html; return n; };
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const short = (id) => String(id || "").slice(0, 8);
/* The dev server's name in labels: its configured command. */
const devCmd = () => pf.command || "dev server";
const stateLabel = k => (STATES.find(s => s.key === k) || {}).label || k;

/* Claiming a session is a move — say where it moved from when it was elsewhere. */
function movedFrom(r) {
  return r.detached && r.detached.length ? ` (moved off ${r.detached.join(", ")})` : "";
}

function toast(msg, ok = true) {
  const box = $("#toasts");
  const t = el("div", "toast", (ok ? '<span class="ok">✓</span> ' : '<span class="bad">✕</span> ') + esc(msg));
  box.appendChild(t);
  setTimeout(() => { t.style.transition = "opacity .3s, transform .3s"; t.style.opacity = "0"; t.style.transform = "translateY(6px)"; }, 2400);
  setTimeout(() => t.remove(), 2750);
}

/* A pane's render keeps where the user had scrolled: `root` (the pane, or a
   function returning it when the render replaces it) and every element
   scrolled inside it get their offsets back by position once `render` has
   rebuilt them, again when an async render settles. `same` false (another
   item, issue, … shown) starts the pane at the top instead. */
function keepScroll(root, render, same = true) {
  const at = () => typeof root === "function" ? root() : root;
  const before = at();
  const marks = same && before ? [before, ...before.querySelectorAll("*")].filter(n => n.scrollTop || n.scrollLeft)
    .map(n => [scrollPath(before, n), n.scrollTop, n.scrollLeft]) : [];
  const out = render();
  const put = () => {
    const now = at();
    if (!now) return;
    if (!same) now.scrollTop = now.scrollLeft = 0;
    marks.forEach(([path, top, left]) => { const n = path ? now.querySelector(path) : now; if (n) { n.scrollTop = top; n.scrollLeft = left; } });
  };
  put();
  if (out && typeof out.then === "function") out.then(put, () => {});
  return out;
}
/* Whether `pane` last rendered `subject` (an item's slug, …), remembering
   it for the next render: keepScroll's `same`. */
function sameSubject(pane, subject) {
  const same = pane.dataset.subject === String(subject || "");
  pane.dataset.subject = subject || "";
  return same;
}
function scrollPath(root, n) {
  const parts = [];
  for (; n !== root; n = n.parentElement) {
    if (n.id) { parts.unshift("#" + CSS.escape(n.id)); break; }
    parts.unshift(`${n.localName}:nth-child(${[...n.parentElement.children].indexOf(n) + 1})`);
  }
  return !parts.length ? "" : parts[0][0] === "#" ? parts.join(" > ") : ":scope > " + parts.join(" > ");
}
