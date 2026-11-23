// App state fed by /api/events and thread fetches; screens subscribe to topics.

import { enc, get } from './api.js';

export const store = {
  /** The `/api/state` body: {projects, threads, providers, defaults, runtimeModes, host, version}. */
  state: null,
  /** Open thread id and its `{thread, summary}` once fetched. */
  threadID: null,
  thread: null,
  threadError: null,
  /** threadID → [{id, threadID, title, running}] from `terminals` events. */
  terminals: new Map(),
  /** threadID → { items: [SideQuestion], starting: boolean } from `/side-questions` and SSE. */
  sideQuestions: new Map(),
  /** Last threadID whose side questions changed (so other threads don't rebuild an active input). */
  lastSideQuestionsThreadID: null,
  /** 'connecting' | 'open' | 'closed' */
  connection: 'connecting',
};

const listeners = new Set();

/** fn(topic): 'state' | 'thread' | 'terminals' | 'sideQuestions' | 'connection'. Returns an unsubscribe function. */
export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function emit(topic) {
  for (const fn of [...listeners]) {
    try {
      fn(topic);
    } catch (error) {
      console.warn('Listener failed', topic, error);
    }
  }
}

/** The freshest summary of a thread: the inbox list's, else the fetched one. */
export function summaryFor(id) {
  return store.state?.threads?.find((t) => t.id === id) ?? (store.thread?.thread?.id === id ? store.thread.summary : null);
}

let inflight = null;
let again = false;

/** Refetches the open thread; overlapping calls coalesce into one follow-up fetch. */
export function refreshThread() {
  const id = store.threadID;
  if (!id) return Promise.resolve();
  if (inflight) {
    again = true;
    return inflight;
  }
  inflight = (async () => {
    try {
      const body = await get(`/api/threads/${enc(id)}`);
      if (store.threadID === id) {
        store.thread = body;
        store.threadError = null;
        emit('thread');
      }
    } catch (error) {
      if (store.threadID === id && error?.status !== 401) {
        store.threadError = error;
        emit('thread');
      }
    } finally {
      inflight = null;
      if (again) {
        again = false;
        refreshThread();
      }
    }
  })();
  return inflight;
}

export function openThread(id) {
  if (store.threadID !== id) {
    store.threadID = id;
    store.thread = null;
    store.threadError = null;
  }
  return refreshThread();
}

export async function loadSideQuestions(id) {
  if (!id) return;
  try {
    const body = await get(`/api/threads/${enc(id)}/side-questions`);
    store.sideQuestions.set(id, { items: body.sideQuestions ?? [], starting: Boolean(body.starting) });
    emit('sideQuestions');
  } catch {
    // Best-effort load.
  }
}

function findTurn(thread, turnID) {
  const turn = thread.turns.find((t) => t.id === turnID);
  if (turn) return turn;
  for (const subagent of thread.subagents ?? []) {
    const found = subagent.turns?.find((t) => t.id === turnID);
    if (found) return found;
  }
  return null;
}

function applyItem({ threadID, turnID, item }) {
  const thread = store.thread?.thread;
  if (!thread || thread.id !== threadID || !item) return;
  const turn = findTurn(thread, turnID);
  if (!turn) {
    refreshThread();
    return;
  }
  const index = turn.items.findIndex((existing) => existing.id === item.id);
  if (index >= 0) turn.items[index] = item;
  else turn.items.push(item);
  emit('thread');
}

/** Applies one `/api/events` event. */
export function applyEvent(name, data) {
  switch (name) {
    case 'state':
      store.state = data;
      emit('state');
      if (store.threadID) refreshThread();
      break;
    case 'threads':
      if (store.state) {
        store.state.threads = data.threads;
        emit('state');
      }
      break;
    case 'thread':
      if (data.threadID === store.threadID) refreshThread();
      break;
    case 'item':
      applyItem(data);
      break;
    case 'projects':
      if (store.state) {
        store.state.projects = data.projects;
        emit('state');
      }
      break;
    case 'providers':
      if (store.state) {
        store.state.providers = data.providers;
        emit('state');
      }
      break;
    case 'terminals':
      store.terminals.set(data.threadID, data.terminals);
      emit('terminals');
      break;
    case 'sideQuestions':
      store.sideQuestions.set(data.threadID, { items: data.sideQuestions ?? [], starting: Boolean(data.starting) });
      store.lastSideQuestionsThreadID = data.threadID;
      emit('sideQuestions');
      break;
    default:
      break;
  }
}

export function setConnection(status) {
  if (store.connection === status) return;
  store.connection = status;
  emit('connection');
}

export function resetStore() {
  store.state = null;
  store.threadID = null;
  store.thread = null;
  store.threadError = null;
  store.terminals.clear();
  store.sideQuestions.clear();
}
