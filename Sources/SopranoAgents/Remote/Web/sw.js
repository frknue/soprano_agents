// Service worker: app shell cache (network first, so a new app version shows at once), vendor files
// cache first, /api/* never cached; push notifications that open their thread.

const CACHE = 'soprano-agents-shell-v3';

const SHELL = [
  '/',
  '/app.css',
  '/app.js',
  '/manifest.webmanifest',
  '/icon-192.png',
  '/icon-512.png',
  '/apple-touch-icon.png',
  '/js/api.js',
  '/js/attachments.js',
  '/js/cards.js',
  '/js/diff.js',
  '/js/dom.js',
  '/js/markdown.js',
  '/js/model.js',
  '/js/nav.js',
  '/js/push.js',
  '/js/sse.js',
  '/js/store.js',
  '/js/timeline.js',
  '/js/screens/common.js',
  '/js/screens/diff.js',
  '/js/screens/git.js',
  '/js/screens/inbox.js',
  '/js/screens/newThread.js',
  '/js/screens/pair.js',
  '/js/screens/settings.js',
  '/js/screens/terminal.js',
  '/js/screens/thread.js',
];

const NETWORK_TIMEOUT = 4000;

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

async function networkFirst(request, cacheKey) {
  const cache = await caches.open(CACHE);
  try {
    // Revalidate past the HTTP cache: a new app version or palette shows on the next load.
    const fresh = request.mode === 'navigate' ? new Request(request.url, { cache: 'no-cache' }) : new Request(request, { cache: 'no-cache' });
    const response = await Promise.race([
      fetch(fresh),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), NETWORK_TIMEOUT)),
    ]);
    if (response.ok && response.type === 'basic') cache.put(cacheKey, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(cacheKey);
    if (cached) return cached;
    throw error;
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok && response.type === 'basic') cache.put(request, response.clone());
  return response;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  // The API (including the event and terminal streams) always goes to the network, never cached.
  if (url.pathname.startsWith('/api/')) return;
  if (url.pathname.startsWith('/vendor/')) {
    event.respondWith(cacheFirst(request));
    return;
  }
  const key = request.mode === 'navigate' ? '/' : url.pathname;
  event.respondWith(networkFirst(request, key));
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = { body: event.data ? event.data.text() : '' };
  }
  const threadID = payload.threadID ?? null;
  const options = {
    body: payload.body ?? '',
    data: { threadID },
    icon: '/icon-192.png',
  };
  if (threadID) options.tag = threadID;
  event.waitUntil(self.registration.showNotification(payload.title || 'Soprano Agents', options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const threadID = event.notification.data?.threadID;
  const url = threadID ? `/#/thread/${encodeURIComponent(threadID)}` : '/';
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin !== self.location.origin) continue;
      await client.focus();
      client.postMessage({ type: 'open', url });
      return;
    }
    await self.clients.openWindow(url);
  })());
});
