"use strict";

/* ------- usage limits chip (header) ------- */
/* The account's 5h and weekly limits as the status line last wrote them
   (rateLimits in the state; nil until a status line has run). Countdowns
   come from resetsAt, so they stay right however old the capture is; past
   LIMITS_STALE_MS the whole chip greys and says how old it is. */
const LIMITS_STALE_MS = 6 * 3600 * 1000;

function limitsLeft(ms, days) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (days && s >= 86400) return `${Math.floor(s / 86400)}d${Math.floor((s % 86400) / 3600)}h`;
  return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
}

function limitsAge(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 60) return `${m}m`;
  if (m < 48 * 60) return `${Math.floor(m / 60)}h`;
  return `${Math.floor(m / 1440)}d`;
}

function limitsSegment(label, w, days, now) {
  if (!w) return null;
  const pct = Math.round(w.usedPercentage);
  const level = pct >= 80 ? "crit" : pct >= 50 ? "warn" : "ok";
  let when = "";
  if (w.resetsAt) {
    const left = Date.parse(w.resetsAt) - now;
    when = left > 0 ? ` · ${limitsLeft(left, days)}` : " · reset";
  }
  return `<span><span class="lim lim-${level}">${label} ${pct}%</span><span class="lim-when">${when}</span></span>`;
}

function renderLimits() {
  const chip = $("#limits-chip");
  if (!chip) return;
  if (!rateLimits) { chip.hidden = true; return; }
  const now = Date.now();
  const parts = [limitsSegment("5h", rateLimits.fiveHour, false, now),
                 limitsSegment("wk", rateLimits.sevenDay, true, now)].filter(Boolean);
  const age = now - Date.parse(rateLimits.capturedAt);
  const stale = age > LIMITS_STALE_MS;
  chip.hidden = !parts.length;
  chip.classList.toggle("stale", stale);
  chip.innerHTML = parts.join('<span class="lim-sep">│</span>') +
    (stale ? `<span class="lim-age">${limitsAge(age)} old</span>` : "");
  chip.title = `Claude usage limits, as a status line last saw them ${limitsAge(age)} ago` +
    (stale ? " — no session has rendered its status line since, so the percentages may be out of date" : "");
}
setInterval(renderLimits, 60 * 1000);
