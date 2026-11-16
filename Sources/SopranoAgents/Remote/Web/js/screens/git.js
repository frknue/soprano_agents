// Git: branch status of the thread's workspace and commit / push / PR actions.

import { enc, get, post } from '../api.js';
import { h, icon, iconButton, spinner, toastError } from '../dom.js';
import { threadHash } from '../nav.js';
import { openThread, store } from '../store.js';
import { failure, loading, topbar } from './common.js';

const ACTIONS = [
  ['commit_push', 'Commit & push', 'Committing and pushing…'],
  ['commit', 'Commit', 'Committing…'],
  ['push', 'Push', 'Pushing…'],
  ['commit_push_pr', 'Commit, push & PR', 'Committing, pushing and opening a PR…'],
  ['create_pr', 'Create PR', 'Opening a pull request…'],
];

function enabledActions(status) {
  const hasChanges = (status.files ?? []).length > 0;
  const hasRemote = Boolean(status.hasRemote);
  const openPR = status.pullRequest && String(status.pullRequest.state).toLowerCase() === 'open';
  const nothingToPush = status.hasUpstream && !(status.ahead > 0);
  return {
    commit: hasChanges,
    commit_push: hasChanges && hasRemote,
    commit_push_pr: hasChanges && hasRemote && !openPR,
    push: hasRemote && !nothingToPush,
    create_pr: hasRemote && !openPR,
  };
}

export function mountGit(root, { id }) {
  const content = h('div', { class: 'lane git-lane' });
  const body = h('main', { class: 'scroll' }, content);
  const headerHost = h('div');
  const screen = h('div', { class: 'screen git-screen' }, headerHost, body);
  root.replaceChildren(screen);

  let status = null;
  let running = null;
  let result = null;
  let message = '';
  let featureBranch = null;
  let generation = 0;

  const renderHeader = () => {
    const thread = store.thread?.thread?.id === id ? store.thread.thread : null;
    headerHost.replaceChildren(topbar({
      title: 'Git',
      subtitle: thread?.title ?? null,
      backTo: threadHash(id),
      actions: [iconButton('refresh', 'Reload', () => load())],
    }));
  };

  const run = async (action) => {
    running = action;
    result = null;
    render();
    const body = { action };
    if (message.trim()) body.commitMessage = message.trim();
    if (status.isDefaultBranch) body.featureBranch = Boolean(featureBranch);
    try {
      result = { ok: true, ...(await post(`/api/threads/${enc(id)}/git`, body)) };
      message = '';
    } catch (error) {
      if (error?.status !== 401) result = { ok: false, title: 'The action failed', detail: error.message };
    }
    running = null;
    await load({ quiet: true });
  };

  function render() {
    if (!status) return;
    if (!status.isRepository) {
      content.replaceChildren(h('div', { class: 'placeholder' }, icon('branch', { size: 24 }), h('p', { text: 'This workspace is not a git repository.' })));
      return;
    }
    if (featureBranch == null) featureBranch = Boolean(status.isDefaultBranch);
    const files = status.files ?? [];
    const enabled = enabledActions(status);
    const sync = [];
    if (!status.hasRemote) sync.push('No remote');
    else if (!status.hasUpstream) sync.push('Not pushed yet');
    else {
      if (status.ahead > 0) sync.push(`${status.ahead} ahead`);
      if (status.behind > 0) sync.push(`${status.behind} behind`);
      if (!status.ahead && !status.behind) sync.push('Up to date');
    }
    const pr = status.pullRequest;
    const additions = files.reduce((s, f) => s + f.additions, 0);
    const deletions = files.reduce((s, f) => s + f.deletions, 0);

    const messageField = h('textarea', {
      class: 'field', rows: 2, id: 'commit-message', placeholder: 'Leave empty to generate one', value: message, disabled: Boolean(running),
    });
    messageField.addEventListener('input', () => { message = messageField.value; });

    const featureToggle = status.isDefaultBranch
      ? h('label', { class: 'switch-row' },
        h('span', null, h('span', { class: 'strong', text: 'Create a feature branch' }), h('span', { class: 'form-hint block', text: `Commit on a new branch instead of ${status.branch ?? 'the default branch'}.` })),
        (() => {
          const input = h('input', { type: 'checkbox', role: 'switch', class: 'switch', checked: featureBranch, disabled: Boolean(running) });
          input.addEventListener('change', () => { featureBranch = input.checked; });
          return input;
        })())
      : null;

    content.replaceChildren(...[
      h('section', { class: 'card git-status' },
        h('div', { class: 'git-branch' }, icon('branch', { size: 18 }), h('span', { class: 'strong mono', text: status.branch ?? 'Detached HEAD' }),
          status.isDefaultBranch ? h('span', { class: 'chip', text: 'default' }) : null),
        h('div', { class: 'meta', text: sync.join(' · ') }),
        pr ? h('a', { class: 'pr-link', href: pr.url, target: '_blank', rel: 'noopener noreferrer' },
          icon('external', { size: 16 }), h('span', { text: `#${pr.number} ${pr.title}` }), h('span', { class: `chip pr-${String(pr.state).toLowerCase()}`, text: String(pr.state).toLowerCase() })) : null),
      h('section', { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', { text: files.length ? `${files.length} changed ${files.length === 1 ? 'file' : 'files'}` : 'No uncommitted changes' }),
          files.length ? h('span', { class: 'stats' }, h('span', { class: 'stat-add', text: `+${additions}` }), h('span', { class: 'stat-del', text: `−${deletions}` })) : null),
        files.length ? h('ul', { class: 'file-list' }, files.map((f) => h('li', null,
          h('span', { class: 'mono file-path', text: f.path }),
          h('span', { class: 'stats' }, h('span', { class: 'stat-add', text: `+${f.additions}` }), h('span', { class: 'stat-del', text: `−${f.deletions}` }))))) : null),
      h('section', { class: 'card' },
        h('div', { class: 'form-field' }, h('label', { class: 'form-label', for: 'commit-message', text: 'Commit message' }), messageField),
        featureToggle,
        h('div', { class: 'git-actions' }, ACTIONS.map(([action, label, busyLabel]) => {
          const button = h('button', {
            type: 'button',
            class: `button${action === 'commit_push' ? ' primary' : ''}`,
            disabled: Boolean(running) || !enabled[action],
          });
          if (running === action) button.append(spinner(busyLabel), h('span', { text: busyLabel }));
          else button.textContent = label;
          button.addEventListener('click', () => run(action));
          return button;
        })),
        running ? h('p', { class: 'form-hint', role: 'status', text: 'This can take a minute.' }) : null),
      result ? h('section', { class: `card result ${result.ok ? 'ok' : 'failed'}`, role: 'status' },
        h('div', { class: 'card-head' }, icon(result.ok ? 'check' : 'alert', { size: 18 }), h('h2', { text: result.title ?? (result.ok ? 'Done' : 'Failed') })),
        result.detail ? h('p', { class: 'result-detail', text: result.detail }) : null,
        result.pullRequestURL ? h('a', { class: 'pr-link', href: result.pullRequestURL, target: '_blank', rel: 'noopener noreferrer' }, icon('external', { size: 16 }), h('span', { text: 'Open pull request' })) : null) : null,
    ].filter(Boolean));
  }

  async function load({ quiet = false } = {}) {
    const mine = ++generation;
    if (!quiet || !status) content.replaceChildren(loading('Reading git status…'));
    try {
      const next = await get(`/api/threads/${enc(id)}/git`);
      if (mine !== generation) return;
      status = next;
      render();
    } catch (error) {
      if (mine !== generation) return;
      if (status && quiet) {
        render();
        toastError(error, 'Git status');
      } else {
        content.replaceChildren(failure(error.message, () => load()));
      }
    }
  }

  renderHeader();
  openThread(id);
  load();
  return {
    update(topic) {
      if (topic === 'thread') renderHeader();
    },
    destroy() {
      generation++;
    },
  };
}
