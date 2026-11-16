// New thread: project, model, permissions, workspace, first message.

import { enc, get, post } from '../api.js';
import { attachmentTray } from '../attachments.js';
import { h, spinner, toastError } from '../dom.js';
import { providerName } from '../model.js';
import { go, threadHash } from '../nav.js';
import { store } from '../store.js';
import { loading, topbar } from './common.js';

const LAST_PROJECT_KEY = 'soprano.lastProject';
const SEP = '\u0001';

const modelValue = (selection) => `${selection.provider}${SEP}${selection.model}`;

function field(label, control, hint = null) {
  const id = control.id || `f-${Math.random().toString(36).slice(2)}`;
  control.id = id;
  return h('div', { class: 'form-field' },
    h('label', { for: id, class: 'form-label', text: label }),
    control,
    hint);
}

export function mountNewThread(root) {
  const body = h('main', { class: 'scroll form-scroll' });
  const screen = h('div', { class: 'screen new-thread' }, topbar({ title: 'New thread', backTo: '#/' }), body);
  root.replaceChildren(screen);

  let built = false;
  let starting = false;
  let attachments = null;

  const build = () => {
    const state = store.state;
    if (!state) {
      body.replaceChildren(loading('Connecting to your Mac…'));
      return;
    }
    built = true;
    const projects = state.projects ?? [];
    const readyProviders = (state.providers ?? []).filter((p) => p.health === 'ready' && p.models?.length);
    const lastProject = localStorage.getItem(LAST_PROJECT_KEY);
    const initialProject = lastProject === '' ? '' : projects.find((p) => p.id === lastProject)?.id ?? projects[0]?.id ?? '';

    const project = h('select', { class: 'field' },
      projects.map((p) => h('option', { value: p.id, text: p.title, selected: p.id === initialProject })),
      h('option', { value: '', text: 'No project', selected: initialProject === '' }));

    const model = h('select', { class: 'field' });
    const selectionFor = new Map();
    for (const provider of readyProviders) {
      const group = h('optgroup', { label: providerName(provider.kind) });
      for (const m of provider.models) {
        const selection = { provider: provider.kind, model: m.slug, options: {} };
        selectionFor.set(modelValue(selection), selection);
        group.append(h('option', { value: modelValue(selection), text: m.name }));
      }
      model.append(group);
    }
    const unavailable = readyProviders.length === 0;
    const applyDefaultModel = () => {
      const projectDefault = projects.find((p) => p.id === project.value)?.defaultModel;
      for (const candidate of [projectDefault, state.defaults?.model]) {
        if (!candidate) continue;
        const value = modelValue(candidate);
        if (selectionFor.has(value)) {
          selectionFor.set(value, { ...candidate, options: candidate.options ?? {} });
          model.value = value;
          return;
        }
      }
      const fallback = readyProviders[0]?.models.find((m) => m.isDefault) ?? readyProviders[0]?.models[0];
      if (fallback) model.value = modelValue({ provider: readyProviders[0].kind, model: fallback.slug });
    };

    const modes = state.runtimeModes ?? [];
    const runtime = h('select', { class: 'field' }, modes.map((m) => h('option', { value: m.id, text: m.title, selected: m.id === state.defaults?.runtimeMode })));
    const runtimeHint = h('p', { class: 'form-hint' });
    const syncRuntimeHint = () => { runtimeHint.textContent = modes.find((m) => m.id === runtime.value)?.summary ?? ''; };
    runtime.addEventListener('change', syncRuntimeHint);
    syncRuntimeHint();

    let workspaceKind = 'projectRoot';
    const workspaceButtons = [['projectRoot', 'Current checkout'], ['newWorktree', 'New worktree']].map(([value, label]) => {
      const button = h('button', { type: 'button', role: 'radio', 'aria-checked': String(value === workspaceKind), text: label });
      button.addEventListener('click', () => {
        workspaceKind = value;
        workspaceButtons.forEach((b) => b.setAttribute('aria-checked', String(b === button)));
        syncWorkspace();
      });
      return button;
    });
    const branch = h('select', { class: 'field', disabled: true }, h('option', { text: 'Loading branches…' }));
    const branchField = field('Base branch', branch);
    const workspaceField = h('div', { class: 'form-field' },
      h('span', { class: 'form-label', id: 'workspace-label', text: 'Workspace' }),
      h('div', { class: 'segmented', role: 'radiogroup', 'aria-labelledby': 'workspace-label' }, workspaceButtons));

    let branchesFor = null;
    const loadBranches = async () => {
      const projectID = project.value;
      if (!projectID || branchesFor === projectID) return;
      branchesFor = projectID;
      branch.disabled = true;
      branch.replaceChildren(h('option', { text: 'Loading branches…' }));
      try {
        const result = await get(`/api/projects/${enc(projectID)}/branches`);
        if (project.value !== projectID) return;
        const names = result.branches ?? [];
        if (result.current && !names.includes(result.current)) names.unshift(result.current);
        branch.replaceChildren(...names.map((name) => h('option', { value: name, text: name === result.current ? `${name} (current)` : name, selected: name === result.current })));
        branch.disabled = names.length === 0;
        if (!names.length) branch.replaceChildren(h('option', { text: 'No branches' }));
      } catch (error) {
        branchesFor = null;
        branch.replaceChildren(h('option', { text: 'Could not load branches' }));
        toastError(error, 'Branches');
      }
    };

    const syncWorkspace = () => {
      const hasProject = project.value !== '';
      workspaceField.hidden = !hasProject;
      branchField.hidden = !hasProject || workspaceKind !== 'newWorktree';
      if (hasProject && workspaceKind === 'newWorktree') loadBranches();
    };

    const text = h('textarea', { class: 'field message-field', id: 'new-thread-message', rows: 5, placeholder: 'What should the agent do?' });
    const start = h('button', { type: 'submit', class: 'button primary wide', text: 'Start' });
    const syncStart = () => {
      const hasContent = text.value.trim().length > 0 || attachments.ids().length > 0;
      start.disabled = starting || unavailable || !hasContent || attachments.busy();
    };
    attachments = attachmentTray('new', syncStart);
    attachments.button.classList.add('with-label');
    attachments.button.append(h('span', { text: 'Attach' }));
    text.addEventListener('input', syncStart);
    text.addEventListener('paste', (event) => attachments.handlePaste(event));

    project.addEventListener('change', () => {
      branchesFor = null;
      applyDefaultModel();
      syncWorkspace();
    });

    const form = h('form', { class: 'form' },
      field('Project', project),
      field('Model', model, unavailable ? h('p', { class: 'form-hint error-text', text: 'No provider is ready on the Mac.' }) : null),
      field('Permissions', runtime, runtimeHint),
      workspaceField,
      branchField,
      h('div', { class: 'form-field' },
        h('label', { class: 'form-label', for: 'new-thread-message', text: 'Message' }),
        attachments.tray,
        text,
        attachments.input,
        h('div', { class: 'message-tools' }, attachments.button)),
      start);

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (start.disabled) return;
      starting = true;
      syncStart();
      start.append(spinner('Starting'));
      const projectID = project.value || null;
      const workspace = projectID && workspaceKind === 'newWorktree' && !branch.disabled
        ? { kind: 'newWorktree', baseBranch: branch.value }
        : { kind: 'projectRoot' };
      try {
        const selection = selectionFor.get(model.value);
        const ids = attachments.ids();
        const body = {
          projectID,
          text: text.value.trim(),
          model: selection,
          runtimeMode: runtime.value,
          workspace,
        };
        if (ids.length) body.attachments = ids;
        const result = await post('/api/threads', body);
        attachments.clearSent(ids);
        localStorage.setItem(LAST_PROJECT_KEY, projectID ?? '');
        go(threadHash(result.threadID), { replace: true });
      } catch (error) {
        toastError(error, 'Could not start');
        starting = false;
        start.querySelector('.spinner')?.remove();
        syncStart();
      }
    });

    applyDefaultModel();
    syncWorkspace();
    syncStart();
    body.replaceChildren(h('div', { class: 'lane' }, form));
  };

  build();
  return {
    update(topic) {
      if (topic === 'state' && !built) build();
    },
    destroy() {
      attachments?.destroy();
    },
  };
}
