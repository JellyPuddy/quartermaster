"use strict";

function renderChatMain() {
  const body = $("#chat-body-slot");
  keepScroll(body, () => {
    const headSlot = $("#chat-head-slot");
    const wrap = $("#term-wrap");
    headSlot.innerHTML = ""; body.innerHTML = "";
    const it = items.find(i => i.slug === chatSlug);
    renderAside(it);
    renderHistory(it);
    const lc = !it && looseOf(chatSlug);
    if (lc) { renderLooseMain(lc, headSlot, wrap); applyPaneMax(); return; }
    if (!it) {
      wrap.hidden = true; chatTerm.disconnect();
      body.appendChild(el("div", "chat-empty", "Select a chat on the left, or open an item from the board."));
      applyPaneMax();
      return;
    }
    const a = attention.find(x => x.slug === it.slug) || { state: "none" };
    const hasPane = panes.includes(it.slug);

    const head = el("div", "chat-head");
    const r1 = el("div", "row1");
    r1.appendChild(attDot(a));
    r1.appendChild(el("span", "slug", esc(it.slug)));
    if (it.live) r1.appendChild(el("span", "live-dot", hasPane ? "live" : "live elsewhere"));
    const now = el("span", "att-now", esc(attLabel(a)) + (a.state === "none" ? "" : " · "));
    if (a.state !== "none") { const w = el("span", "att-wait", waitedFor(a.since)); w.dataset.since = a.since || ""; now.appendChild(w); }
    r1.appendChild(now);
    head.appendChild(r1);
    head.appendChild(el("h2", "", esc(it.title)));
    const job = jobFor(it.slug);
    const meter = ctxMeter(a);
    const offer = coldOffer(it, a);
    if (meter || job) {
      const r2 = el("div", "row2");
      if (meter) r2.appendChild(meter);
      if (job) r2.appendChild(el("span", "job-label", esc(job.label)));
      else if (a.rotate && !offer) r2.append(rotateButton(a, "snooze-btn rotate-btn"), closeButton(it.slug), finishButton(it.slug));
      head.appendChild(r2);
    }
    if (offer) head.appendChild(offer);
    const bar = el("div", "sheet-actions");
    const resumeLabel = hasPane ? "▸ Chat" : "▸ Resume";
    [["pane-resume", "strong", resumeLabel, "r"], ["pane-start", "", "Start", "n"], ["state", "", "State ▾", "s"],
     ["aside", "", it.asideCount ? `Aside · ${it.asideCount}` : "Aside", "q"], ["note", "", "Note +", "a"], ["diff", "diff-toggle", "Diff", "d"], ["more", "", "⋯", "."]].forEach(([k, extra, label, key]) => bar.appendChild(action(k, extra, label, key)));
    if (a.state === "your_turn" && !a.snoozed) bar.appendChild(action("snooze-turn", "", "Snooze turn", "z"));
    bar.querySelector('.act[data-act="diff"]').after(clipboardLoadButton());
    if ((it.drafts || []).length) bar.querySelector('.act[data-act="diff"]').after(draftsChip(it));
    if (itemIssues(it)) bar.querySelector('.act[data-act="diff"]').after(issuesButton(it));
    bar.querySelectorAll("button").forEach(b => b.tabIndex = -1);
    bar.addEventListener("click", e => {
      const btn = e.target.closest(".act"); if (!btn) return;
      if (btn.dataset.act === "snooze-turn") snoozeTurn(it.slug); else runAction(btn.dataset.act, it, btn);
    });
    head.appendChild(bar);
    headSlot.appendChild(head);

    if (hasPane) {
      wrap.hidden = false;
      const tb = $("#term-bar");
      tb.innerHTML = "";
      tb.appendChild(el("span", "grow", `tmux · ${esc(it.slug)} — the wheel scrolls back, Esc reaches claude`));
      const warp = el("button", "", "Open in Warp");
      warp.title = "tmux attach to this chat in a Warp tab";
      warp.onclick = () => act("pane-warp", { slug: it.slug }).then(r => { if (r.ok) toast(`${it.slug} → Warp tab (same chat)`); });
      tb.appendChild(warp);
      const max = el("button", "max-btn", "");
      max.id = "pane-max-btn";
      max.title = "Fill the page with this chat (⌘⇧⏎ toggles; Esc stays claude's)";
      max.onclick = () => { togglePaneMax(); chatTerm.focus(); };
      tb.appendChild(max);
      chatTerm.connect(it.slug);
      if (wantsTermFocus === it.slug) focusChatTermSoon(it.slug);
    } else {
      wrap.hidden = true;
      chatTerm.disconnect();
      const pane = el("div", "chat-pane");
      const inner = el("div", "");
      if (it.live) {
        inner.innerHTML = `<strong>This item's chat runs outside the GUI</strong> (a Warp tab).<br>` +
          `Its status shows on the left. Once it ends, Resume takes it over here.`;
      } else {
        inner.innerHTML = `<strong>No live chat.</strong><br>Resume continues the latest session here; Start opens a fresh one.`;
        const acts = el("div", "pane-acts");
        const rb = el("button", "act strong", "▸ Resume here"); rb.onclick = () => paneAction("pane-resume", it);
        const sb = el("button", "act", "Start fresh"); sb.onclick = () => paneAction("pane-start", it);
        acts.append(rb, sb);
        inner.appendChild(acts);
      }
      pane.appendChild(inner);
      body.appendChild(pane);
    }

    const sess = it.sessionList || [];
    const ss = el("div", "chat-sessions");
    const h = el("h3", "", "Sessions"); h.appendChild(el("span", "n", String(sess.length)));
    if (hasPane) {
      // Under a live pane the history is secondary: collapsed, one click away.
      const d = el("details");
      d.open = !!sessionsOpen[it.slug];
      d.ontoggle = () => { sessionsOpen[it.slug] = d.open; };
      const sum = el("summary"); sum.appendChild(h); d.appendChild(sum);
      sess.forEach(se => d.appendChild(sessionRow(it, se, null)));
      ss.appendChild(d);
    } else {
      ss.appendChild(h);
      if (!sess.length) ss.appendChild(el("div", "desc-text", "No sessions yet. Start one with n."));
      sess.forEach(se => ss.appendChild(sessionRow(it, se, "pane")));
    }
    body.appendChild(ss);
    applyPaneMax();
  }, sameSubject(body, chatSlug));
}
