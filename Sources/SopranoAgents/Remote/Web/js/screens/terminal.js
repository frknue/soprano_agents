// Terminals: the thread's phone shells (list, create, attach with xterm.js, close).

import { del, enc, get, post } from '../api.js';
import { h, icon, toastError } from '../dom.js';
import { go, threadHash } from '../nav.js';
import { SSEStream } from '../sse.js';
import { store } from '../store.js';
import { failure, loading, topbar } from './common.js';

let assets = null;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`Could not load ${src}`));
    document.head.append(script);
  });
}

/** Loads xterm.js and its fit addon once, on first use. */
function loadXterm() {
  if (!assets) {
    const css = document.createElement('link');
    css.rel = 'stylesheet';
    css.href = '/vendor/xterm.css';
    document.head.append(css);
    assets = loadScript('/vendor/xterm.js').then(() => loadScript('/vendor/addon-fit.js')).catch((error) => {
      assets = null;
      throw error;
    });
  }
  return assets;
}

/** A CSS color value resolved to a form xterm understands (#rrggbb or rgba()). */
function cssColor(name, probe, context) {
  probe.style.color = `var(${name})`;
  const computed = getComputedStyle(probe).color;
  context.fillStyle = '#000';
  context.fillStyle = computed;
  return context.fillStyle;
}

function terminalTheme() {
  const probe = h('span', { hidden: true });
  document.body.append(probe);
  const context = document.createElement('canvas').getContext('2d');
  const color = (name) => cssColor(name, probe, context);
  const ansi = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];
  const theme = {
    background: color('--terminal-background'),
    foreground: color('--terminal-foreground'),
    cursor: color('--terminal-cursor'),
    cursorAccent: color('--terminal-background'),
    selectionBackground: color('--terminal-selection'),
  };
  ansi.forEach((name, index) => {
    theme[name] = color(`--terminal-ansi-${index}`);
    theme[`bright${name[0].toUpperCase()}${name.slice(1)}`] = color(`--terminal-ansi-${index + 8}`);
  });
  probe.remove();
  return theme;
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function terminalsOf(threadID) {
  return store.terminals.get(threadID);
}

function mountList(root, threadID) {
  const content = h('div', { class: 'lane' });
  const newButton = h('button', { type: 'button', class: 'button small', onclick: () => go(threadHash(threadID, 'terminal', 'new=1')) }, icon('plus', { size: 16 }), 'New');
  const screen = h('div', { class: 'screen terminal-list' },
    topbar({ title: 'Terminals', subtitle: store.thread?.thread?.id === threadID ? store.thread.thread.title : null, backTo: threadHash(threadID), actions: [newButton] }),
    h('main', { class: 'scroll' }, content));
  root.replaceChildren(screen);

  const render = () => {
    const terminals = terminalsOf(threadID);
    if (!terminals) {
      content.replaceChildren(loading());
      return;
    }
    if (!terminals.length) {
      content.replaceChildren(h('div', { class: 'placeholder' },
        icon('terminal', { size: 26 }),
        h('p', { text: 'No terminals yet. A new one opens a shell in the thread’s working folder on the Mac.' }),
        h('button', { type: 'button', class: 'button primary', onclick: () => go(threadHash(threadID, 'terminal', 'new=1')) }, 'New terminal')));
      return;
    }
    content.replaceChildren(h('ul', { class: 'list card' }, terminals.map((t) => h('li', null,
      h('a', { class: 'list-row', href: threadHash(threadID, 'terminal', `id=${encodeURIComponent(t.id)}`) },
        icon('terminal', { size: 18 }),
        h('span', { class: 'list-title', text: t.title || 'Shell' }),
        h('span', { class: `chip ${t.running ? 'chip-success' : ''}`, text: t.running ? 'Running' : 'Exited' }),
        icon('chevronRight', { size: 16, cls: 'trailing' }))))));
  };

  let generation = 0;
  const load = async () => {
    const mine = ++generation;
    try {
      const result = await get(`/api/threads/${enc(threadID)}/terminals`);
      if (mine !== generation) return;
      store.terminals.set(threadID, result.terminals ?? []);
      render();
    } catch (error) {
      if (mine !== generation) return;
      content.replaceChildren(failure(error.message, load));
    }
  };
  render();
  load();
  return {
    update(topic) {
      if (topic === 'terminals') render();
    },
    destroy() {
      generation++;
    },
  };
}

const KEYS = [
  ['Esc', '\x1b'],
  ['Tab', '\t'],
  ['Ctrl', null],
  ['↑', 'up'],
  ['↓', 'down'],
  ['←', 'left'],
  ['→', 'right'],
  ['|', '|'],
  ['~', '~'],
  ['/', '/'],
  ['-', '-'],
];

const ARROWS = { up: 'A', down: 'B', right: 'C', left: 'D' };

function mountSession(root, threadID, { terminalID, create }) {
  const surface = h('div', { class: 'terminal-surface' });
  const status = h('div', { class: 'terminal-status', role: 'status' });
  const closeButton = h('button', { type: 'button', class: 'button small ghost danger', text: 'Close' });
  const keybar = h('div', { class: 'keybar', role: 'toolbar', 'aria-label': 'Terminal keys' });
  const screen = h('div', { class: 'screen terminal-session' },
    topbar({ title: 'Terminal', subtitle: store.thread?.thread?.id === threadID ? store.thread.thread.title : null, backTo: threadHash(threadID, 'terminal'), actions: [closeButton] }),
    h('div', { class: 'terminal-wrap' }, surface, status),
    keybar);
  root.replaceChildren(screen);

  let id = terminalID;
  let term = null;
  let fit = null;
  let stream = null;
  let destroyed = false;
  let exited = false;
  let ctrl = false;
  let buffer = '';
  let flushTimer = null;
  let chain = Promise.resolve();
  let resizeTimer = null;
  let lastSize = '';

  const showStatus = (text) => {
    status.textContent = text ?? '';
    status.hidden = !text;
  };
  showStatus('Starting…');

  const flush = () => {
    flushTimer = null;
    if (!buffer || !id || exited) return;
    const data = buffer;
    buffer = '';
    chain = chain.then(() => post(`/api/terminals/${enc(id)}/input`, { data })).catch((error) => toastError(error, 'Input'));
  };
  const send = (data) => {
    if (exited) return;
    if (ctrl && data.length === 1) {
      const code = data.toUpperCase().charCodeAt(0);
      if (code >= 64 && code <= 95) data = String.fromCharCode(code - 64);
      else if (data === ' ') data = '\x00';
      setCtrl(false);
    }
    buffer += data;
    if (!flushTimer) flushTimer = setTimeout(flush, 10);
  };

  const ctrlButton = { el: null };
  const setCtrl = (value) => {
    ctrl = value;
    ctrlButton.el?.setAttribute('aria-pressed', String(value));
  };
  for (const [label, value] of KEYS) {
    const button = h('button', { type: 'button', class: 'key', text: label, 'aria-label': label === 'Ctrl' ? 'Control' : label === 'Esc' ? 'Escape' : undefined });
    // Keep the keyboard up: never let the key bar take focus from the terminal.
    button.addEventListener('pointerdown', (event) => event.preventDefault());
    button.addEventListener('mousedown', (event) => event.preventDefault());
    if (value === null) {
      button.setAttribute('aria-pressed', 'false');
      ctrlButton.el = button;
      button.addEventListener('click', () => setCtrl(!ctrl));
    } else if (ARROWS[value]) {
      button.addEventListener('click', () => {
        const application = term?.modes?.applicationCursorKeysMode;
        send(`\x1b${application ? 'O' : '['}${ARROWS[value]}`);
      });
    } else {
      button.addEventListener('click', () => send(value));
    }
    keybar.append(button);
  }

  const postResize = () => {
    if (!term || !id || exited) return;
    const size = `${term.cols}x${term.rows}`;
    if (size === lastSize) return;
    lastSize = size;
    post(`/api/terminals/${enc(id)}/resize`, { cols: term.cols, rows: term.rows }).catch(() => {});
  };
  const refit = () => {
    if (!fit || destroyed) return;
    try {
      fit.fit();
    } catch {
      // Not laid out yet.
    }
  };
  const resizeObserver = new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(refit, 80);
  });

  let armed = false;
  let armTimer = null;
  closeButton.addEventListener('click', async () => {
    if (!id) return;
    if (!armed) {
      armed = true;
      closeButton.textContent = 'Close shell?';
      armTimer = setTimeout(() => {
        armed = false;
        closeButton.textContent = 'Close';
      }, 3000);
      return;
    }
    clearTimeout(armTimer);
    closeButton.disabled = true;
    try {
      await del(`/api/terminals/${enc(id)}`);
      go(threadHash(threadID, 'terminal'), { replace: true });
    } catch (error) {
      closeButton.disabled = false;
      toastError(error, 'Could not close');
    }
  });

  const connect = () => {
    let reset = false;
    stream = new SSEStream(`/api/terminals/${enc(id)}/output`, {
      onOpen: () => { reset = true; },
      onStatus: (value) => {
        if (exited) return;
        showStatus(value === 'open' ? null : value === 'connecting' ? null : 'Reconnecting…');
      },
      onFatal: (code) => {
        showStatus(code === 404 ? 'This terminal is gone.' : `The terminal stream failed (${code}).`);
      },
      onEvent: (name, data) => {
        if (name === 'output') {
          // Every connection replays the scrollback first.
          if (reset) {
            term.reset();
            reset = false;
          }
          term.write(base64ToBytes(data.data ?? ''));
        } else if (name === 'exit') {
          exited = true;
          stream.stop();
          term.write(`\r\n\x1b[2m[Process exited${data?.code != null ? ` with code ${data.code}` : ''}]\x1b[0m\r\n`);
          showStatus('The shell exited.');
          closeButton.textContent = 'Remove';
          armed = true;
        }
      },
    });
    stream.start();
  };

  const onVisible = () => {
    if (document.visibilityState === 'visible') stream?.kick({ force: true });
  };
  const onOnline = () => stream?.kick({ force: true });
  const onViewport = () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(refit, 80);
  };

  (async () => {
    try {
      await loadXterm();
    } catch (error) {
      if (!destroyed) surface.replaceChildren(failure(error.message));
      return;
    }
    if (destroyed) return;
    term = new window.Terminal({
      fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      lineHeight: 1.15,
      cursorBlink: true,
      scrollback: 5000,
      theme: terminalTheme(),
      allowTransparency: false,
      macOptionIsMeta: true,
    });
    fit = new window.FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(surface);
    refit();
    term.onData(send);
    term.onResize(() => postResize());
    resizeObserver.observe(surface);
    window.visualViewport?.addEventListener('resize', onViewport);
    window.addEventListener('orientationchange', onViewport);
    if (create) {
      try {
        const created = await post(`/api/threads/${enc(threadID)}/terminals`, { cols: term.cols, rows: term.rows });
        if (destroyed) return;
        id = created.id;
        lastSize = `${term.cols}x${term.rows}`;
        history.replaceState(null, '', threadHash(threadID, 'terminal', `id=${encodeURIComponent(id)}`));
      } catch (error) {
        showStatus(null);
        surface.replaceChildren(failure(error.message, () => go(threadHash(threadID, 'terminal'), { replace: true })));
        return;
      }
    } else {
      postResize();
    }
    showStatus(null);
    connect();
    term.focus();
  })();

  document.addEventListener('visibilitychange', onVisible);
  window.addEventListener('online', onOnline);

  return {
    update() {},
    destroy() {
      destroyed = true;
      flush();
      stream?.stop();
      resizeObserver.disconnect();
      clearTimeout(resizeTimer);
      window.visualViewport?.removeEventListener('resize', onViewport);
      window.removeEventListener('orientationchange', onViewport);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('online', onOnline);
      term?.dispose();
    },
  };
}

export function mountTerminal(root, { id, terminalID, create }) {
  if (terminalID || create) return mountSession(root, id, { terminalID, create });
  return mountList(root, id);
}
