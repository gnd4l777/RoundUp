/* RoundUp service worker
 * Strategy: NETWORK-FIRST. Always try to load the freshest version from the
 * network so new deploys show up immediately. Fall back to cache only when
 * the user is offline. Bump CACHE_VERSION on every deploy to purge old caches.
 * NEVER cache backend (Supabase) / API / auth calls — those always go live.
 */
const CACHE_VERSION = 'roundup-v3';
const CORE_ASSETS = ['/', '/index.html', '/manifest.json'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(CORE_ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // Never intercept backend / auth / data calls — always live.
  if (url.hostname.endsWith('supabase.co') ||
      url.pathname.startsWith('/api') ||
      url.pathname.startsWith('/auth') ||
      url.pathname.startsWith('/rest')) {
    return;
  }
  // Network-first: fresh when online, cached fallback when offline.
  event.respondWith(
    fetch(req)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then((cached) => cached || caches.match('/index.html')))
  );
});
