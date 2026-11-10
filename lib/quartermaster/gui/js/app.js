"use strict";

/* ------- the installed app: offline page (sw.js) and Dock badge ------- */
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(e => console.warn("qm: service worker not registered", e));
}

/* The Dock badge shows the tab title's count (updateTitleCount); a plain tab has no badge to set. */
let appBadgeCount = null;
function updateAppBadge(count) {
  if (count === appBadgeCount || !("setAppBadge" in navigator)) return;
  appBadgeCount = count;
  (count ? navigator.setAppBadge(count) : navigator.clearAppBadge()).catch(e => console.warn("qm: app badge", e));
}

/* Installed, Chrome opens outside links in its own window, never the default browser, so the
   app hands them to the server's macOS `open` (open-url): target=_blank clicks and window.open.
   A plain tab, a modifier click and a same-origin link are left alone; a failed hand-off opens as before. */
const runsAsApp = window.matchMedia("(display-mode: standalone)").matches;
const browserOpen = window.open.bind(window);

function outsideUrl(href) {
  try {
    const u = new URL(href, location.href);
    return /^https?:$/.test(u.protocol) && u.origin !== location.origin ? u.href : null;
  } catch (e) { return null; }
}

function openOutside(url, fallback) {
  fetch("/api/action", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ cmd: "open-url", slug: null, args: { url } }),
  }).then(r => r.json()).then(res => { if (!res || !res.ok) throw new Error((res && res.error) || "open-url failed"); })
    .catch(e => { console.warn("qm: opening in this window instead", e); fallback(); });
}

if (runsAsApp) {
  window.open = (url, target, features) => {
    const outside = url != null && outsideUrl(String(url));
    if (!outside) return browserOpen(url, target, features);
    openOutside(outside, () => browserOpen(url, target, features));
    return null;
  };
  document.addEventListener("click", e => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest('a[target="_blank"][href]');
    const outside = a && outsideUrl(a.href);
    if (!outside) return;
    e.preventDefault();
    openOutside(outside, () => browserOpen(outside, "_blank", "noopener"));
  }, true);
}
