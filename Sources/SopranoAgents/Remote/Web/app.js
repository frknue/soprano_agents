// Entry: pairing, the event stream, the hash router, viewport and service worker.

import { clearToken, onUnauthorized, pair, parsePairCode, token } from './js/api.js';
import { h, toast } from './js/dom.js';
import { compactDuration, relativeTime, time } from './js/model.js';
import { go, noteHashChange, parseHash } from './js/nav.js';
import { mountDiff } from './js/screens/diff.js';
import { mountGit } from './js/screens/git.js';
import { mountInbox } from './js/screens/inbox.js';
import { mountNewThread } from './js/screens/newThread.js';
import { mountPair } from './js/screens/pair.js';
import { onForget } from './js/screens/settings.js';
import { mountTerminal } from './js/screens/terminal.js';
import { mountThread } from './js/screens/thread.js';
import { SSEStream } from './js/sse.js';
import { applyEvent, emit, resetStore, setConnection, store, subscribe } from './js/store.js';

const app = document.getElementById('app');
let screen = null;
let events = null;
let pairMessage = null;

// Viewport: follow the visual viewport so the composer and key bar sit above the keyboard.
function syncViewport() {
  const viewport = window.visualViewport;
  const height = viewport ? viewport.height : window.innerHeight;
  document.documentElement.style.setProperty('--app-height', `${Math.round(height)}px`);
  document.documentElement.style.setProperty('--app-top', `${Math.round(viewport?.offsetTop ?? 0)}px`);
  document.documentElement.classList.toggle('keyboard-open', viewport ? window.innerHeight - viewport.height > 120 : false);
}
window.visualViewport?.addEventListener('resize', syncViewport);
window.visualViewport?.addEventListener('scroll', syncViewport);
window.addEventListener('resize', syncViewport);
syncViewport();

// The status bar / browser chrome tint follows the theme's background.
function syncThemeColor() {
  const meta = document.querySelector('meta[name="theme-color"]');
  const value = getComputedStyle(document.documentElement).getPropertyValue('--background').trim();
  if (meta && value) meta.setAttribute('content', value);
}

function mount(route) {
  screen?.destroy();
  screen = null;
  window.scrollTo(0, 0);
  const { parts, query } = route;
  if (parts[0] === 'thread' && parts[1]) {
    const id = parts[1];
    if (parts[2] === 'diff') screen = mountDiff(app, { id, turn: query.get('turn') });
    else if (parts[2] === 'git') screen = mountGit(app, { id });
    else if (parts[2] === 'terminal') screen = mountTerminal(app, { id, terminalID: query.get('id'), create: query.get('new') === '1' });
    else screen = mountThread(app, { id });
  } else if (parts[0] === 'new') {
    screen = mountNewThread(app);
  } else {
    screen = mountInbox(app);
  }
}

function route() {
  if (!token()) {
    showPair();
    return;
  }
  mount(parseHash());
}

function startEvents() {
  if (events) return;
  events = new SSEStream('/api/events', {
    idleTimeout: 40000,
    onEvent: applyEvent,
    onStatus: setConnection,
  });
  events.start();
}

function stopEvents() {
  events?.stop();
  events = null;
}

function showPair(message = pairMessage) {
  pairMessage = null;
  stopEvents();
  resetStore();
  screen?.destroy();
  screen = mountPair(app, {
    message,
    onPaired: () => {
      toast('Paired with your Mac');
      startEvents();
      if (location.hash && location.hash !== '#/') go('#/', { replace: true });
      else route();
    },
  });
  screen.isPair = true;
}

function signedOut(message) {
  pairMessage = message;
  if (screen?.isPair) return;
  showPair();
}

onUnauthorized(() => {
  // A revoked or unknown token: pair again.
  clearToken();
  signedOut('This device is no longer paired. Pair it again from the Mac.');
});
onForget(() => signedOut(null));

subscribe((topic) => {
  if (topic === 'connection') updateConnectionBanner();
  screen?.update?.(topic);
});

// Connection banner: shown only after a short grace period, so quick reconnects stay invisible.
const banner = h('div', { class: 'connection-banner', role: 'status', hidden: true }, h('span', { class: 'spinner small' }), h('span', { text: 'Reconnecting…' }));
document.body.append(banner);
let bannerTimer = null;
function updateConnectionBanner() {
  clearTimeout(bannerTimer);
  if (store.connection === 'open' || !events) {
    banner.hidden = true;
    return;
  }
  bannerTimer = setTimeout(() => {
    banner.hidden = store.connection === 'open' || !events;
  }, 1500);
}

// Live durations and relative times.
setInterval(() => {
  const now = Date.now();
  for (const el of document.querySelectorAll('[data-since]')) {
    const since = time(el.dataset.since);
    if (!Number.isNaN(since)) el.textContent = compactDuration(now - since);
  }
  for (const el of document.querySelectorAll('[data-rel]')) {
    if (el.dataset.rel) el.textContent = relativeTime(el.dataset.rel, now);
  }
}, 1000);

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') events?.kick();
});
window.addEventListener('online', () => events?.kick({ force: true }));
window.addEventListener('hashchange', () => {
  noteHashChange();
  route();
});

// Service worker: offline shell and push; a notification tap asks us to open a thread.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch((error) => console.warn('Service worker registration failed', error));
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data?.type === 'open' && typeof event.data.url === 'string') {
      const hash = new URL(event.data.url, location.href).hash;
      if (hash && hash !== location.hash) location.hash = hash;
    }
  });
}

async function boot() {
  syncThemeColor();
  window.addEventListener('load', syncThemeColor);
  matchMedia('(prefers-color-scheme: dark)').addEventListener?.('change', syncThemeColor);
  const code = parsePairCode(location.hash);
  if (code && location.hash.includes('pair=')) {
    history.replaceState(null, '', `${location.pathname}#/`);
    app.replaceChildren(h('div', { class: 'placeholder full' }, h('span', { class: 'spinner' }), h('span', { text: 'Pairing with your Mac…' })));
    try {
      await pair(code);
      toast('Paired with your Mac');
    } catch (error) {
      if (!token()) {
        showPair(error.message);
        return;
      }
      toast(error.message, { kind: 'error' });
    }
  }
  if (!token()) {
    showPair();
    return;
  }
  startEvents();
  emit('connection');
  route();
}

boot();
