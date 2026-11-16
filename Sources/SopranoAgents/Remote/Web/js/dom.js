// DOM helpers: element builder, keyed reconciliation, line icons, toasts, sheets.

const PROPS = new Set(['value', 'checked', 'disabled', 'hidden', 'open', 'selected', 'indeterminate', 'multiple']);

/** Builds an element. `props`: class, text, html (trusted markup only), style object, dataset, on<event>, DOM props, attributes. */
export function h(tag, props = null, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value == null || value === false) continue;
      if (key === 'class') el.className = value;
      else if (key === 'text') el.textContent = value;
      else if (key === 'html') el.innerHTML = value;
      else if (key === 'style' && typeof value === 'object') {
        for (const [name, style] of Object.entries(value)) el.style.setProperty(name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`), style);
      }
      else if (key === 'dataset') Object.assign(el.dataset, value);
      else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2).toLowerCase(), value);
      else if (PROPS.has(key)) el[key] = value;
      else el.setAttribute(key, value === true ? '' : String(value));
    }
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const child of children) {
    if (child == null || child === false || child === true) continue;
    if (Array.isArray(child)) append(el, child);
    else el.append(child instanceof Node ? child : String(child));
  }
}

/**
 * Keeps `parent`'s children in the order of `entries` ({key, sig, build}), reusing an element whose
 * key and signature are unchanged and rebuilding the rest.
 */
export function reconcile(parent, entries) {
  const old = new Map();
  for (const el of [...parent.children]) old.set(el._key, el);
  const next = entries.map((entry) => {
    const previous = old.get(entry.key);
    if (previous && previous._sig === entry.sig) {
      old.delete(entry.key);
      return previous;
    }
    const el = entry.build();
    el._key = entry.key;
    el._sig = entry.sig;
    return el;
  });
  for (const el of old.values()) el.remove();
  next.forEach((el, index) => {
    if (parent.children[index] !== el) parent.insertBefore(el, parent.children[index] ?? null);
  });
}

// Line icons (24×24 grid, stroked with currentColor), drawn for this app in the SF Symbols spirit.

function gearPath() {
  const teeth = 8;
  const outer = 9.6;
  const inner = 7.4;
  const points = [];
  for (let i = 0; i < teeth; i++) {
    const base = (i / teeth) * Math.PI * 2;
    const step = (Math.PI * 2) / teeth;
    for (const [fraction, radius] of [[0.08, inner], [0.2, outer], [0.42, outer], [0.54, inner]]) {
      const angle = base + step * fraction;
      points.push(`${(12 + radius * Math.cos(angle)).toFixed(2)} ${(12 + radius * Math.sin(angle)).toFixed(2)}`);
    }
  }
  return `<path d="M${points.join('L')}Z"/><circle cx="12" cy="12" r="2.8"/>`;
}

const ICONS = {
  back: '<path d="M15 5l-7 7 7 7"/>',
  chevronDown: '<path d="M6 9l6 6 6-6"/>',
  chevronRight: '<path d="M9 6l6 6-6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  compose: '<path d="M11 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20h11a2.5 2.5 0 0 0 2.5-2.5V13"/><path d="M17.6 3.6a2 2 0 0 1 2.8 2.8L12 14.8l-3.6.8.8-3.6z"/>',
  more: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  gear: gearPath(),
  terminal: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7.5 9.5l3 2.5-3 2.5M13 15h3.5"/>',
  branch: '<circle cx="6.5" cy="5.5" r="2"/><circle cx="6.5" cy="18.5" r="2"/><circle cx="17.5" cy="7.5" r="2"/><path d="M6.5 7.5v9M17.5 9.5v.5a5 5 0 0 1-5 5H8"/>',
  worktree: '<path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h3l2 2h6A2.5 2.5 0 0 1 20 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/><path d="M12 11v5M9.5 13.5h5"/>',
  folder: '<path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h3l2 2h6A2.5 2.5 0 0 1 20 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/>',
  diff: '<path d="M7.5 4v6M4.5 7h6M13.5 18h6M18 4.5L6 19.5"/>',
  git: '<circle cx="12" cy="12" r="3"/><path d="M3 12h6M15 12h6"/>',
  pin: '<path d="M9.5 4h5l-.8 4.8 3.3 3.2V14H7v-2l3.3-3.2z"/><path d="M12 14v6"/>',
  archive: '<rect x="3.5" y="4.5" width="17" height="4" rx="1"/><path d="M5 8.5v9A2.5 2.5 0 0 0 7.5 20h9a2.5 2.5 0 0 0 2.5-2.5v-9M10 12.5h4"/>',
  settle: '<circle cx="12" cy="12" r="8.5"/><path d="M8.3 12.4l2.5 2.5 5-5.4"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  x: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none"/>',
  send: '<path d="M12 19V5.5M6 11l6-6 6 6"/>',
  circleDashed: '<circle cx="12" cy="12" r="7.5" stroke-dasharray="2.9 3"/>',
  alert: '<path d="M10.3 4.6L3.2 17.5A2 2 0 0 0 5 20.5h14a2 2 0 0 0 1.8-3L13.7 4.6a2 2 0 0 0-3.4 0z"/><path d="M12 9.5v4M12 17v.01"/>',
  question: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.6a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .8-1 1.5v.4M12 16.8v.01"/>',
  file: '<path d="M13.5 3.5H7.5A2 2 0 0 0 5.5 5.5v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8.5z"/><path d="M13.5 3.5v5h5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>',
  globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.4 3.5 5.2 3.5 8.5s-1.1 6.1-3.5 8.5c-2.4-2.4-3.5-5.2-3.5-8.5s1.1-6.1 3.5-8.5z"/>',
  tool: '<path d="M14.5 4.2a4.5 4.5 0 0 0-4.9 6.3L4.3 15.8a1.9 1.9 0 0 0 2.7 2.7l5.3-5.3a4.5 4.5 0 0 0 6.3-4.9l-2.6 2.6-2.4-.6-.6-2.4z"/>',
  bulb: '<path d="M9.5 17.5h5M10.5 20.5h3"/><path d="M12 3.5a5.5 5.5 0 0 0-3.3 9.9c.7.5 1 1.3 1 2.1v.5h4.6v-.5c0-.8.3-1.6 1-2.1A5.5 5.5 0 0 0 12 3.5z"/>',
  external: '<path d="M13.5 4.5h6v6M19.5 4.5l-8 8M17.5 14v3.5a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2H10"/>',
  trash: '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l.8 12a1.5 1.5 0 0 0 1.5 1.5h6.4a1.5 1.5 0 0 0 1.5-1.5l.8-12"/>',
  paperclip: '<path d="M19.5 11.5l-7.6 7.6a4.6 4.6 0 0 1-6.5-6.5l8-8a3 3 0 0 1 4.3 4.3l-7.9 7.9a1.5 1.5 0 0 1-2.1-2.1l7.2-7.2"/>',
  image: '<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="9.5" r="1.6"/><path d="M20.5 15.5l-4.8-4.8a1.5 1.5 0 0 0-2.1 0L5 19.4"/>',
  refresh: '<path d="M19.5 11.5a7.5 7.5 0 1 0-2.2 5.3"/><path d="M19.5 4.5v7h-7"/>',
  bell: '<path d="M6.5 16v-5a5.5 5.5 0 0 1 11 0v5l1.5 2h-14z"/><path d="M10 20.5h4"/>',
  person: '<circle cx="12" cy="8.5" r="3.8"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0"/>',
  note: '<path d="M4.5 5.5h15v10.5h-9l-4.5 3.5v-3.5h-1.5z"/>',
  info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8v.01"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2"/><path d="M15.5 8.5V6.5a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  keyboard: '<rect x="3" y="6" width="18" height="12" rx="2.5"/><path d="M7 10h.01M10.5 10h.01M14 10h.01M17.5 10h.01M8 14.5h8"/>',
};

/** An inline SVG line icon, decorative unless `label` is given. */
export function icon(name, { size = 20, label = null, cls = '' } = {}) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.7');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('class', `icon ${cls}`.trim());
  if (label) {
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', label);
  } else {
    svg.setAttribute('aria-hidden', 'true');
  }
  svg.innerHTML = ICONS[name] ?? '';
  return svg;
}

/** A 44 pt icon-only button. */
export function iconButton(name, label, onClick, cls = '') {
  return h('button', { type: 'button', class: `icon-button ${cls}`.trim(), 'aria-label': label, title: label, onclick: onClick }, icon(name));
}

export function toast(message, { kind = 'info', duration = 4200 } = {}) {
  const host = document.getElementById('toasts');
  if (!host) return;
  const el = h('div', { class: `toast toast-${kind}`, role: kind === 'error' ? 'alert' : 'status' },
    kind === 'error' ? icon('alert', { size: 18 }) : icon('info', { size: 18 }),
    h('span', { text: message }));
  el.addEventListener('click', () => el.remove());
  host.append(el);
  setTimeout(() => {
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 220);
  }, duration);
}

/** Error toast for a failed request. */
export function toastError(error, prefix = '') {
  if (error?.status === 401) return;
  const text = error?.message || String(error);
  toast(prefix ? `${prefix}: ${text}` : text, { kind: 'error' });
}

/** Bottom sheet; returns {close}. `build(close)` returns the sheet's content. */
export function sheet(title, build, { onClose } = {}) {
  const previousFocus = document.activeElement;
  const backdrop = h('div', { class: 'sheet-backdrop' });
  const close = () => {
    document.removeEventListener('keydown', onKey);
    backdrop.classList.add('leaving');
    setTimeout(() => backdrop.remove(), 200);
    onClose?.();
    if (previousFocus instanceof HTMLElement) previousFocus.focus({ preventScroll: true });
  };
  const onKey = (event) => {
    if (event.key === 'Escape') close();
  };
  const titleID = `sheet-title-${Math.random().toString(36).slice(2)}`;
  const panel = h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': titleID },
    h('div', { class: 'sheet-grabber', 'aria-hidden': 'true' }),
    h('div', { class: 'sheet-head' },
      h('h2', { id: titleID, text: title }),
      iconButton('x', 'Close', close)),
    h('div', { class: 'sheet-body' }, build(close)));
  backdrop.append(panel);
  backdrop.addEventListener('click', (event) => {
    if (event.target === backdrop) close();
  });
  document.addEventListener('keydown', onKey);
  document.body.append(backdrop);
  requestAnimationFrame(() => panel.querySelector('button, [href], input, select, textarea')?.focus({ preventScroll: true }));
  return { close };
}

/** Action sheet: a list of {label, icon, onSelect, disabled, destructive}. */
export function actionSheet(title, actions) {
  return sheet(title, (close) => h('div', { class: 'action-list' }, actions.map((action) =>
    h('button', {
      type: 'button',
      class: `action-row${action.destructive ? ' destructive' : ''}`,
      disabled: action.disabled,
      onclick: () => {
        close();
        action.onSelect();
      },
    }, action.icon ? icon(action.icon) : null, h('span', { text: action.label })))));
}

export function spinner(label = 'Loading') {
  return h('span', { class: 'spinner', role: 'status', 'aria-label': label });
}

/** Copies text, falling back to a hidden textarea where the async clipboard is unavailable. */
export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = h('textarea', { class: 'visually-hidden', value: text });
    document.body.append(area);
    area.select();
    document.execCommand('copy');
    area.remove();
  }
  toast('Copied');
}
