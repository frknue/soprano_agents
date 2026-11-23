// Thread timeline: turns, their user messages, steers and activity items, queue.

import { h, icon, reconcile, spinner } from './dom.js';
import { parseDiff, renderDiffLines } from './diff.js';
import { attachmentList } from './attachments.js';
import { renderMarkdown } from './markdown.js';
import {
  compactDuration, DECISION_PAST, diffStats, itemKind, pendingApproval, pendingUserInput, time, turnDuration, turnEndedAt, APPROVAL_TITLES,
} from './model.js';

/** Item rows the user expanded (item id or item id + sub key); survives re-renders. */
const expanded = new Set();

function fold(key, summaryChildren, buildBody, { cls = '', defaultOpen = false } = {}) {
  const open = expanded.has(key) || (defaultOpen && !expanded.has(`${key}!closed`));
  const details = h('details', { class: `fold ${cls}`.trim() },
    h('summary', null, icon('chevronRight', { size: 14, cls: 'disclosure' }), summaryChildren));
  let built = false;
  const build = () => {
    if (built) return;
    built = true;
    details.append(h('div', { class: 'fold-body' }, buildBody()));
  };
  details.addEventListener('toggle', () => {
    if (details.open) {
      expanded.add(key);
      expanded.delete(`${key}!closed`);
      build();
    } else {
      expanded.delete(key);
      if (defaultOpen) expanded.add(`${key}!closed`);
    }
  });
  if (open) {
    details.open = true;
    build();
  }
  return details;
}

function pre(text, cls = 'output') {
  return h('pre', { class: cls }, h('code', { text }));
}

function markdown(text, cls) {
  return h('div', { class: `md ${cls}`.trim(), html: renderMarkdown(text) });
}

function userBubble(message, { label = null, steer = false } = {}) {
  const sender = message.sender
    ? (message.sender.kind === 'teammate' ? `From ${message.sender.name}` : `From thread “${message.sender.name}”`)
    : null;
  return h('div', { class: `user-message${steer ? ' steer' : ''}` },
    sender || label ? h('div', { class: 'user-meta', text: [label, sender].filter(Boolean).join(' · ') }) : null,
    h('div', { class: 'bubble' },
      message.text ? h('div', { class: 'bubble-text', text: message.text }) : null,
      message.attachments?.length ? attachmentList(message.attachments) : null));
}

const FILE_VERBS = {
  add: ['Creating', 'Created'],
  delete: ['Deleting', 'Deleted'],
  update: ['Editing', 'Edited'],
  move: ['Moving', 'Moved'],
};

function splitPath(path) {
  const index = path.lastIndexOf('/');
  return index < 0 ? ['', path] : [path.slice(0, index + 1), path.slice(index + 1)];
}

function pathLabel(path) {
  const [dir, base] = splitPath(path);
  return h('span', { class: 'path' }, h('span', { class: 'path-base', text: base }), dir ? h('span', { class: 'path-dir', text: ` ${dir}` }) : null);
}

function fileChangeRow(turnID, item, change, index) {
  const running = item.status === 'running' || item.status === 'pending';
  const verbs = change.isFullContent ? ['Writing', 'Wrote'] : FILE_VERBS[change.kind] ?? FILE_VERBS.update;
  const verb = running ? verbs[0] : verbs[1];
  const stats = change.diff
    ? (change.isFullContent
      ? h('span', { class: 'meta', text: `${change.diff.split('\n').length} lines` })
      : (() => {
        const { additions, deletions } = diffStats(change.diff);
        return h('span', { class: 'stats' }, h('span', { class: 'stat-add', text: `+${additions}` }), h('span', { class: 'stat-del', text: `−${deletions}` }));
      })())
    : null;
  const summary = [
    icon('file', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title' }, h('span', { class: 'verb', text: `${verb} ` }), pathLabel(change.movePath ? `${change.path} → ${change.movePath}` : change.path)),
    stats,
  ];
  if (!change.diff) return h('div', { class: 'work-row' }, summary);
  return fold(`${turnID}:${item.id}:${index}`, summary, () => {
    if (change.isFullContent) {
      return renderDiffLines(change.diff.split('\n').map((text) => ({ type: 'ctx', text })), { plain: true });
    }
    const files = parseDiff(change.diff, change.path);
    if (files.length === 1) return renderDiffLines(files[0].lines);
    return files.map((f) => [h('div', { class: 'fold-label mono', text: f.path }), renderDiffLines(f.lines)]);
  }, { cls: 'work' });
}

function statusChip(item, extra = null) {
  if (item.status === 'running' || item.status === 'pending') return spinner('Running');
  if (item.status === 'failed') return h('span', { class: 'chip chip-error', text: extra ?? 'Failed' });
  if (item.status === 'declined') return h('span', { class: 'chip', text: 'Declined' });
  if (item.status === 'interrupted') return h('span', { class: 'chip', text: 'Stopped' });
  return extra ? h('span', { class: 'chip', text: extra }) : null;
}

function commandRow(turnID, item, command) {
  const failed = command.exitCode != null && command.exitCode !== 0;
  const exit = command.exitCode == null ? null
    : h('span', { class: `chip ${failed ? 'chip-error' : 'chip-quiet'}`, text: `exit ${command.exitCode}` });
  const duration = command.durationMs != null && item.status !== 'running' ? h('span', { class: 'meta', text: turnDuration(command.durationMs) }) : null;
  const running = item.status === 'running' || item.status === 'pending';
  return fold(`${turnID}:${item.id}`, [
    icon('terminal', { size: 16, cls: 'row-icon' }),
    h('code', { class: 'row-command', text: command.command }),
    running ? spinner('Running') : exit ?? statusChip(item),
    duration,
  ], () => {
    const output = pre(command.output || (running ? '' : 'No output'), 'output');
    if (running) requestAnimationFrame(() => { output.scrollTop = output.scrollHeight; });
    return [
      command.cwd ? h('div', { class: 'meta mono cwd', text: command.cwd }) : null,
      h('pre', { class: 'command-line' }, h('code', { text: `$ ${command.command}` })),
      output,
    ];
  }, { cls: `work${failed || item.status === 'failed' ? ' failed' : ''}` });
}

const TOOL_ICONS = { read: 'file', search: 'search', subagent: 'person', other: 'tool' };

function toolRow(turnID, item, tool) {
  const hasBody = tool.input || tool.output;
  const summary = [
    icon(TOOL_ICONS[tool.category] ?? 'tool', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title', text: tool.title || tool.name }),
    statusChip(item),
  ];
  if (!hasBody) return h('div', { class: 'work-row' }, summary);
  return fold(`${turnID}:${item.id}`, summary, () => [
    tool.input ? h('div', { class: 'fold-label', text: 'Input' }) : null,
    tool.input ? pre(tool.input) : null,
    tool.output ? h('div', { class: 'fold-label', text: 'Output' }) : null,
    tool.output ? pre(tool.output) : null,
  ], { cls: 'work' });
}

// Pending requests of the open turn show as cards above the composer (and in the turn footer);
// one left over in an ended turn reads as unanswered.
function approvalRow(request, open) {
  if (request.decision == null) {
    if (open) return null;
    return h('div', { class: 'work-row' }, icon('alert', { size: 16, cls: 'row-icon' }),
      h('span', { class: 'row-title muted', text: `${APPROVAL_TITLES[request.kind] ?? 'Approval'}: not answered` }));
  }
  const accepted = request.decision === 'accept' || request.decision === 'acceptForSession';
  return h('div', { class: 'work-row' }, icon(accepted ? 'check' : 'x', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title' }, h('span', { class: 'verb', text: `${DECISION_PAST[request.decision] ?? request.decision} ` }),
      h('code', { class: 'row-command', text: request.detail })));
}

function userInputRow(turnID, item, request, open) {
  if (request.dismissed) {
    return h('div', { class: 'work-row' }, icon('question', { size: 16, cls: 'row-icon' }), h('span', { class: 'row-title muted', text: 'Questions dismissed' }));
  }
  if (request.answers == null) {
    if (open) return null;
    return h('div', { class: 'work-row' }, icon('question', { size: 16, cls: 'row-icon' }), h('span', { class: 'row-title muted', text: 'Questions not answered' }));
  }
  const count = request.questions.length;
  return fold(`${turnID}:${item.id}`, [
    icon('question', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title', text: count === 1 ? `Answered: ${request.questions[0].header || request.questions[0].question}` : `Answered ${count} questions` }),
  ], () => h('dl', { class: 'answers' }, request.questions.map((q) => [
    h('dt', { text: q.question }),
    h('dd', { text: (request.answers[q.id] ?? []).join(', ') || 'No answer' }),
  ])), { cls: 'work' });
}

function advisoryCard(notes) {
  return h('div', { class: 'advisory' },
    h('div', { class: 'advisory-head' }, icon('note', { size: 16 }), h('span', { text: 'Advisor notes' })),
    h('ul', null, notes.map((note) => h('li', null,
      h('span', { class: `severity severity-${note.severity}`, text: { nit: 'Nit', concern: 'Concern', blocker: 'Blocker' }[note.severity] ?? note.severity }),
      note.advisor ? h('span', { class: 'meta', text: ` ${note.advisor} · ` }) : ' ',
      h('span', { text: note.text })))));
}

function renderItem(turnID, item, open) {
  const { type, value } = itemKind(item);
  switch (type) {
    case 'assistantMessage':
      if (!value.text?.trim()) return null;
      return markdown(value.text, value.isFinal ? 'assistant' : 'assistant commentary');
    case 'reasoning': {
      const running = item.status === 'running';
      if (!value.text?.trim()) {
        return running ? h('div', { class: 'work-row thinking' }, icon('bulb', { size: 16, cls: 'row-icon' }), h('span', { class: 'shimmer', text: 'Thinking…' })) : null;
      }
      return fold(`${turnID}:${item.id}`, [icon('bulb', { size: 16, cls: 'row-icon' }), h('span', { class: `row-title${running ? ' shimmer' : ''}`, text: running ? 'Thinking…' : 'Thinking' })],
        () => markdown(value.text, 'reasoning'), { cls: 'work' });
    }
    case 'command':
      return commandRow(turnID, item, value);
    case 'fileChange':
      return h('div', { class: 'file-changes' }, (value ?? []).map((change, index) => fileChangeRow(turnID, item, change, index)));
    case 'toolCall':
      return toolRow(turnID, item, value);
    case 'webSearch':
      return h('div', { class: 'work-row' }, icon('globe', { size: 16, cls: 'row-icon' }),
        h('span', { class: 'row-title' }, h('span', { class: 'verb', text: item.status === 'running' ? 'Searching ' : 'Searched ' }), h('span', { text: `“${value.query}”` })),
        statusChip(item));
    case 'approval':
      return approvalRow(value, open);
    case 'userInput':
      return userInputRow(turnID, item, value, open);
    case 'error':
      return h('div', { class: 'error-box', role: 'note' }, icon('alert', { size: 16 }), h('span', { text: value.message }));
    case 'notice':
      return h('div', { class: 'notice', role: 'separator' }, h('span', { text: value.text }));
    case 'advisory':
      return advisoryCard(value ?? []);
    default:
      return null;
  }
}

/** What a working turn waits on from the user, if anything. */
function waitingOn(turn) {
  if (turn.status !== 'running' || turn.yieldedAt) return null;
  if (pendingApproval(turn)) return 'Waiting for your approval';
  if (pendingUserInput(turn)) return 'Waiting for your answers';
  return null;
}

function footer(threadID, turn) {
  const ended = turnEndedAt(turn);
  if (turn.status === 'running' && !turn.yieldedAt) {
    const waiting = waitingOn(turn);
    if (waiting && !turn.stopRequestedAt) {
      return h('div', { class: 'turn-footer waiting', role: 'status' }, icon('clock', { size: 15 }), h('span', { text: waiting }));
    }
    return h('div', { class: 'turn-footer working', role: 'status' },
      spinner('Working'),
      turn.stopRequestedAt
        ? h('span', { class: 'shimmer', text: 'Stopping…' })
        : [h('span', { class: 'shimmer', text: 'Working' }), h('span', { class: 'meta', dataset: { since: turn.startedAt }, text: compactDuration(Date.now() - time(turn.startedAt)) })]);
  }
  const files = turn.checkpoint?.files ?? [];
  const additions = files.reduce((sum, f) => sum + f.additions, 0);
  const deletions = files.reduce((sum, f) => sum + f.deletions, 0);
  const parts = [];
  if (!Number.isNaN(ended)) parts.push(h('span', { class: 'meta', text: `Worked for ${turnDuration(ended - time(turn.startedAt))}` }));
  if (turn.status === 'interrupted') parts.push(h('span', { class: 'chip', text: 'Interrupted' }));
  if (turn.yieldedAt && turn.status === 'running') parts.push(h('span', { class: 'meta' }, spinner('Background work'), ' Background work running'));
  return h('div', { class: 'turn-end' },
    parts.length ? h('div', { class: 'turn-footer' }, parts) : null,
    turn.failureMessage ? h('div', { class: 'error-box', role: 'note' }, icon('alert', { size: 16 }), h('span', { text: turn.failureMessage })) : null,
    files.length
      ? h('a', { class: 'changes-link', href: `#/thread/${encodeURIComponent(threadID)}/diff?turn=${turn.ordinal}` },
        icon('diff', { size: 16 }),
        h('span', { text: `${files.length} ${files.length === 1 ? 'file' : 'files'} changed` }),
        h('span', { class: 'stat-add', text: `+${additions}` }),
        h('span', { class: 'stat-del', text: `−${deletions}` }),
        icon('chevronRight', { size: 14, cls: 'trailing' }))
      : null);
}

function turnEntries(threadID, turn) {
  const entries = [{ key: 'u', sig: JSON.stringify(turn.userMessage), build: () => userBubble(turn.userMessage) }];
  // Steers sit among the items by time.
  const flow = [
    ...turn.items.map((item) => ({ at: time(item.startedAt), item })),
    ...turn.steers.map((steer) => ({ at: time(steer.createdAt), steer })),
  ];
  flow.sort((a, b) => a.at - b.at);
  for (const entry of flow) {
    if (entry.item) {
      const { item } = entry;
      const open = turn.status === 'running';
      entries.push({ key: `i:${item.id}`, sig: `${open}${JSON.stringify(item)}`, build: () => renderItem(turn.id, item, open) ?? h('div', { hidden: true }) });
    } else {
      entries.push({ key: `s:${entry.steer.id}`, sig: JSON.stringify(entry.steer), build: () => userBubble(entry.steer, { label: 'Steered', steer: true }) });
    }
  }
  const footerSig = JSON.stringify([turn.status, turn.completedAt, turn.yieldedAt, turn.stopRequestedAt, turn.failureMessage, turn.checkpoint, turn.startedAt, waitingOn(turn)]);
  entries.push({ key: 'f', sig: footerSig, build: () => footer(threadID, turn) });
  return entries;
}

function queuedBubble(queued, actions) {
  const message = queued.message;
  const busy = { value: false };
  const run = (fn) => async (event) => {
    if (busy.value) return;
    busy.value = true;
    event.currentTarget.closest('.queued').classList.add('busy');
    try {
      await fn(message.id);
    } finally {
      busy.value = false;
    }
  };
  return h('div', { class: 'user-message queued' },
    h('div', { class: 'user-meta' }, icon('clock', { size: 13 }), ' Queued'),
    h('div', { class: 'bubble' },
      message.text ? h('div', { class: 'bubble-text', text: message.text }) : null,
      message.attachments?.length ? attachmentList(message.attachments) : null,
      h('div', { class: 'queued-actions' },
        h('button', { type: 'button', class: 'button small', onclick: run(actions.sendNow) }, 'Send now'),
        h('button', { type: 'button', class: 'button small ghost', onclick: run(actions.remove) }, 'Remove'))));
}

/** Renders `thread` into `container`, reusing unchanged rows. */
export function renderTimeline(container, thread, actions) {
  const entries = thread.turns.map((turn) => ({
    key: `t:${turn.id}`,
    sig: 'turn',
    build: () => h('section', { class: 'turn', 'aria-label': `Turn ${turn.ordinal}` }),
  }));
  if (!thread.turns.length) {
    entries.push({
      key: 'empty',
      sig: thread.teammate?.name ?? '',
      build: () => h('div', { class: 'empty-thread' },
        thread.teammate
          ? [h('div', { class: 'avatar large', text: thread.teammate.name.slice(0, 1).toUpperCase() }),
            h('p', { class: 'strong', text: thread.teammate.name }),
            h('p', { class: 'muted', text: thread.teammate.role }),
            h('p', { class: 'muted', text: `Ask ${thread.teammate.name} anything.` })]
          : h('p', { class: 'muted', text: 'Send a message to start the conversation.' })),
    });
  }
  for (const queued of thread.queue ?? []) {
    entries.push({ key: `q:${queued.message.id}`, sig: JSON.stringify(queued.message), build: () => queuedBubble(queued, actions) });
  }
  reconcile(container, entries);
  thread.turns.forEach((turn, index) => {
    const section = container.children[index];
    reconcile(section, turnEntries(thread.id, turn));
  });
}
