// Diff: the thread's (or one turn's) unified diff, per file, with a turn selector.

import { enc, get } from '../api.js';
import { h, iconButton } from '../dom.js';
import { parseDiff, renderDiffFile } from '../diff.js';
import { go, threadHash } from '../nav.js';
import { openThread, store } from '../store.js';
import { failure, loading, topbar } from './common.js';

const COLLAPSE_OVER = 400;

export function mountDiff(root, { id, turn }) {
  const select = h('select', { class: 'field compact', 'aria-label': 'Turn' });
  const toolbar = h('div', { class: 'toolbar' }, select);
  const content = h('div', { class: 'lane diff-lane' });
  const body = h('main', { class: 'scroll' }, content);
  const headerHost = h('div');
  const screen = h('div', { class: 'screen diff-screen' }, headerHost, toolbar, body);
  root.replaceChildren(screen);

  let selectSig = null;
  const renderChrome = () => {
    const thread = store.thread?.thread?.id === id ? store.thread.thread : null;
    headerHost.replaceChildren(topbar({
      title: 'Diff',
      subtitle: thread ? thread.title : null,
      backTo: threadHash(id),
      actions: [iconButton('refresh', 'Reload', load)],
    }));
    const turns = (thread?.turns ?? []).filter((t) => t.checkpoint?.status === 'ready');
    const sig = JSON.stringify([turn, turns.map((t) => [t.ordinal, t.checkpoint.files.length])]);
    if (sig === selectSig) return;
    selectSig = sig;
    const options = [h('option', { value: '', text: 'All turns', selected: turn == null })];
    for (const t of turns) {
      const text = t.userMessage.text.replace(/\s+/g, ' ').trim();
      const label = `Turn ${t.ordinal}${text ? ` · ${text.length > 40 ? `${text.slice(0, 40)}…` : text}` : ''}`;
      options.push(h('option', { value: String(t.ordinal), text: label, selected: String(t.ordinal) === turn }));
    }
    if (turn != null && !turns.some((t) => String(t.ordinal) === turn)) {
      options.push(h('option', { value: turn, text: `Turn ${turn}`, selected: true }));
    }
    select.replaceChildren(...options);
  };

  select.addEventListener('change', () => {
    go(threadHash(id, 'diff', select.value ? `turn=${select.value}` : ''), { replace: true });
  });

  let generation = 0;
  async function load() {
    const mine = ++generation;
    content.replaceChildren(loading('Loading diff…'));
    try {
      const result = await get(`/api/threads/${enc(id)}/diff${turn != null ? `?turn=${enc(turn)}` : ''}`);
      if (mine !== generation) return;
      const files = parseDiff(result?.diff ?? '');
      if (!files.length) {
        content.replaceChildren(h('div', { class: 'placeholder' }, h('p', { text: turn != null ? 'This turn changed no files.' : 'No changes.' })));
        return;
      }
      const additions = files.reduce((sum, f) => sum + f.additions, 0);
      const deletions = files.reduce((sum, f) => sum + f.deletions, 0);
      content.replaceChildren(
        h('div', { class: 'diff-summary' },
          h('span', { text: `${files.length} ${files.length === 1 ? 'file' : 'files'}` }),
          h('span', { class: 'stat-add', text: `+${additions}` }),
          h('span', { class: 'stat-del', text: `−${deletions}` })),
        ...files.map((file) => renderDiffFile(file, { open: file.lines.length <= COLLAPSE_OVER && files.length <= 30 })));
    } catch (error) {
      if (mine !== generation) return;
      content.replaceChildren(failure(error.message, load));
    }
  }

  renderChrome();
  openThread(id);
  load();
  return {
    update(topic) {
      if (topic === 'thread') renderChrome();
    },
    destroy() {
      generation++;
    },
  };
}
