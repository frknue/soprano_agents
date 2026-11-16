// Pieces shared by screens: top bar, status pill, connection dot.

import { h, icon, iconButton } from '../dom.js';
import { compactDuration, STATUS_LABELS, time } from '../model.js';
import { back } from '../nav.js';
import { store } from '../store.js';

/** Screen top bar. `backTo`: fallback hash for the back button (none on the inbox). */
export function topbar({ title, subtitle = null, backTo = null, actions = [], large = false }) {
  return h('header', { class: `topbar${large ? ' large' : ''}` },
    h('div', { class: 'topbar-row' },
      backTo != null ? iconButton('back', 'Back', () => back(backTo), 'back-button') : null,
      h('div', { class: 'topbar-title' },
        large ? h('h1', null, title, connectionDot()) : h('h1', { text: title }),
        subtitle ? h('div', { class: 'topbar-subtitle' }, subtitle) : null),
      h('div', { class: 'topbar-actions' }, actions)));
}

export function connectionDot() {
  const dot = h('span', { class: 'conn-dot', role: 'img' });
  updateConnectionDot(dot);
  return dot;
}

export function updateConnectionDot(dot) {
  const status = store.connection;
  dot.dataset.status = status;
  const label = status === 'open' ? 'Connected' : status === 'connecting' ? 'Connecting' : 'Disconnected';
  dot.setAttribute('aria-label', label);
  dot.title = label;
}

/** Status pill for a ThreadSummary; idle shows nothing (callers show a relative time). */
export function statusPill(summary) {
  const status = summary?.status;
  if (!status || status === 'idle') return null;
  const pill = h('span', { class: `pill pill-${status}` });
  if (status === 'working') {
    pill.append(icon('circleDashed', { size: 13, cls: 'spin' }), h('span', { text: 'Working' }));
    if (summary.workingSince) {
      pill.append(h('span', { class: 'pill-time', dataset: { since: summary.workingSince }, text: compactDuration(Date.now() - time(summary.workingSince)) }));
    }
  } else {
    pill.append(h('span', { text: STATUS_LABELS[status] ?? status }));
  }
  return pill;
}

export function loading(label = 'Loading…') {
  return h('div', { class: 'placeholder', role: 'status' }, h('span', { class: 'spinner' }), h('span', { text: label }));
}

export function failure(message, retry) {
  return h('div', { class: 'placeholder' },
    icon('alert', { size: 22 }),
    h('p', { text: message }),
    retry ? h('button', { type: 'button', class: 'button', onclick: retry }, 'Try again') : null);
}
