// Thread: header with menu, timeline, pending approval/question cards, composer.

import { del, enc, patch, post } from '../api.js';
import { attachmentTray } from '../attachments.js';
import { actionSheet, copyText, h, icon, iconButton, toast, toastError } from '../dom.js';
import { approvalCard, questionCard } from '../cards.js';
import { activeTurn, modelLabel, openTurn, pendingApproval, pendingUserInput, projectTitle } from '../model.js';
import { go, threadHash } from '../nav.js';
import { openThread, refreshThread, store, summaryFor } from '../store.js';
import { renderTimeline } from '../timeline.js';
import { failure, loading, statusPill, topbar } from './common.js';

const DRAFT_PREFIX = 'soprano.draft.';
const MODE_KEY = 'soprano.runningMode';

function composer(threadID) {
  const field = h('textarea', {
    class: 'composer-field',
    rows: 1,
    placeholder: 'Message',
    'aria-label': 'Message',
    enterkeyhint: 'send',
    value: sessionStorage.getItem(DRAFT_PREFIX + threadID) ?? '',
  });
  const send = h('button', { type: 'button', class: 'composer-send', 'aria-label': 'Send' }, icon('send', { size: 20 }));
  const stop = h('button', { type: 'button', class: 'composer-stop', 'aria-label': 'Stop' }, icon('stop', { size: 18 }));
  let mode = localStorage.getItem(MODE_KEY) === 'queue' ? 'queue' : 'steer';
  const modeButtons = ['steer', 'queue'].map((value) => {
    const button = h('button', { type: 'button', role: 'radio', 'aria-checked': String(mode === value), text: value === 'steer' ? 'Steer' : 'Queue' });
    button.addEventListener('click', () => {
      mode = value;
      localStorage.setItem(MODE_KEY, value);
      modeButtons.forEach((b, i) => b.setAttribute('aria-checked', String(['steer', 'queue'][i] === mode)));
    });
    return button;
  });
  const modeSwitch = h('div', { class: 'segmented small', role: 'radiogroup', 'aria-label': 'While the agent works' }, modeButtons);
  let running = false;
  let stopping = false;
  let sending = false;

  const attachments = attachmentTray(threadID, () => sync());
  const root = h('form', { class: 'composer', 'aria-label': 'Composer' },
    attachments.tray,
    field,
    attachments.input,
    h('div', { class: 'composer-bar' }, attachments.button, modeSwitch, h('span', { class: 'spacer' }), stop, send));

  const grow = () => {
    field.style.height = 'auto';
    const line = parseFloat(getComputedStyle(field).lineHeight) || 22;
    field.style.height = `${Math.min(field.scrollHeight, line * 6 + 16)}px`;
  };
  function sync() {
    const hasContent = field.value.trim().length > 0 || attachments.ids().length > 0;
    send.disabled = !hasContent || sending || attachments.busy();
    send.hidden = running && !hasContent && !attachments.busy();
    stop.hidden = !running;
    stop.disabled = stopping;
    stop.setAttribute('aria-label', stopping ? 'Stopping' : 'Stop');
    modeSwitch.hidden = !running;
  }

  const submit = async () => {
    const text = field.value.trim();
    const ids = attachments.ids();
    if ((!text && !ids.length) || sending || attachments.busy()) return;
    sending = true;
    sync();
    try {
      const body = { text, mode: running ? mode : 'automatic' };
      if (ids.length) body.attachments = ids;
      await post(`/api/threads/${enc(threadID)}/messages`, body);
      field.value = '';
      sessionStorage.removeItem(DRAFT_PREFIX + threadID);
      attachments.clearSent(ids);
      grow();
    } catch (error) {
      toastError(error, 'Could not send');
    } finally {
      sending = false;
      sync();
    }
  };

  field.addEventListener('paste', (event) => attachments.handlePaste(event));

  field.addEventListener('input', () => {
    sessionStorage.setItem(DRAFT_PREFIX + threadID, field.value);
    grow();
    sync();
  });
  field.addEventListener('keydown', (event) => {
    // Hardware keyboards: ⌘↩ / Ctrl↩ sends; plain Return makes a new line like the iOS keyboard.
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      submit();
    }
  });
  root.addEventListener('submit', (event) => {
    event.preventDefault();
    submit();
  });
  send.addEventListener('click', submit);
  stop.addEventListener('click', async () => {
    stopping = true;
    sync();
    try {
      await post(`/api/threads/${enc(threadID)}/interrupt`);
    } catch (error) {
      stopping = false;
      sync();
      toastError(error, 'Could not stop');
    }
  });

  requestAnimationFrame(grow);
  sync();
  return {
    el: root,
    setRunning(value, stopRequested) {
      running = value;
      stopping = Boolean(stopRequested);
      sync();
    },
    destroy() {
      attachments.destroy();
    },
  };
}

export function mountThread(root, { id }) {
  const timeline = h('div', { class: 'timeline' });
  const scroller = h('main', { class: 'scroll thread-scroll' }, h('div', { class: 'lane' }, timeline));
  const pending = h('div', { class: 'pending' });
  const compose = composer(id);
  const dock = h('div', { class: 'dock' }, pending, compose.el);
  const headerHost = h('div');
  const screen = h('div', { class: 'screen thread' }, headerHost, scroller, dock);
  root.replaceChildren(screen);

  let atBottom = true;
  let firstRender = true;
  let pendingKey = null;
  let visitedKey = null;
  let headerSig = null;

  scroller.addEventListener('scroll', () => {
    atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;
  }, { passive: true });
  const keepBottom = () => {
    if (atBottom) scroller.scrollTop = scroller.scrollHeight;
  };
  const resizeObserver = new ResizeObserver(keepBottom);
  resizeObserver.observe(scroller);
  resizeObserver.observe(timeline);

  timeline.addEventListener('click', (event) => {
    const copy = event.target.closest('.code-copy');
    if (copy) copyText(copy.closest('.code-block').querySelector('code').textContent);
  });

  const markVisited = () => post(`/api/threads/${enc(id)}/visited`).catch(() => {});

  const queueActions = {
    sendNow: (messageID) => post(`/api/threads/${enc(id)}/queue/${enc(messageID)}/send`).catch((error) => toastError(error, 'Could not send')),
    remove: (messageID) => del(`/api/threads/${enc(id)}/queue/${enc(messageID)}`).catch((error) => toastError(error, 'Could not remove')),
  };

  const runMenu = () => {
    const summary = summaryFor(id);
    const teammate = Boolean(store.thread?.thread?.teammate);
    const setFlag = (body, done) => patch(`/api/threads/${enc(id)}`, body).then(done).catch((error) => toastError(error));
    actionSheet(summary?.title ?? 'Thread', [
      { label: 'Diff', icon: 'diff', onSelect: () => go(threadHash(id, 'diff')) },
      { label: 'Git', icon: 'branch', onSelect: () => go(threadHash(id, 'git')) },
      { label: 'Terminal', icon: 'terminal', onSelect: () => go(threadHash(id, 'terminal')) },
      { label: summary?.pinned ? 'Unpin' : 'Pin', icon: 'pin', disabled: teammate, onSelect: () => setFlag({ pinned: !summary?.pinned }) },
      { label: summary?.settled ? 'Unsettle' : 'Settle', icon: 'settle', disabled: teammate, onSelect: () => setFlag({ settled: !summary?.settled }) },
      { label: 'Archive', icon: 'archive', disabled: teammate, destructive: true, onSelect: () => setFlag({ archived: true }, () => { toast('Thread archived'); go('#/', { replace: true }); }) },
    ]);
  };

  const renderHeader = () => {
    const thread = store.thread?.thread;
    const summary = summaryFor(id);
    const sig = JSON.stringify([summary?.title ?? thread?.title, summary?.status, summary?.workingSince, thread?.modelSelection, thread?.projectID, store.state?.providers?.length]);
    if (sig === headerSig) return;
    headerSig = sig;
    const project = projectTitle(store.state, thread?.projectID ?? summary?.projectID);
    const model = thread ? modelLabel(thread.modelSelection, store.state?.providers) : '';
    headerHost.replaceChildren(topbar({
      title: summary?.title ?? thread?.title ?? 'Thread',
      subtitle: [
        project ? h('span', { class: 'subtitle-item', text: project }) : null,
        model ? h('span', { class: 'model-chip', text: model }) : null,
        statusPill(summary),
      ],
      backTo: '#/',
      actions: [iconButton('more', 'Thread actions', runMenu)],
    }));
  };

  const renderPending = (thread) => {
    const turn = openTurn(thread);
    const approval = pendingApproval(turn);
    const question = pendingUserInput(turn);
    const key = JSON.stringify([approval?.id, question?.id]);
    if (key === pendingKey) return;
    pendingKey = key;
    const cards = [];
    if (approval) cards.push(approvalCard(id, approval));
    if (question) {
      const holder = h('div');
      const draw = () => holder.replaceChildren(questionCard(id, question, draw));
      draw();
      cards.push(holder);
    }
    pending.replaceChildren(...cards);
  };

  const render = () => {
    renderHeader();
    const body = store.thread;
    if (!body || body.thread?.id !== id) {
      if (store.threadError) {
        timeline.replaceChildren(failure(store.threadError.status === 404 ? 'This thread no longer exists.' : store.threadError.message, () => refreshThread()));
      } else if (!timeline.querySelector('.placeholder')) {
        timeline.replaceChildren(loading());
      }
      return;
    }
    timeline.querySelector(':scope > .placeholder')?.remove();
    const thread = body.thread;
    const wasAtBottom = atBottom;
    renderTimeline(timeline, thread, queueActions);
    renderPending(thread);
    const active = activeTurn(thread);
    compose.setRunning(Boolean(active), active?.stopRequestedAt);
    if (firstRender || wasAtBottom) {
      scroller.scrollTop = scroller.scrollHeight;
      atBottom = true;
    }
    firstRender = false;
    // New answers while shown: mark the thread seen again.
    const summary = summaryFor(id);
    const last = thread.turns.at(-1);
    const key = last ? `${last.id}:${last.completedAt ?? last.yieldedAt ?? ''}:${summary?.status}` : null;
    if (document.visibilityState === 'visible' && (summary?.status === 'done' || summary?.status === 'failed') && key !== visitedKey) {
      visitedKey = key;
      markVisited();
    }
  };

  const onVisible = () => {
    if (document.visibilityState === 'visible') {
      visitedKey = null;
      render();
    }
  };
  document.addEventListener('visibilitychange', onVisible);

  markVisited();
  openThread(id);
  render();

  return {
    update(topic) {
      if (topic === 'thread' || topic === 'state') render();
    },
    destroy() {
      resizeObserver.disconnect();
      compose.destroy();
      document.removeEventListener('visibilitychange', onVisible);
    },
  };
}
