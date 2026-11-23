// Thread: header with menu, timeline, pending approval/question cards, composer.

import { del, enc, patch, post } from '../api.js';
import { attachmentTray } from '../attachments.js';
import { actionSheet, copyText, h, icon, iconButton, toast, toastError } from '../dom.js';
import { approvalCard, questionCard } from '../cards.js';
import { renderMarkdown } from '../markdown.js';
import { activeTurn, modelLabel, openTurn, pendingApproval, pendingUserInput, projectTitle, supportsPlanMode } from '../model.js';
import { go, threadHash } from '../nav.js';
import { loadSideQuestions, openThread, refreshThread, store, summaryFor } from '../store.js';
import { renderTimeline } from '../timeline.js';
import { failure, loading, statusPill, topbar } from './common.js';

const DRAFT_PREFIX = 'soprano.draft.';
const MODE_KEY = 'soprano.runningMode';

function composer(threadID, { onSideQuestion }) {
  const field = h('textarea', {
    class: 'composer-field',
    rows: 1,
    placeholder: 'Message (or /btw …)',
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

  let interactionMode = 'default';
  let planSupported = false;
  const planButtons = [['default', 'Build'], ['plan', 'Plan']].map(([value, label]) => {
    const button = h('button', { type: 'button', role: 'radio', 'aria-checked': String(interactionMode === value), text: label });
    button.addEventListener('click', async () => {
      if (interactionMode === value) return;
      const previous = interactionMode;
      interactionMode = value;
      planButtons.forEach((b, i) => b.setAttribute('aria-checked', String(['default', 'plan'][i] === interactionMode)));
      try {
        await patch(`/api/threads/${enc(threadID)}`, { interactionMode: value });
      } catch (error) {
        interactionMode = previous;
        planButtons.forEach((b, i) => b.setAttribute('aria-checked', String(['default', 'plan'][i] === interactionMode)));
        toastError(error, 'Mode');
      }
    });
    return button;
  });
  const planSwitch = h('div', { class: 'segmented small', role: 'radiogroup', 'aria-label': 'Interaction mode', hidden: true }, planButtons);

  let running = false;
  let stopping = false;
  let sending = false;

  const attachments = attachmentTray(threadID, () => sync());
  const root = h('form', { class: 'composer', 'aria-label': 'Composer' },
    attachments.tray,
    field,
    attachments.input,
    h('div', { class: 'composer-bar' }, attachments.button, planSwitch, modeSwitch, h('span', { class: 'spacer' }), stop, send));

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
    planSwitch.hidden = !planSupported || running;
  }

  const submit = async () => {
    const text = field.value.trim();
    const ids = attachments.ids();
    if ((!text && !ids.length) || sending || attachments.busy()) return;
    if (!ids.length && (text === '/btw' || /^\/btw\s+/i.test(text))) {
      const question = text.replace(/^\/btw\s*/i, '').trim();
      const restored = field.value;
      field.value = '';
      sessionStorage.removeItem(DRAFT_PREFIX + threadID);
      grow();
      sync();
      onSideQuestion(question, () => {
        if (!field.value) {
          field.value = restored;
          sessionStorage.setItem(DRAFT_PREFIX + threadID, restored);
          grow();
          sync();
        }
      });
      return;
    }
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
    setPlanMode(supported, value) {
      planSupported = Boolean(supported);
      interactionMode = value === 'plan' ? 'plan' : 'default';
      planButtons.forEach((b, i) => b.setAttribute('aria-checked', String(['default', 'plan'][i] === interactionMode)));
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
  const sideHost = h('div', { class: 'side-host' });
  let sideOpen = false;
  let sideInput = null;
  let sideBusy = false;

  const askSide = async (question, topicID = null, onFailure = null) => {
    const trimmed = String(question ?? '').trim();
    if (!trimmed || sideBusy) return;
    sideOpen = true;
    sideBusy = true;
    renderSideQuestions();
    try {
      const body = topicID ? { question: trimmed, topicID } : { question: trimmed };
      const res = await post(`/api/threads/${enc(id)}/side-questions`, body);
      store.sideQuestions.set(id, { items: res.sideQuestions ?? [], starting: Boolean(res.starting) });
    } catch (error) {
      onFailure?.();
      toastError(error, 'Side question');
    } finally {
      sideBusy = false;
      renderSideQuestions();
    }
  };

  const openSidePanel = (initialQuestion = '', onFailure = null) => {
    sideOpen = true;
    if (initialQuestion) {
      askSide(initialQuestion, null, onFailure);
    } else {
      loadSideQuestions(id);
      renderSideQuestions();
      requestAnimationFrame(() => sideInput?.focus());
    }
  };

  const compose = composer(id, { onSideQuestion: openSidePanel });
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const toBottom = h('button', {
    type: 'button',
    class: 'scroll-bottom',
    'aria-label': 'Scroll to the latest message',
    title: 'Scroll to the latest message',
    hidden: true,
    onclick: () => scroller.scrollTo({ top: scroller.scrollHeight, behavior: reduceMotion.matches ? 'auto' : 'smooth' }),
  }, icon('arrowDown', { size: 20 }));
  const dock = h('div', { class: 'dock' }, toBottom, sideHost, pending, compose.el);
  const headerHost = h('div');
  const screen = h('div', { class: 'screen thread' }, headerHost, scroller, dock);
  root.replaceChildren(screen);

  let atBottom = true;
  let firstRender = true;
  let pendingKey = null;
  let visitedKey = null;
  let headerSig = null;

  // Shown while the newest message is out of view.
  const updateToBottom = () => { toBottom.hidden = atBottom; };
  scroller.addEventListener('scroll', () => {
    atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;
    updateToBottom();
  }, { passive: true });
  const keepBottom = () => {
    if (atBottom) scroller.scrollTop = scroller.scrollHeight;
    else updateToBottom();
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
      { label: 'Side questions (/btw)', icon: 'note', onSelect: () => openSidePanel() },
      { label: 'Diff', icon: 'diff', onSelect: () => go(threadHash(id, 'diff')) },
      { label: 'Git', icon: 'branch', onSelect: () => go(threadHash(id, 'git')) },
      { label: 'Terminal', icon: 'terminal', onSelect: () => go(threadHash(id, 'terminal')) },
      { label: summary?.pinned ? 'Unpin' : 'Pin', icon: 'pin', disabled: teammate, onSelect: () => setFlag({ pinned: !summary?.pinned }) },
      { label: summary?.settled ? 'Unsettle' : 'Settle', icon: 'settle', disabled: teammate, onSelect: () => setFlag({ settled: !summary?.settled }) },
      { label: 'Archive', icon: 'archive', disabled: teammate, destructive: true, onSelect: () => setFlag({ archived: true }, () => { toast('Thread archived'); go('#/', { replace: true }); }) },
    ]);
  };

  function renderSideQuestions() {
    const entry = store.sideQuestions.get(id) ?? { items: [], starting: false };
    const items = entry.items ?? [];
    const running = entry.starting || items.some((q) => {
      const latest = q.followUps?.length ? q.followUps[q.followUps.length - 1] : q.first;
      return latest?.status === 'running';
    });
    if (!sideOpen) {
      sideHost.replaceChildren();
      return;
    }
    const list = h('div', { class: 'side-list' });
    if (!items.length && !running) {
      list.append(h('p', { class: 'side-empty', text: 'Ask a side question without steering the agent.' }));
    } else {
      for (const topic of items.slice(0, 3)) {
        const exchanges = [topic.first, ...(topic.followUps ?? [])];
        const card = h('div', { class: 'side-topic' });
        for (const ex of exchanges) {
          card.append(h('div', { class: 'side-q', text: ex.question }));
          if (ex.answer) {
            const ans = h('div', { class: 'side-a md' });
            ans.innerHTML = renderMarkdown(ex.answer);
            card.append(ans);
          } else if (ex.status === 'running') {
            card.append(h('div', { class: 'side-status shimmer', text: 'Thinking…' }));
          }
          if (ex.error) card.append(h('div', { class: 'side-error', text: ex.error }));
        }
        list.append(card);
      }
    }
    const input = h('input', {
      type: 'text',
      class: 'side-input',
      placeholder: items.length ? 'Ask a follow-up or new /btw…' : 'Ask a side question…',
      disabled: running || sideBusy,
    });
    sideInput = input;
    const askBtn = h('button', { type: 'submit', class: 'button primary small', text: 'Ask', disabled: running || sideBusy });
    const cancelBtn = running
      ? h('button', {
        type: 'button',
        class: 'button small',
        text: 'Stop',
        onclick: () => post(`/api/threads/${enc(id)}/side-questions/cancel`).catch((error) => toastError(error)),
      })
      : null;
    const form = h('form', { class: 'side-form' }, input, cancelBtn, askBtn);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const q = input.value.trim();
      if (!q) return;
      input.value = '';
      askSide(q, items[0]?.id ?? null);
    });
    const closeBtn = h('button', {
      type: 'button',
      class: 'side-close',
      'aria-label': 'Close side questions',
      text: 'Done',
      onclick: () => { sideOpen = false; renderSideQuestions(); },
    });
    const panel = h('div', { class: 'side-panel' },
      h('div', { class: 'side-head' }, h('span', { text: 'Side questions (/btw)' }), closeBtn),
      list,
      form);
    sideHost.replaceChildren(panel);
  }

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
    compose.setPlanMode(supportsPlanMode(thread.modelSelection?.provider, store.state), thread.interactionMode);
    if (firstRender || wasAtBottom) {
      scroller.scrollTop = scroller.scrollHeight;
      atBottom = true;
    }
    updateToBottom();
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
      if (topic === 'sideQuestions' && (!store.lastSideQuestionsThreadID || store.lastSideQuestionsThreadID === id)) {
        renderSideQuestions();
      }
    },
    destroy() {
      resizeObserver.disconnect();
      compose.destroy();
      document.removeEventListener('visibilitychange', onVisible);
    },
  };
}
