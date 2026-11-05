"use strict";

/* A terminal attached to one tmux session on the GUI's socket, over the
   server's /ws/terminal bridge: xterm.js draws, keystrokes go back as binary
   frames, resizes as {cols, rows} text frames. Each connection is a fresh
   tmux client, so a reload or a GUI restart just reattaches and tmux redraws
   the screen; the wheel scrolls tmux's own history (mouse mode). */
/* xterm.js drops ⌘← / ⌘→ / ⌘⌫ (it leaves ⌘ chords to the browser) and sends
   ⇧⏎ as a bare Enter. Mapped like Warp and iTerm: line start, line end,
   delete to line start, and ⇧⏎ as Option-Enter (ESC CR), claude's newline.
   Keyed by the chord's only modifier. */
const MAC_CHORDS = { "Meta+ArrowLeft": "\x01", "Meta+ArrowRight": "\x05", "Meta+Backspace": "\x15", "Shift+Enter": "\x1b\r" };
const chordName = e => {
  const mods = ["Meta", "Shift", "Control", "Alt"].filter(m => e.getModifierState(m));
  return mods.length === 1 ? `${mods[0]}+${e.key}` : null;
};

/* Plain-text URLs as links, including ones broken across rows. tmux redraws
   row by row, so xterm never marks a row as wrapped and a URL split by the
   terminal or by claude's own layout looks like two lines. A row that runs
   to the right edge is joined to the next row, minus that row's indent. */
const URL_RE = /https?:\/\/[^\s"'<>`\u2500-\u257F]+[^\s"'<>`\u2500-\u257F.,;:!?)\]]/g;
function urlLinks(xt, open) {
  const MAX_ROWS = 12;
  // A row as [code unit, 1-based column] pairs: wide characters take two
  // columns and emoji two code units, so string index and column differ.
  const row = y => {
    const line = xt.buffer.active.getLine(y);
    if (!line) return null;
    const units = [];
    for (let x = 0; x < xt.cols; x++) {
      const cell = line.getCell(x);
      if (!cell || cell.getWidth() === 0) continue;
      for (const u of (cell.getChars() || " ").split("")) units.push([u, x + 1]);
    }
    return units;
  };
  const textOf = units => units.map(u => u[0]).join("");
  const runsOn = y => {
    const text = row(y), next = row(y + 1);
    if (!text || !next) return false;
    const last = text.findLast(u => u[0] !== " ");
    return !!last && last[1] >= xt.cols - 1 && /^ {0,4}\S/.test(textOf(next));
  };
  return {
    provideLinks(lineNumber, callback) {
      const y = lineNumber - 1;
      let first = y;
      while (first > 0 && y - first < MAX_ROWS && runsOn(first - 1)) first--;
      const units = [];
      for (let r = first; r <= y + MAX_ROWS; r++) {
        let line = row(r);
        if (!line) break;
        const joined = runsOn(r);
        if (r > first) line = line.slice(textOf(line).length - textOf(line).trimStart().length);
        if (joined) line = line.slice(0, textOf(line).trimEnd().length);
        units.push(...line.map(u => [u[0], u[1], r + 1]));
        if (!joined) break;
      }
      const links = [];
      for (const m of textOf(units).matchAll(URL_RE)) {
        const a = units[m.index], b = units[m.index + m[0].length - 1];
        if (a[2] > lineNumber || b[2] < lineNumber) continue;
        links.push({ text: m[0], range: { start: { x: a[1], y: a[2] }, end: { x: b[1], y: b[2] } }, activate: open });
      }
      callback(links.length ? links : undefined);
    }
  };
}

class TermView {
  constructor(host) { this.host = host; this.xt = null; this.ws = null; this.name = null; this.lastTry = 0; }

  ready() {
    if (this.xt) return true;
    if (!window.Terminal || !window.FitAddon) return false;
    // Links open in a new tab: plain-text URLs through urlLinks, OSC 8
    // hyperlinks through linkHandler (xterm.js's default asks confirm()).
    const openLink = (_event, uri) => window.open(uri, "_blank", "noopener");
    this.xt = new Terminal({ fontFamily: 'Menlo, "SF Mono", monospace', fontSize: 12.5, cursorBlink: true,
      scrollback: 0, allowProposedApi: true, theme: { background: "#16181F", foreground: "#D7DCE6" },
      linkHandler: { activate: openLink } });
    this.fit = new FitAddon.FitAddon();
    this.xt.loadAddon(this.fit);
    // xterm.js defaults to Unicode 6 widths; tmux and claude count symbols and
    // emoji with newer tables, and every disagreement shifts the rest of that
    // line and the cursor.
    if (window.Unicode11Addon) { this.xt.loadAddon(new Unicode11Addon.Unicode11Addon()); this.xt.unicode.activeVersion = "11"; }
    this.xt.registerLinkProvider(urlLinks(this.xt, openLink));
    this.xt.open(this.host);
    const enc = new TextEncoder();
    const send = data => { if (this.ws && this.ws.readyState === 1) this.ws.send(data); };
    // ⌘⇧⏎ toggles the maximized chat and ⌘⇧Esc hands focus back to the page,
    // neither reaching claude, and the Mac editing chords go out as Mac
    // terminals send them (MAC_CHORDS). Every event type of a chord is
    // swallowed; keydown alone acts.
    this.xt.attachCustomKeyEventHandler(e => {
      const max = this.onMaxChord && isMaxChord(e);
      const leave = !max && isLeaveChord(e);
      const seq = !max && !leave && MAC_CHORDS[chordName(e)];
      if (!max && !leave && !seq) return true;
      e.preventDefault();
      if (e.type === "keydown") max ? this.onMaxChord() : leave ? this.xt.blur() : send(enc.encode(seq));
      return false;
    });
    // A browser never tells the page where a dropped file lives: it goes up
    // to qm (/api/drop) and the saved path is pasted into the chat, the way
    // Warp pastes a dropped file's path — claude attaches an image path.
    this.host.addEventListener("dragover", e => {
      if (!e.dataTransfer.types.includes("Files")) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    });
    this.host.addEventListener("drop", e => {
      const files = [...e.dataTransfer.files];
      if (!files.length) return;
      e.preventDefault();
      this.drop(files);
    });
    this.xt.onData(d => send(enc.encode(d)));
    this.xt.onBinary(d => send(Uint8Array.from(d, c => c.charCodeAt(0))));
    this.xt.onResize(({ cols, rows }) => send(JSON.stringify({ cols, rows })));
    this.host.addEventListener("focusin", () => this.claimSize());
    new ResizeObserver(() => this.refit()).observe(this.host);
    return true;
  }

  /* tmux sizes a chat to the client that attached, resized or typed last: a
     second tab or a Warp attach on the same chat takes the window,
     and this pane then shows only its top rows. Re-sending the size (the
     server signals SIGWINCH with it) takes the window back. */
  claimSize() {
    if (this.xt && this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify({ cols: this.xt.cols, rows: this.xt.rows }));
  }

  refit() { if (this.xt && this.host.offsetWidth > 0 && this.host.offsetHeight > 0) this.fit.fit(); }

  /* Idempotent: re-rendering the chat view calls this every state poll. A
     dropped connection retries at most every 2 s while the session lives. */
  connect(name) {
    if (!this.ready()) { this.host.textContent = "xterm.js did not load (offline?) — reload to retry."; return; }
    if (this.name === name && this.ws) return;
    if (this.name === name && Date.now() - this.lastTry < 2000) return;
    this.disconnect();
    this.name = name;
    this.lastTry = Date.now();
    this.xt.reset();
    this.refit();
    const q = new URLSearchParams({ session: name, token: terminalToken || "", cols: this.xt.cols, rows: this.xt.rows });
    const ws = new WebSocket(`ws://${location.host}/ws/terminal?${q}`);
    ws.binaryType = "arraybuffer";
    // A refit while the socket was still connecting sent nothing (send needs
    // it open): tmux kept the URL's size, drew a row more than xterm shows,
    // and the screen scrolled under a cursor left one line low.
    ws.onopen = () => ws.send(JSON.stringify({ cols: this.xt.cols, rows: this.xt.rows }));
    ws.onmessage = e => this.xt.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data));
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.ws = null;
      // The chat ended (its session is gone) or the GUI went away: the next
      // state says which, and the chat view re-renders from it.
      if (this.onClosed) this.onClosed();
    };
    this.ws = ws;
  }

  disconnect() {
    const ws = this.ws;
    this.ws = null;
    this.name = null;
    if (ws) ws.close();
  }

  focus() { if (this.xt) this.xt.focus(); }

  async drop(files) {
    const paths = [];
    for (const file of files) {
      const q = new URLSearchParams({ token: terminalToken || "", name: file.name });
      const r = await fetch(`/api/drop?${q}`, { method: "POST", body: file })
        .then(res => res.json()).catch(() => ({ ok: false, error: "upload failed — is qm gui running?" }));
      if (!r.ok) { toast(r.error || "drop failed", false); return; }
      paths.push(r.path);
    }
    this.xt.paste(paths.join(" ") + " ");
    this.focus();
  }
}

/* Coming back to this tab or window is when its panes should own their chats. */
const claimTermSizes = () => { if (!document.hidden) { chatTerm.claimSize(); asideTerm.claimSize(); } };
window.addEventListener("focus", claimTermSizes);
document.addEventListener("visibilitychange", claimTermSizes);

const chatTerm = new TermView($("#term-host"));
chatTerm.onClosed = () => refresh();
chatTerm.onMaxChord = () => togglePaneMax();

/* Maximize: the live chat fills the page (⌘⇧⏎ or the term bar's button). Esc
   never restores — it is claude's. Remembered per browser tab. */
let paneMax = false;
try { paneMax = sessionStorage.getItem("qm-pane-max") === "1"; } catch (e) { /* storage blocked: not maximized */ }
const isMaxChord = e => e.key === "Enter" && e.metaKey && e.shiftKey && !e.ctrlKey && !e.altKey;
/* ⌘⇧Esc leaves the terminal: focus falls to the page body, where the
   document's shortcuts work again. Plain Esc stays claude's. */
const isLeaveChord = e => e.key === "Escape" && e.metaKey && e.shiftKey && !e.ctrlKey && !e.altKey;
const chatTermShown = () => mode === "chat" && !$("#term-wrap").hidden;

function applyPaneMax() {
  const on = paneMax && chatTermShown();
  if (document.body.classList.contains("pane-max") !== on) {
    document.body.classList.toggle("pane-max", on);
    requestAnimationFrame(() => { chatTerm.refit(); asideTerm.refit(); });
  }
  const btn = $("#pane-max-btn");
  if (btn) {
    btn.setAttribute("aria-pressed", String(paneMax));
    btn.textContent = paneMax ? "⤡ Restore" : "⤢ Maximize";
  }
}

function togglePaneMax() {
  if (!chatTermShown()) return;
  paneMax = !paneMax;
  try { sessionStorage.setItem("qm-pane-max", paneMax ? "1" : "0"); } catch (e) { /* not remembered */ }
  applyPaneMax();
}

/* bin/update after a pf switch runs in a tmux session of its own; watch it here. */
function terminalModal(name, title) {
  let view = null;
  modal(m => {
    m.classList.add("term-dialog");
    m.appendChild(el("h2", "", esc(title)));
    m.appendChild(el("div", "sub", "Migrations stay manual. Closing this view leaves bin/update running in tmux."));
    const wrap = el("div", "term-wrap");
    const bar = el("div", "term-bar", `<span class="grow">tmux · ${esc(name)}</span>`);
    const warp = el("button", "", "Open in Warp");
    warp.title = "tmux attach to the same session in a Warp tab";
    warp.onclick = () => act("pane-warp", { slug: name });
    bar.appendChild(warp);
    const host = el("div", "term-host");
    wrap.append(bar, host);
    m.appendChild(wrap);
    const done = el("div", "modal-actions");
    const close = el("button", "btn", "Close");
    close.title = "Closes this view only — bin/update keeps running in tmux";
    close.onclick = closeModal;
    done.appendChild(close);
    m.appendChild(done);
    view = new TermView(host);
  });
  openModal.onClose = () => view.disconnect();
  requestAnimationFrame(() => { view.connect(name); view.focus(); });
}

function paneAction(cmd, it, args = {}) {
  act(cmd, { slug: it.slug, args }).then(r => {
    if (!r.ok) return;
    if (r.attached) { if (cmd === "pane-start") toast(`${it.slug} already has a live chat — one per item`); }
    else toast(cmd === "pane-start" ? `new chat for ${it.slug}` : `${r.mode === "resume" ? "resuming" : "starting"} ${it.slug} here`);
    if (!panes.includes(it.slug)) panes = panes.concat(it.slug);
    renderChatMain();
    chatTerm.focus();
  });
}
