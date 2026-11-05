"use strict";

/* ------- action dispatch ------- */
function runAction(actName, it, anchor) {
  switch (actName) {
    case "resume": act("resume", { slug: it.slug }).then(r => { if (r.ok) toast(`resuming ${it.slug} → Warp tab`); }); break;
    case "start":  act("start", { slug: it.slug }).then(r => { if (r.ok) toast(`new session for ${it.slug} → Warp tab`); }); break;
    case "pane-resume": case "pane-start": paneAction(actName, it); break;
    case "aside":  openAside(it); break;
    case "diff":   toggleDiff(); break;
    case "issues": toggleIssues(); break;
    case "drafts": openDraftsTray(); break;
    case "drafts-load": loadClipboardAnnotations(it.slug); break;
    case "pr":     act("pr", { slug: it.slug }).then(r => { if (r.ok) toast(`opening PR for ${it.slug}`); }); break;
    case "state":  stateMenu(anchor, it); break;
    case "note":   noteModal(it); break;
    case "more":   moreMenu(anchor, it); break;
  }
}

/* ------- events ------- */
$("#columns").addEventListener("click", e => {
  const actBtn = e.target.closest(".act");
  const card = e.target.closest(".card");
  if (!card) return;
  focusIdx = visibleSlugs.indexOf(card.dataset.slug); applyFocus();
  const it = items.find(i => i.slug === card.dataset.slug);
  if (actBtn) { runAction(actBtn.dataset.act, it, actBtn); e.stopPropagation(); return; }
  openChat(it);
});

$("#modes").addEventListener("click", e => {
  const b = e.target.closest("button"); if (!b) return;
  setMode(b.dataset.mode);
});

// Tab (or programmatic focus) onto a card mirrors into the app's selection, so
// Tab and j/k share a single highlight instead of drifting apart.
$("#columns").addEventListener("focusin", e => {
  const card = e.target.closest(".card");
  if (!card) return;
  const idx = visibleSlugs.indexOf(card.dataset.slug);
  if (idx < 0 || idx === focusIdx) return;
  focusIdx = idx; applyFocus();
});

$("#inbox-body").addEventListener("click", e => {
  const btn = e.target.closest(".act");
  const row = e.target.closest(".inbox-item");
  if (!row) return;
  const sess = inbox.find(s => s.id === row.dataset.id);
  if (!sess) return;
  if (!btn) { openSession(null, sess); return; }
  const a = btn.dataset.act;
  if (a === "attach") attachMenu(btn, sess);
  else if (a === "dismiss") act("dismiss", { args: { session: sess.id } }).then(r => { if (r.ok) toast(`dismissed ${short(sess.id)}`); });
  else if (a === "mk-item") itemFromSessionModal(sess);
  e.stopPropagation();
});

$("#filters").addEventListener("click", e => {
  const b = e.target.closest("button"); if (!b) return;
  setFilter(b.dataset.filter);
});
function setFilter(f) {
  filter = f;
  document.querySelectorAll("#filters button").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.filter === f)));
  focusIdx = -1; render();
}

$("#search").addEventListener("input", e => { query = e.target.value; ask = null; focusIdx = -1; render(); renderSearchMenu(); });
$("#search").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.isComposing) {
    e.preventDefault();
    if (e.shiftKey) runTranscriptSearch(); else if (issueRef(query)) startFromSearch(); else runAsk();
    renderSearchMenu();
  }
});
$("#search").addEventListener("focus", renderSearchMenu);
$("#search").addEventListener("blur", renderSearchMenu);
// mousedown, not click: the input's blur would hide the menu before a click lands.
$("#search-menu-ask").addEventListener("mousedown", e => { e.preventDefault(); runAsk(); renderSearchMenu(); });
$("#search-menu-issue").addEventListener("mousedown", e => { e.preventDefault(); startFromSearch(); });
$("#search-menu-grep").addEventListener("mousedown", e => { e.preventDefault(); runTranscriptSearch(); });
$("#elsewhere").addEventListener("click", e => { e.preventDefault(); setFilter("all"); });
$("#new-item").addEventListener("click", newItemModal);
$("#att-min").addEventListener("click", () => setChatsMin(!chatsMin));
$("#loose-new").addEventListener("click", newLooseModal);
applyChatsMin();
$("#header-more").addEventListener("click", e => headerMenu(e.currentTarget));
$("#caffeinate").addEventListener("click", () =>
  act("caffeinate", { args: { mode: CAFFEINATE_NEXT[caffeinate.mode] || "auto" } }).then(r => {
    if (!r.ok) return;
    toast({ on: "Mac kept from idle sleep (display may still sleep)", off: "caffeinate off",
            auto: "caffeinate auto: Mac kept awake while any session is working" }[r.caffeinate.mode]);
  }));

$("#theme").addEventListener("click", () => {
  const root = document.documentElement;
  const dark = root.getAttribute("data-theme") === "dark"
    || (!root.getAttribute("data-theme") && window.matchMedia("(prefers-color-scheme: dark)").matches);
  root.setAttribute("data-theme", dark ? "light" : "dark");
});

/* Anything cut off with an ellipsis shows its full text on hover, above
   whatever title it or an element around it already had (a chat row's
   slug). Set on the hover itself, since only then is the width known, and
   put back once the text fits. */
let ellipsisCanvas = null;
function cutOff(node) {
  if (node.tagName !== "SELECT") return node.scrollWidth > node.clientWidth;
  const style = getComputedStyle(node);
  ellipsisCanvas ||= document.createElement("canvas").getContext("2d");
  ellipsisCanvas.font = style.font;
  const room = node.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
  return ellipsisCanvas.measureText(node.selectedOptions[0]?.text || "").width > room;
}

document.addEventListener("mouseover", e => {
  for (let node = e.target; node && node !== document.body; node = node.parentElement) {
    if (getComputedStyle(node).textOverflow !== "ellipsis") continue;
    if (!("baseTitle" in node.dataset)) node.dataset.baseTitle = node.title;
    const base = node.dataset.baseTitle || node.parentElement?.closest("[title]")?.title || "";
    const text = (node.tagName === "SELECT" ? node.selectedOptions[0]?.text : node.textContent)?.trim();
    if (text && cutOff(node) && !base.includes(text)) node.title = base ? `${text}\n${base}` : text;
    else if (node.dataset.baseTitle) node.title = node.dataset.baseTitle;
    else node.removeAttribute("title");
    return;
  }
});

document.addEventListener("keydown", e => {
  // Every key typed into a terminal is claude's, Esc included — except ⌘⇧⏎
  // and ⌘⇧Esc, which the terminal's own key handler has already turned into
  // a toggle and a blur.
  if (e.target.closest && e.target.closest(".term-host")) return;
  // Outside the terminal, ⌘⇧⏎ fills the page with the diff while it is open.
  if (isMaxChord(e)) {
    if (!$("#diff-pane").hidden) { e.preventDefault(); toggleDiffMax(); }
    else if (chatTermShown()) { e.preventDefault(); togglePaneMax(); }
    return;
  }
  if (e.key === "Escape") {
    if (openModal) return closeModal();
    if (openPop) return closePop();
    if (openSessSheet) return closeSession();
    if (openSheet) return closeDetail();
    if (ask) return clearAsk();
    if (document.activeElement === $("#search")) return $("#search").blur();
  }
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
  if (e.key === "/" && !typing && mode === "board") { e.preventDefault(); $("#search").focus(); return; }
  // An open popover owns its own arrow keys (roving focus); don't also move the grid.
  if (typing || openModal || openSheet || openSessSheet || openPop) return;
  // Let the browser own modified chords (⌘R reload, ⌘L, etc.) — our shortcuts are bare keys only.
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  if (e.key === "v") { e.preventDefault(); setMode(mode === "board" ? "chat" : "board"); return; }
  if (e.key === "p") { e.preventDefault(); setMode(mode === "prs" ? "board" : "prs"); return; }
  if (e.key === "I") { e.preventDefault(); setMode(mode === "issues" ? "board" : "issues"); return; }
  if (mode === "chat") return chatKey(e);
  if (mode === "prs") return prsKey(e);
  if (mode === "issues") return issueListKey(e);

  const it = focusedItem();
  switch (e.key) {
    case "j": case "ArrowDown": e.preventDefault(); moveFocus(1); break;
    case "k": case "ArrowUp":   e.preventDefault(); moveFocus(-1); break;
    case "h": case "ArrowLeft":  e.preventDefault(); moveColumn(-1); break;
    case "l": case "ArrowRight": e.preventDefault(); moveColumn(1); break;
    case "c": e.preventDefault(); newItemModal(); break;
    case "Enter": if (it) openChat(it); break;
    case "r": if (it) runAction("resume", it); break;
    case "n": if (it) runAction("start", it); break;
    case "o": if (it) runAction("pr", it); break;
    case "s": if (it) { const c = document.querySelector(`.card[data-slug="${it.slug}"] .act[data-act="state"]`); stateMenu(c, it); } break;
    case "a": if (it) noteModal(it); break;
    case ".": if (it) { const c = document.querySelector(`.card[data-slug="${it.slug}"] .act[data-act="more"]`); moreMenu(c, it); } break;
  }
});

/* The chat view's keys: the board's item keys, aimed at the selected chat.
   Popover anchors are the chat header's buttons. */
function chatKey(e) {
  const it = items.find(i => i.slug === chatSlug);
  const anchor = a => document.querySelector(`#chat-main .act[data-act="${a}"]`);
  switch (e.key) {
    case "j": case "ArrowDown": e.preventDefault(); moveChat(1); break;
    case "k": case "ArrowUp":   e.preventDefault(); moveChat(-1); break;
    case "c": e.preventDefault(); newItemModal(); break;
    case "Enter": if ((it || looseOf(chatSlug)) && panes.includes(chatSlug)) { e.preventDefault(); focusChatTermSoon(chatSlug); } break;
    case "i": if (it) openDetail(it); break;
    case "r": if (it) runAction("pane-resume", it); break;
    case "n": if (it) runAction("pane-start", it); break;
    case "o": if (it) runAction("pr", it); break;
    case "s": if (it) stateMenu(anchor("state"), it); break;
    case "a": if (it) noteModal(it); break;
    case "q": if (it) { e.preventDefault(); openAside(it); } break;
    case "d": if (it) { e.preventDefault(); toggleDiff(); } break;
    case "D": e.preventDefault(); toggleDiffMax(); break;
    case ".": if (it) moreMenu(anchor("more"), it); break;
    case "z": {
      const a = attention.find(x => x.slug === chatSlug);
      if (a && a.state === "your_turn" && !a.snoozed) snoozeTurn(a.slug);
      break;
    }
  }
}

window.addEventListener("resize", () => { if (openPop) closePop(); });

/* A macOS notification's click (qm open-chat) arrives as #chat=<slug>, or a
   loose chat's tmux name: open that chat, then drop the hash so a reload
   doesn't reopen it. A finished benchmark's click adds &benchmark=<branch>:
   that branch's benchmark modal opens over the chat. Before the first state
   there are no items yet; the boot below handles it then. */
let booted = false;
async function openChatFromHash() {
  const m = location.hash.match(/^#chat=([^&]+)(?:&benchmark=([^&]+))?/);
  if (!m || !booted) return;
  history.replaceState(null, "", location.pathname + location.search);
  const word = s => decodeURIComponent(s.replace(/\+/g, " "));
  const slug = word(m[1]);
  if (!items.some(i => i.slug === slug) && !looseOf(slug)) await refresh(); // newer than our last state
  const it = items.find(i => i.slug === slug);
  const lc = !it && looseOf(slug);
  if (it) openChat(it);
  else if (lc) openLooseChat(lc);
  if (it && m[2]) openBenchmark(it.slug, word(m[2]));
}
window.addEventListener("hashchange", openChatFromHash);

let savedMode = null;
try { savedMode = localStorage.getItem("qm-mode"); } catch (e) { /* storage blocked: start on the board */ }
refresh().then(() => {
  booted = true;
  if (["chat", "prs", "issues"].includes(savedMode)) setMode(savedMode);
  openChatFromHash();
  importLegacyDiffDrafts();
  if (mode !== "prs") loadPrs(); // the PRs toggle's tally
});
// Keeps the tally current off the PRs view too; the server refetches past its 5 min cache.
setInterval(() => loadPrs(), 5 * 60 * 1000);
