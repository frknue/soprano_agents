// Inbox: thread sections like the Mac sidebar, a settings gear and a floating New thread button.

import { h, icon, iconButton, reconcile } from '../dom.js';
import { projectTitle, relativeTime, time } from '../model.js';
import { go, threadHash } from '../nav.js';
import { store } from '../store.js';
import { connectionDot, loading, statusPill, updateConnectionDot } from './common.js';
import { openSettings } from './settings.js';

const SECTIONS = [
  ['pinned', 'Pinned'],
  ['working', 'Working'],
  ['blocked', 'Blocked'],
  ['failed', 'Failed'],
  ['done', 'Done'],
  ['idle', 'Idle'],
  ['settled', 'Settled'],
  ['team', 'Team'],
];

const COLLAPSED_KEY = 'soprano.collapsedSections';

function collapsedSections() {
  try {
    const stored = JSON.parse(localStorage.getItem(COLLAPSED_KEY));
    if (Array.isArray(stored)) return new Set(stored);
  } catch {
    // Default below.
  }
  return new Set(['settled']);
}

function saveCollapsed(set) {
  localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...set]));
}

/** The preview line without Markdown syntax (it is often the start of a final answer). */
function plainPreview(text) {
  return text
    .replace(/```[^\n]*\n?/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__|~~|`)/g, '')
    .replace(/^\s{0,3}(#{1,6}\s+|>\s?)/gm, '')
    .replace(/(^|\s)[-*+]\s+\[[ xX]\](?=\s)/g, '$1•')
    .replace(/\s+/g, ' ')
    .trim();
}

function row(summary) {
  const project = projectTitle(store.state, summary.projectID);
  const pill = statusPill(summary);
  const meta = [];
  if (summary.teammate && summary.teammate !== summary.title) meta.push(h('span', { class: 'meta-item' }, icon('person', { size: 13 }), h('span', { text: summary.teammate })));
  if (project) meta.push(h('span', { class: 'meta-item' }, icon('folder', { size: 13 }), h('span', { text: project })));
  if (summary.branch) {
    meta.push(h('span', { class: 'meta-item' }, icon(summary.worktree ? 'worktree' : 'branch', { size: 13 }),
      h('span', { text: summary.branch })));
  } else if (summary.worktree) {
    meta.push(h('span', { class: 'meta-item' }, icon('worktree', { size: 13 }), h('span', { text: 'Worktree' })));
  }
  const date = summary.activityDate ?? summary.updatedAt;
  return h('a', { class: `thread-row status-${summary.status ?? 'idle'}`, href: threadHash(summary.id) },
    h('div', { class: 'thread-row-top' },
      summary.pinned ? icon('pin', { size: 13, cls: 'pinned-icon', label: 'Pinned' }) : null,
      h('span', { class: 'thread-title', text: summary.title || 'New thread' }),
      pill,
      h('time', { class: 'rel-time', dateTime: date ?? '', dataset: { rel: date ?? '' }, text: relativeTime(date) })),
    summary.preview ? h('div', { class: 'thread-preview', text: plainPreview(summary.preview) }) : null,
    meta.length ? h('div', { class: 'thread-meta' }, meta) : null);
}

export function mountInbox(root) {
  const collapsed = collapsedSections();
  const dot = connectionDot();
  const list = h('div', { class: 'inbox-list' });
  const main = h('main', { class: 'scroll inbox-scroll' }, list);
  const header = h('header', { class: 'topbar large' },
    h('div', { class: 'topbar-row' },
      h('div', { class: 'topbar-title' },
        h('h1', null, 'Threads', dot),
        h('div', { class: 'topbar-subtitle host' })),
      h('div', { class: 'topbar-actions' }, iconButton('gear', 'Settings', () => openSettings()))));
  const fab = h('button', { type: 'button', class: 'fab', onclick: () => go('#/new') }, icon('compose', { size: 20 }), h('span', { text: 'New thread' }));
  const screen = h('div', { class: 'screen inbox' }, header, main, fab);
  root.replaceChildren(screen);

  const render = () => {
    const state = store.state;
    header.querySelector('.host').textContent = state?.host ?? '';
    if (!state) {
      list.replaceChildren(loading('Connecting to your Mac…'));
      list._key = null;
      return;
    }
    list.querySelector(':scope > .placeholder')?.remove();
    const threads = state.threads ?? [];
    const entries = [];
    for (const [id, title] of SECTIONS) {
      let members = threads.filter((t) => t.section === id);
      if (!members.length) continue;
      if (id !== 'team') members = [...members].sort((a, b) => (time(b.activityDate ?? b.updatedAt) || 0) - (time(a.activityDate ?? a.updatedAt) || 0));
      const isCollapsed = collapsed.has(id);
      const sig = JSON.stringify([isCollapsed, members, state.projects?.map((p) => [p.id, p.title])]);
      entries.push({
        key: id,
        sig,
        build: () => {
          const bodyID = `section-${id}`;
          const toggle = h('button', {
            type: 'button',
            class: 'section-head',
            'aria-expanded': String(!isCollapsed),
            'aria-controls': bodyID,
            onclick: () => {
              if (collapsed.has(id)) collapsed.delete(id);
              else collapsed.add(id);
              saveCollapsed(collapsed);
              render();
            },
          }, h('span', { class: 'section-title', text: title }), h('span', { class: 'section-count', text: String(members.length) }),
          icon('chevronDown', { size: 14, cls: `section-chevron${isCollapsed ? ' collapsed' : ''}` }));
          return h('section', { class: `inbox-section section-${id}`, 'aria-label': title },
            toggle,
            isCollapsed ? null : h('div', { class: 'section-body', id: bodyID }, members.map(row)));
        },
      });
    }
    if (!entries.length) {
      entries.push({
        key: 'empty',
        sig: 'empty',
        build: () => h('div', { class: 'placeholder' },
          icon('compose', { size: 24 }),
          h('p', { text: 'No threads yet.' }),
          h('button', { type: 'button', class: 'button primary', onclick: () => go('#/new') }, 'Start a thread')),
      });
    }
    reconcile(list, entries);
  };

  render();
  return {
    update(topic) {
      if (topic === 'state') render();
      if (topic === 'connection') updateConnectionDot(dot);
    },
    destroy() {},
  };
}
