/* Idan's Money Club - service worker v4.3.1
   Network-first for the app itself so every publish reaches everyone
   automatically; cache fallback keeps it opening offline. */
const VERSION = "imc-v4.3.1";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

/* 18.8: addAll() is atomic - one 404 in SHELL and the whole install rejects,
   which means no offline cache at all, silently. Each file is cached on its
   own now, so a missing icon costs an icon and not the feature. */
self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(VERSION)
      .then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  // live data + firebase: always network, never cached here
  if (url.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request).then(r => {
      const copy = r.clone();
      caches.open(VERSION).then(c => c.put(e.request, copy)).catch(() => {});
      return r;
    }).catch(() => caches.match(e.request, {ignoreSearch: true}))
  );
});
