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
