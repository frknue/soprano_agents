// Hash routes: #/, #/new, #/thread/<id>, #/thread/<id>/diff?turn=N, …/git, …/terminal[?id=…].

const current = () => location.hash || '#/';

/** The in-app history: lets Back return to the parent screen without leaving stray entries. */
const stack = [current()];
/** How the hash change in flight was started: 'back', 'replace', or null (a link or go()). */
let pending = null;

/** Call on every hashchange. */
export function noteHashChange() {
  const hash = current();
  if (pending === 'back') {
    stack.pop();
    stack[stack.length - 1] = hash;
  } else if (pending === 'replace') {
    stack[stack.length - 1] = hash;
  } else if (stack.length > 1 && stack.at(-2) === hash) {
    // The browser's own back.
    stack.pop();
  } else {
    stack.push(hash);
  }
  pending = null;
}

export function parseHash(hash = location.hash) {
  const raw = hash.replace(/^#/, '') || '/';
  const [path, query = ''] = raw.split('?');
  const parts = path.split('/').filter(Boolean).map((part) => {
    try {
      return decodeURIComponent(part);
    } catch {
      return part;
    }
  });
  return { parts, query: new URLSearchParams(query) };
}

export function threadHash(id, sub = '', query = '') {
  return `#/thread/${encodeURIComponent(id)}${sub ? `/${sub}` : ''}${query ? `?${query}` : ''}`;
}

/** Navigates within the app; `replace` swaps the current entry. */
export function go(hash, { replace = false } = {}) {
  if (hash === current()) return;
  if (replace) {
    pending = 'replace';
    location.replace(hash);
    return;
  }
  location.hash = hash;
}

/** Up to `parent`: history back when it is the previous screen, else replace this entry with it. */
export function back(parent = '#/') {
  if (stack.length > 1 && stack.at(-2) === parent) {
    pending = 'back';
    history.back();
  } else if (parent !== current()) {
    pending = 'replace';
    location.replace(parent);
  }
}
