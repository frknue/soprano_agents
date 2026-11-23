// Domain helpers over the Core models' JSON: item kinds, turn state, durations, labels.

/** Normalizes a TurnItemKind (`{"<case>": {labels…}}` or `{"<case>": {"_0": …}}`) to {type, value}. */
export function itemKind(item) {
  const kind = item?.kind ?? {};
  const type = Object.keys(kind)[0];
  const payload = kind[type] ?? {};
  const value = payload && typeof payload === 'object' && '_0' in payload ? payload._0 : payload;
  return { type, value };
}

export const time = (iso) => (iso ? Date.parse(iso) : NaN);

/** The last turn while it has not ended (working or yielded). */
export function openTurn(thread) {
  const last = thread?.turns?.at(-1);
  return last && last.status === 'running' ? last : null;
}

/** The turn the agent works on: the open turn unless it yielded. */
export function activeTurn(thread) {
  const turn = openTurn(thread);
  return turn && !turn.yieldedAt ? turn : null;
}

export function pendingApproval(turn) {
  if (!turn) return null;
  for (const item of [...turn.items].reverse()) {
    const { type, value } = itemKind(item);
    if (type === 'approval' && value.decision == null) return value;
  }
  return null;
}

export function pendingUserInput(turn) {
  if (!turn) return null;
  for (const item of [...turn.items].reverse()) {
    const { type, value } = itemKind(item);
    if (type === 'userInput' && value.answers == null && !value.dismissed) return value;
  }
  return null;
}

/** When the turn's work ended: completion, or the yield of a yielded turn; NaN while working. */
export function turnEndedAt(turn) {
  if (turn.completedAt) return time(turn.completedAt);
  if (turn.status === 'running' && turn.yieldedAt) return time(turn.yieldedAt);
  return NaN;
}

/** Live working duration: `Ns`, `Nm`, `Hh Mm`. */
export function compactDuration(ms) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

/** Turn duration ("Worked for 1m 12s"). */
export function turnDuration(ms) {
  const interval = ms / 1000;
  if (interval < 1) return `${Math.max(0, Math.floor(interval * 1000))}ms`;
  if (interval < 10) return `${interval.toFixed(1)}s`;
  const seconds = Math.floor(interval);
  if (seconds < 60) return `${seconds}s`;
  const parts = [];
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = seconds % 60;
  if (hours) parts.push(`${hours}h`);
  if (minutes) parts.push(`${minutes}m`);
  if (rest) parts.push(`${rest}s`);
  return parts.join(' ');
}

/** Sidebar relative time: "now", "Nm", "Nh", "Nd". */
export function relativeTime(iso, now = Date.now()) {
  const date = time(iso);
  if (Number.isNaN(date)) return '';
  const seconds = Math.floor((now - date) / 1000);
  if (seconds < 60) return 'now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

export const STATUS_LABELS = { working: 'Working', approval: 'Approval', input: 'Input', failed: 'Failed', done: 'Done' };

export const APPROVAL_TITLES = {
  command: 'Command approval',
  fileChange: 'File change approval',
  fileRead: 'File read approval',
  other: 'Approval',
};

export const DECISION_TITLES = {
  accept: 'Approve',
  acceptForSession: 'Always allow this session',
  decline: 'Decline',
  cancel: 'Cancel',
};

export const DECISION_PAST = {
  accept: 'Approved',
  acceptForSession: 'Allowed for this session',
  decline: 'Declined',
  cancel: 'Cancelled',
};

const PROVIDER_NAMES = {
  omp: 'omp',
  codex: 'Codex',
  claude: 'Claude Code',
  antigravity: 'Antigravity',
  opencode: 'OpenCode',
};

export function providerName(kind) {
  return PROVIDER_NAMES[kind] ?? kind;
}

export function supportsPlanMode(kind, state) {
  if (!kind) return false;
  if (Array.isArray(state?.planModeProviders)) return state.planModeProviders.includes(kind);
  return kind === 'codex' || kind === 'claude';
}

/** Short model label for a ModelSelection, using the provider catalog's display name when known. */
export function modelLabel(selection, providers = []) {
  if (!selection) return '';
  const provider = providers.find((p) => p.kind === selection.provider);
  const model = provider?.models?.find((m) => m.slug === selection.model);
  let label;
  if (model) label = model.name.split(' · ')[0];
  else if (selection.model === 'default') label = `${providerName(selection.provider)} default`;
  else label = selection.model.split('/').at(-1);
  const effort = selection.options?.effort;
  return effort ? `${label} · ${effort}` : label;
}

export function projectTitle(state, projectID) {
  if (!projectID) return null;
  return state?.projects?.find((p) => p.id === projectID)?.title ?? null;
}

/** Lines added and removed in a unified diff text. */
export function diffStats(diff) {
  let additions = 0;
  let deletions = 0;
  for (const line of String(diff ?? '').split('\n')) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line[0] === '+') additions++;
    else if (line[0] === '-') deletions++;
  }
  return { additions, deletions };
}
