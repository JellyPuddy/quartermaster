"use strict";

/* ------- server bridge ------- */
/* While the server is refetching expired PR states in the background it serves
   the stale ones and flags "refreshing"; poll until the flag clears so the
   fresh badges appear without a manual reload. One shared timer — refresh()
   runs after every action too, and stacked polls would hammer the server. */
let prPollTimer = null;
function schedulePrPoll(refreshing) {
  clearTimeout(prPollTimer);
  prPollTimer = refreshing ? setTimeout(refresh, 1500) : null;
}

async function refresh() {
  try {
    const r = await fetch("/api/state");
    const st = await r.json();
    items = st.items; inbox = st.inbox; PROJECTS = st.projects;
    DEFAULT_PROJECT = st.defaultProject || null; LOOSE_STARTERS = st.looseStarters || [];
    distilling = st.distilling || [];
    attention = st.attention || [];
    looseChats = st.loose || [];
    noticeTurns(st.notifications || []);
    noticeDraftsInState(items);
    noticeIssuesInState(items);
    lastPulse = st.pulse;
    (st.distilled || []).forEach(d => {
      if (d.ok) toast(`${d.sessions} snapshot(s) added to ${d.slug}`);
      else toast(`distill of ${d.slug} failed: ${d.error}`, false);
    });
    pf = st.pf || { running: false };
    caffeinate = st.caffeinate || { on: false, mode: "off" };
    rateLimits = st.rateLimits || null;
    jobs = st.jobs || [];
    buildProgress = st.buildProgress || {};
    buildActive = st.buildActive || [];
    noticeBenchmarkBusy(st.benchmark || null);
    panes = st.panes || [];
    if (st.asideModels) asideModels = st.asideModels;
    if (st.terminalToken) terminalToken = st.terminalToken;
    (st.finished || []).forEach(jobFinished);
    // Distills and jobs finish on the server without a request from us — keep polling while one runs.
    schedulePrPoll(st.refreshing || distilling.length > 0 || jobs.length > 0);
  } catch (e) { toast("could not reach qm — is the tab still connected?", false); return; }
  render();
  if (detailSlug) {
    const it = items.find(i => i.slug === detailSlug);
    if (it) openDetail(it); else closeDetail();
  }
}

/* Off the chat view, or in a hidden tab, only whose move it is matters: the
   tab title's count and the notifications. Nothing renders, so nothing
   half-typed on the board or in the detail sheet is redrawn under the user. */
async function refreshAttention() {
  try {
    const st = await (await fetch("/api/attention")).json();
    attention = st.attention || [];
    looseChats = st.loose || [];
    noticeTurns(st.notifications || []);
    noticeDraftCounts(st.draftCounts);
  } catch (e) { /* the next pulse tries again */ }
}

async function act(cmd, opts = {}) {
  const { slug = null, args = {} } = opts;
  try {
    const r = await fetch("/api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cmd, slug, args }),
    });
    const res = await r.json();
    if (!res || !res.ok) {
      // needs_confirmation / needs_force are the caller's to handle (a confirm dialog), not a failure toast.
      if (!(res && (res.needs_confirmation || res.needs_force))) toast((res && res.error) || "action failed", false);
      return res || { ok: false };
    }
    await refresh();
    return res;
  } catch (e) { toast("network error", false); return { ok: false }; }
}
