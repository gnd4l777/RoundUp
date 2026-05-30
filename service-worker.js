/* RoundUp service worker
 * Purpose: makes RoundUp installable as an app and serves a basic offline shell.
 * NOTE FOR DEVELOPER: This caches the static front-end only. Do NOT cache API
 * responses that contain user data, money, or credential info — always fetch
 * those live from the backend. Bump CACHE_VERSION on every deploy.
 */
const CACHE_VERSION = 'roundup-v1';
const CORE_ASSETS = [
  '/',
  '/index.html',
  '/manifest.json'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(CORE_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  // Only handle GET navigation/static requests. Never intercept API/auth/payment calls.
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.pathname.startsWith('/api') || url.pathname.startsWith('/auth') || url.pathname.startsWith('/rest')) {
    return; // let these go straight to the network, never cached
  }
  event.respondWith(
    caches.match(req).then((cached) => cached || fetch(req).catch(() => caches.match('/index.html')))
  );
});
