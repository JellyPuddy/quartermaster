"use strict";

/* ------- item links -------
   Any item's links (epic or not, on every surface): one small chip per http(s)
   link, the label's first letter, the label as its title; a click opens the
   link and nothing under it. Empty (hidden) with no links and no issue URL. */
function linkChips(it) {
  const box = el("span", "link-chips");
  (it.links || []).filter(l => /^https?:\/\//i.test(l.url || "")).forEach(l => {
    const a = el("a", "link-chip", esc((l.label || "").trim().charAt(0).toUpperCase() || "?"));
    a.href = l.url; a.target = "_blank"; a.rel = "noreferrer";
    a.title = `${l.label} — ${l.url}`;
    a.onclick = ev => ev.stopPropagation();
    box.appendChild(a);
  });
  if (describesIssue(it)) box.appendChild(linksRefreshButton(it));
  return box;
}
/* An item describing a GitHub issue gets ↻ links here; an epic also its
   sub-issues in the chats Epic block (chat-epic.js). It describes one with an
   issue URL in its description, or a title ending "(#N)" (the issue in its
   project's repo, which only the server knows). */
const GITHUB_ISSUE_URL = /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/issues\/\d+/;
function describesIssue(it) {
  return GITHUB_ISSUE_URL.test(it.description || "") || /\(#[1-9]\d*\)\s*$/.test(it.title || "");
}
/* ↻ links: an item describing a GitHub issue re-reads it on a server job and
   gains the Tracker / Notion / heading links it lacks; the user's own links stay. */
function linksRefreshButton(it) {
  const job = jobFor(it.slug);
  const b = el("button", "links-refresh", job ? esc(job.label) : "↻ links");
  b.type = "button";
  b.disabled = !!job;
  b.title = "Add the links this item's GitHub issue gives and it lacks";
  b.onclick = ev => { ev.stopPropagation(); act("links-refresh", { slug: it.slug }); };
  return b;
}

/* The detail sheet's Links section: each link with ✕, then label + url to add
   one (a label already there gets the new url). The sheet is rebuilt on every
   refresh, so the half-typed link and its focus live in linkDraft. */
let linkDraft = { slug: null, label: "", url: "", focus: null };
function linkField(it, key, placeholder, type) {
  const input = el("input");
  input.type = type; input.placeholder = placeholder;
  input.value = linkDraft[key];
  input.oninput = () => { linkDraft[key] = input.value; };
  input.onfocus = () => { linkDraft.focus = key; };
  // A rebuild removes the input: only a blur that leaves it in the page is the user's.
  input.onblur = () => setTimeout(() => { if (input.isConnected && linkDraft.focus === key) linkDraft.focus = null; });
  if (linkDraft.focus === key) setTimeout(() => input.focus({ preventScroll: true }));
  return input;
}
function linksEditor(it) {
  if (linkDraft.slug !== it.slug) linkDraft = { slug: it.slug, label: "", url: "", focus: null };
  const box = el("div", "links-editor");
  (it.links || []).forEach(l => {
    const row = el("div", "link-row");
    const a = el("a", "", `<b>${esc(l.label)}</b> <span>${esc(l.url)}</span>`);
    if (/^https?:\/\//i.test(l.url || "")) { a.href = l.url; a.target = "_blank"; a.rel = "noreferrer"; }
    const rm = el("button", "act", "✕");
    rm.title = `Remove ${l.label}`;
    rm.onclick = () => act("link-remove", { slug: it.slug, args: { label: l.label } }).then(r => { if (r.ok) toast(`removed ${l.label}`); });
    row.append(a, rm);
    box.appendChild(row);
  });
  if (!(it.links || []).length) box.appendChild(el("div", "desc-text", "No links yet."));
  const add = el("div", "link-add");
  const label = linkField(it, "label", "Label", "text");
  const url = linkField(it, "url", "https://…", "url");
  const go = el("button", "act", "+ Add link");
  go.onclick = () => {
    const l = linkDraft.label.trim(), u = linkDraft.url.trim();
    if (!l) { label.focus(); return; }
    if (!u) { url.focus(); return; }
    // Cleared before the post: act's refresh rebuilds the sheet before it answers.
    const typed = linkDraft;
    linkDraft = { slug: it.slug, label: "", url: "", focus: null };
    act("link-set", { slug: it.slug, args: { label: l, url: u } }).then(r => {
      if (r.ok) toast(`linked ${l}`); else linkDraft = typed;
    });
  };
  url.addEventListener("keydown", ev => { if (ev.key === "Enter") go.click(); });
  add.append(label, url, go);
  box.appendChild(add);
  return box;
}
