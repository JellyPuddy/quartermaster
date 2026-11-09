"use strict";

/* ------- chat view -------
   The second mode next to the board: a left list of the chats in attention
   order (the server sorts it — ChatAttention), the selected item's chat in the
   centre (a terminal on its tmux session, or why there is none), and its
   digest on the right. */
const ATT_LABEL = { blocked: "blocked", your_turn: "your turn", working: "working", waiting: "waiting on sub-agent", none: "no live chat" };
// The meter's full width; its colour (amber/red) comes from the server (ContextMeter).
const CTX_SCALE = 300000;

function waitedFor(since) {
  if (!since) return "";
  const s = Math.max(0, (Date.now() - Date.parse(since)) / 1000);
  if (s < 60) return `${Math.floor(s)}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d`;
}
function ctxChip(a) {
  const tokens = a.contextTokens;
  if (!tokens) return null;
  const c = el("span", "ctx" + (a.ctxLevel ? " " + a.ctxLevel : ""), `${Math.round(tokens / 1000)}k`);
  c.title = `context: ${tokens.toLocaleString()} tokens`;
  return c;
}
/* The chat header's meter: a bar on a 300k scale plus the size. */
function ctxMeter(a) {
  const tokens = a.contextTokens;
  if (!tokens) return null;
  const m = el("span", "ctx-meter" + (a.ctxLevel ? " " + a.ctxLevel : ""));
  const bar = el("span", "bar");
  const fill = el("i");
  fill.style.width = `${Math.min(100, Math.round(tokens / CTX_SCALE * 100))}%`;
  bar.appendChild(fill);
  m.append(bar, document.createTextNode(`${Math.round(tokens / 1000)}k context`));
  m.title = `${tokens.toLocaleString()} tokens — amber from 150k, red from 250k`;
  return m;
}

/* Context rotation: never automatic. A live chat in its pane is asked to
   record its decisions and open items, then exits and a fresh session starts
   in the same window; a dead chat's last session is distilled instead.
   closeChat is the same wrap-up without the fresh start: Start picks it up later.
   finishChat closes with a final wrap-up and resolves the item once it closed. */
function rotateChat(slug) {
  act("rotate", { slug }).then(r => {
    if (!r.ok) return;
    toast(r.mode === "wrap_up" ? `${slug}: wrap-up prompt sent — a fresh chat starts once it answers`
                               : `${slug}: distilling the last session, then a fresh chat`);
  });
}
function closeChat(slug) {
  act("rotate", { slug, args: { close: true } }).then(r => {
    if (r.ok) toast(`${slug}: wrap-up prompt sent — the chat closes once it answers`);
  });
}
function closeButton(slug) {
  const b = el("button", "snooze-btn", "wrap up & close");
  b.title = "Record decisions and open items while the cache is hot, then close the chat — Start picks it up later";
  b.tabIndex = -1;
  b.onclick = e => { e.stopPropagation(); closeChat(slug); };
  return b;
}
function finishChat(slug) {
  act("rotate", { slug, args: { finish: true } }).then(r => {
    if (r.ok) toast(`${slug}: final wrap-up sent — the chat closes and the item resolves once it answers`);
  });
}
function finishButton(slug) {
  const b = el("button", "snooze-btn", "finish");
  b.title = "Final wrap-up: record remaining decisions and retag handled notes, then close the chat and resolve the item";
  b.tabIndex = -1;
  b.onclick = e => { e.stopPropagation(); finishChat(slug); };
  return b;
}
function rotateButton(a, cls) {
  const b = el("button", cls + (a.ctxLevel === "red" ? " red" : ""), "rotate?");
  b.title = "Hand this chat over to a fresh session that starts from the work item";
  b.tabIndex = -1;
  b.onclick = e => { e.stopPropagation(); rotateChat(a.slug); };
  return b;
}
/* Reopening an item whose cache went cold on a big context offers a rotation
   once; "Not now" holds until the chat answers again. */
const coldDismissed = {};
function coldOffer(it, a) {
  if (a.rotate !== "cold" || coldDismissed[it.slug] === a.lastAssistantAt || jobFor(it.slug)) return null;
  const box = el("div", "rot-offer");
  const ago = waitedFor(a.lastAssistantAt);
  box.appendChild(el("span", "grow", `The cache is cold (last reply ${esc(ago)} ago) on ${Math.round(a.contextTokens / 1000)}k of context. ` +
    "Rotate to a fresh session that starts from the work item?"));
  const go = el("button", "go", "Rotate");
  go.onclick = () => rotateChat(it.slug);
  const no = el("button", "", "Not now");
  no.onclick = () => { coldDismissed[it.slug] = a.lastAssistantAt; renderChatMain(); };
  box.append(go, no);
  if (panes.includes(it.slug)) {
    const close = el("button", "", "Wrap up & close");
    close.onclick = () => closeChat(it.slug);
    box.insertBefore(close, no);
  }
  return box;
}
function attDot(a) { return el("span", "att-dot " + (a.snoozed ? "snoozed" : a.state)); }
function attLabel(a) {
  if (a.snoozed) return "snoozed";
  if (a.state === "waiting" && a.waitingOn?.length) return `waiting · ${a.waitingOn[0]}${a.waitingOn.length > 1 ? ` +${a.waitingOn.length - 1}` : ""}`;
  return a.state === "blocked" && a.tool ? `blocked · ${a.tool}` : ATT_LABEL[a.state] || a.state;
}

/* The list as rows: the attention entries, plus the selected item when it is
   not among them (opened from the board while fridged, or no live chat). */
function chatRows() {
  const rows = attention.slice();
  if (chatSlug && !rows.some(a => a.slug === chatSlug) && items.some(i => i.slug === chatSlug)) {
    rows.push({ slug: chatSlug, state: "none", extra: true });
  }
  return rows;
}
function snoozeTurn(slug) {
  act("snooze", { slug, args: { duration: "turn" } }).then(r => { if (r.ok) toast(`${slug}: your turn snoozed until its next turn ends`); });
}

/* The chats list shrunk to a strip: a dot and the title's initials per chat,
   the rest in the tooltip. Remembered per browser. */
let chatsMin = false;
try { chatsMin = localStorage.getItem("qm-chats-min") === "1"; } catch (e) { /* storage blocked: start open */ }
function setChatsMin(on) {
  chatsMin = on;
  try { localStorage.setItem("qm-chats-min", on ? "1" : "0"); } catch (e) { /* storage blocked: this page only */ }
  applyChatsMin();
}
function applyChatsMin() {
  document.body.classList.toggle("chats-min", chatsMin);
  const b = $("#att-min");
  b.textContent = chatsMin ? "›" : "‹";
  b.title = chatsMin ? "Widen the chats list" : "Shrink the chats list to a strip of dots";
}

/* "Quartermaster — Claude session tracker (qm)" → "QCS": the first letters
   of its first three words; a number gives its first two digits. */
function chatInitials(title, slug) {
  const words = (title || slug).match(/[\p{L}\p{N}]+/gu) || [slug];
  return words.slice(0, 3).map(w => /^\d/.test(w) ? w.slice(0, 2) : w[0].toUpperCase()).join("");
}

function renderChat() {
  const rows = chatRows();
  if (!chatSlug || !(items.some(i => i.slug === chatSlug) || looseOf(chatSlug))) {
    chatSlug = rows.length ? rows[0].slug : (looseChats.length ? looseChats[0].name : null);
  }
  adoptSidePane();

  $("#att-count").textContent = attention.length;
  const list = $("#att-body");
  keepScroll(list, () => {
    list.innerHTML = "";
    if (!rows.length && !looseChats.length) list.appendChild(el("div", "col-empty", "no chats and nothing in progress"));
    rows.forEach((a, i) => {
      if (a.extra) list.appendChild(el("div", "att-group", "opened from the board"));
      const it = items.find(x => x.slug === a.slug) || { slug: a.slug, title: "" };
      const row = el("div", `att-row ${a.state}${a.snoozed ? " snoozed" : ""}${a.slug === chatSlug ? " selected" : ""}`);
      row.dataset.slug = a.slug;
      row.title = a.slug;
      row.tabIndex = a.slug === chatSlug ? 0 : -1;
      row.appendChild(attDot(a));
      const initials = el("span", "att-short", esc(chatInitials(it.title, a.slug)));
      initials.title = [it.title, a.slug, attLabel(a) + (a.state === "none" ? "" : ` · ${waitedFor(a.since)}`)].filter(Boolean).join("\n");
      row.appendChild(initials);
      const name = el("span", "att-label", "");
      name.appendChild(el("span", "att-name", esc(it.title || a.slug)));
      if (it.served) name.appendChild(servedMark());
      row.appendChild(name);
      const w = el("span", "att-wait", a.state === "none" ? "" : waitedFor(a.since));
      w.dataset.since = a.state === "none" ? "" : (a.since || "");
      row.appendChild(w);
      const segs = chainSegmentBar(it);
      if (segs) row.appendChild(segs);
      const meta = el("div", "att-meta");
      meta.appendChild(el("span", "att-state", esc(attLabel(a))));
      const ctx = ctxChip(a);
      if (ctx) meta.appendChild(ctx);
      const behind = restackCount(it);
      if (behind) meta.appendChild(behind);
      if (a.rotate === "threshold" && !jobFor(a.slug)) meta.appendChild(rotateButton(a, "snooze-btn rotate-btn"));
      if (a.state === "your_turn" && !a.snoozed) {
        const z = el("button", "snooze-btn", "snooze");
        z.title = "Quiet this turn until the next one ends (z)";
        z.tabIndex = -1;
        z.onclick = e => { e.stopPropagation(); snoozeTurn(a.slug); };
        meta.appendChild(z);
      }
      row.appendChild(meta);
      row.onclick = () => selectChat(a.slug, { focusTerm: true });
      list.appendChild(row);
    });
    renderLooseGroup(list);
  });

  renderChatMain();
  renderChatSide();
  syncDiffPane();
  syncIssuesPane();
}
