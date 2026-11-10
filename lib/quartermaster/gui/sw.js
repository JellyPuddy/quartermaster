"use strict";

/* The installed app's service worker: a page load that can't reach qm gui shows
   the offline page below instead of the browser's error. It handles navigations
   only; state, assets, CDN scripts and the terminal WebSocket go straight to the
   network, never into a cache. */
const CACHE = "qm-offline-v1";
const OFFLINE_URL = "/__qm-offline";

const OFFLINE_PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>qm — not running</title>
<style>
  :root { --bg: #EBEEF3; --surface: #FFFFFF; --ink: #191C24; --muted: #5D6577; --accent: #4C63D6; --accent-ink: #ffffff; --border: #DCE1EA; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #0F1218; --surface: #171B23; --ink: #E7EAF1; --muted: #9AA3B4; --accent: #8AA0FF; --accent-ink: #0F1218; --border: #262D3A; }
  }
  html, body { height: 100%; }
  body { margin: 0; display: grid; place-items: center; background: var(--bg); color: var(--ink);
         font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  main { max-width: 420px; padding: 28px 32px; background: var(--surface); border: 1px solid var(--border); border-radius: 12px; text-align: center; }
  h1 { margin: 0 0 8px; font-size: 18px; }
  p { margin: 0 0 16px; color: var(--muted); }
  code { font: 13px "SF Mono", ui-monospace, Menlo, monospace; color: var(--ink); background: var(--bg); padding: 2px 6px; border-radius: 4px; }
  button { font: inherit; padding: 6px 14px; border: 0; border-radius: 6px; background: var(--accent); color: var(--accent-ink); cursor: pointer; }
  small { display: block; margin-top: 12px; color: var(--muted); font-size: 12px; }
</style>
</head>
<body>
<main>
  <h1>qm gui isn't running</h1>
  <p>Start it with <code>qm gui</code> in a terminal. This window comes back by itself once it answers.</p>
  <button id="retry" type="button">Retry now</button>
  <small id="status">Checking every 3 seconds…</small>
</main>
<script>
  "use strict";
  async function retry() {
    try {
      const res = await fetch("/api/root", { cache: "no-store" });
      if (res.ok) location.reload();
    } catch (e) {
      document.getElementById("status").textContent = "Still not answering · checking every 3 seconds…";
    }
  }
  document.getElementById("retry").addEventListener("click", retry);
  setInterval(retry, 3000);
</script>
</body>
</html>`;

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.put(OFFLINE_URL, new Response(OFFLINE_PAGE, { headers: { "Content-Type": "text/html; charset=utf-8" } })))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  if (event.request.mode !== "navigate") return;
  event.respondWith(fetch(event.request).catch(() => caches.match(OFFLINE_URL)));
});
