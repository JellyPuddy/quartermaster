"use strict";

/* ------- loose chats -------
   A chat that belongs to no work item (LooseChat): started here or with
   `qm loose`, listed under "Loose" while its tmux session (loose--<id>) lives,
   opened in the normal chat pane. ✕ ends it (/exit, kill, dismiss) and
   → Work item promotes it into an item's chat. chatSlug holds its tmux name.
   A local automation's run chat (<slug>--run-<id>, RunChats) comes in the same
   list with a `run` field and is listed under "Runs"; its button opens the automation.
   An automation's edit chat (its own tmux, named by its slug: AutomationEditChats)
   comes with an `automation` field and is listed under "Automations". */
const looseOf = name => looseChats.find(l => l.name === name);
/* A notification's click (browser or macOS): chat mode, that loose chat, terminal focused. */
function openLooseChat(lc) { chatSlug = lc.name; setMode("chat"); selectChat(lc.name, { focusTerm: true }); }

let looseModel = "";
try { looseModel = localStorage.getItem("qm-loose-model") || ""; } catch (e) { /* storage blocked: claude's default */ }

function newLooseModal() {
  modal(m => {
    m.innerHTML = `<h2>New loose chat</h2><p class="sub">a chat with no work item · in the project's main checkout</p>`;
    const pf = el("div", "field", `<label>Project</label><select>${PROJECTS.map(p => `<option>${esc(p)}</option>`).join("")}</select>`);
    // "Start with": config.yml's loose_starters (LOOSE_STARTERS, from the state), "" for none.
    const starters = [{ key: "", label: "(nothing)" }, ...LOOSE_STARTERS];
    const sf = el("div", "field", `<label>Start with</label><select>${starters.map(s => `<option value="${esc(s.key)}">${esc(s.label)}</option>`).join("")}</select>`);
    const tf = el("div", "field", `<label>First prompt <span style="text-transform:none;color:var(--faint)">(optional)</span></label><textarea placeholder="What do you want to ask?"></textarea>`);
    const models = ["", ...asideModels];
    const mf = el("div", "field", `<label>Model</label><select>${models.map(k => `<option value="${esc(k)}"${k === looseModel ? " selected" : ""}>${k || "claude's default"}</option>`).join("")}</select>`);
    m.append(pf, ...(LOOSE_STARTERS.length ? [sf] : []), tf, mf);
    const starter = sf.querySelector("select");
    starter.onchange = () => {
      ta.placeholder = starter.value ? "What do you want to know about them? (else it asks)" : "What do you want to ask?";
    };
    const ta = tf.querySelector("textarea");
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const start = el("button", "btn primary", "Start chat");
    start.onclick = () => {
      const model = mf.querySelector("select").value;
      looseModel = model;
      try { localStorage.setItem("qm-loose-model", model); } catch (e) { /* storage blocked: this page only */ }
      act("loose-start", { args: { project: pf.querySelector("select").value, model, prompt: ta.value.trim(), starter: starter.value } }).then(r => {
        if (!r.ok) return;
        closeModal();
        if (mode !== "chat") setMode("chat");
        selectChat(r.name, { focusTerm: true });
      });
    };
    bar.append(cancel, start); m.appendChild(bar);
    ta.addEventListener("keydown", e => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") start.click(); });
    ta.focus();
  });
}

function closeLoose(lc) {
  act("loose-close", { args: { id: lc.id } }).then(r => { if (r.ok) toast("closing the loose chat…"); });
}

function promoteLooseModal(lc) {
  modal(m => {
    m.innerHTML = `<h2>Loose chat → work item</h2><p class="sub">${esc(lc.project || "No project")} · the chat carries on as the item's</p>`;
    const tf = el("div", "field", `<label>Title</label><input type="text" placeholder="Short, intent-named title">`);
    const input = tf.querySelector("input");
    if (lc.title !== "New loose chat") input.value = lc.title;
    m.appendChild(tf);
    const tellField = el("div", "field", `<label><input type="checkbox" checked> Tell the chat</label>`);
    tellField.title = "Type one line into the chat naming its new item, so it follows the item's protocol from here";
    const tellBox = tellField.querySelector("input");
    m.appendChild(tellField);
    const bar = el("div", "modal-actions");
    const cancel = el("button", "btn", "Cancel"); cancel.onclick = closeModal;
    const create = el("button", "btn primary", "Create item");
    create.onclick = () => {
      const title = input.value.trim();
      if (!title) { input.focus(); return; }
      act("loose-promote", { args: { id: lc.id, title, tell: tellBox.checked } }).then(r => {
        if (!r.ok) return;
        closeModal();
        toast(`created ${r.slug} from the loose chat${r.told ? " and told the chat" : ""}`);
        if (r.warning) toast(r.warning, false);
        selectChat(r.warning ? lc.name : r.slug);
      });
    };
    input.addEventListener("keydown", e => { if (e.key === "Enter") create.click(); });
    bar.append(cancel, create); m.appendChild(bar);
    input.focus(); input.select();
  });
}

function looseButtons(lc, cls) {
  if (lc.run || lc.automation) {
    const open = el("button", cls, "⚙ automation");
    open.title = lc.run ? "Open this run's automation in the Automations tab" : "Open this automation in the Automations tab";
    open.onclick = e => { e.stopPropagation(); showAutomation(lc.run ? lc.run.slug : lc.automation); };
    open.tabIndex = -1;
    return [open];
  }
  const promote = el("button", cls, "→ Work item");
  promote.title = "Make this chat a work item's: an item with this session, the chat renamed to its slug";
  promote.onclick = e => { e.stopPropagation(); promoteLooseModal(lc); };
  const close = el("button", cls, "✕");
  close.title = "End this loose chat (/exit) and dismiss it from the inbox";
  close.onclick = e => { e.stopPropagation(); closeLoose(lc); };
  [promote, close].forEach(b => b.tabIndex = -1);
  return [promote, close];
}

/* The chats list's Loose group, then its Automations and Runs groups, after the item chats. */
function renderLooseGroup(list) {
  renderLooseRows(list, "Loose ", looseChats.filter(lc => !lc.run && !lc.automation));
  renderLooseRows(list, "Automations ", looseChats.filter(lc => lc.automation));
  renderLooseRows(list, "Runs ", looseChats.filter(lc => lc.run));
}

function renderLooseRows(list, label, chats) {
  if (!chats.length) return;
  const head = el("div", "att-group loose-group", label);
  head.appendChild(el("span", "loose-count", String(chats.length)));
  list.appendChild(head);
  chats.forEach(lc => {
    const row = el("div", `att-row ${lc.state}${lc.name === chatSlug ? " selected" : ""}`);
    row.dataset.slug = lc.name;
    row.title = lc.title;
    row.tabIndex = lc.name === chatSlug ? 0 : -1;
    row.appendChild(attDot(lc));
    const initials = el("span", "att-short", esc(chatInitials(lc.title, lc.id)));
    initials.title = [lc.title, lc.run ? "automation run" : lc.automation ? "automation edit chat" : "loose chat", attLabel(lc)].join("\n");
    row.appendChild(initials);
    const name = el("span", "att-label", "");
    name.appendChild(el("span", "att-name", esc(lc.title)));
    row.appendChild(name);
    const w = el("span", "att-wait", lc.state === "none" ? "" : waitedFor(lc.since));
    w.dataset.since = lc.state === "none" ? "" : (lc.since || "");
    row.appendChild(w);
    const meta = el("div", "att-meta");
    meta.appendChild(attState(lc));
    if (lc.project) meta.appendChild(el("span", "loose-project", esc(lc.project)));
    meta.append(...looseButtons(lc, "snooze-btn"));
    row.appendChild(meta);
    row.onclick = () => selectChat(lc.name, { focusTerm: true });
    list.appendChild(row);
  });
}

/* The centre pane for a loose chat: its header and its terminal. */
function renderLooseMain(lc, headSlot, wrap) {
  const head = el("div", "chat-head");
  const r1 = el("div", "row1");
  r1.appendChild(attDot(lc));
  r1.appendChild(el("span", "slug", lc.run ? "automation run" : "loose chat"));
  if (lc.project) r1.appendChild(clipped("slug", lc.project));
  r1.appendChild(attNow(lc));
  head.appendChild(r1);
  head.appendChild(el("h2", "", esc(lc.title)));
  const bar = el("div", "sheet-actions");
  const job = jobFor(lc.name);
  if (job) bar.appendChild(el("span", "job-label", esc(job.label)));
  else bar.append(...looseButtons(lc, "act"));
  head.appendChild(bar);
  headSlot.appendChild(head);

  wrap.hidden = false;
  const tb = $("#term-bar");
  tb.innerHTML = "";
  tb.appendChild(el("span", "grow", `tmux · ${esc(lc.name)}${lc.cwd ? ` · ${esc(lc.cwd)}` : ""}${lc.run ? "" : " — no work item: promote it before it changes code"}`));
  const max = el("button", "max-btn", "");
  max.id = "pane-max-btn";
  max.title = "Fill the page with this chat (⌘⇧⏎ toggles; Esc stays claude's)";
  max.onclick = () => { togglePaneMax(); chatTerm.focus(); };
  tb.appendChild(max);
  chatTerm.connect(lc.name);
  if (wantsTermFocus === lc.name) focusChatTermSoon(lc.name);
}
