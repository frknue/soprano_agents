// Pending approval and question cards shown above the composer.

import { enc, del, post } from './api.js';
import { h, icon, spinner, toastError } from './dom.js';
import { APPROVAL_TITLES, DECISION_TITLES } from './model.js';

/** Approval card; buttons in phone order: Approve first. */
export function approvalCard(threadID, request) {
  const order = ['accept', 'acceptForSession', 'decline', 'cancel'];
  const options = order.filter((decision) => (request.options ?? order).includes(decision));
  const buttons = [];
  const answer = async (decision, button) => {
    buttons.forEach((b) => { b.disabled = true; });
    button.append(spinner('Sending'));
    try {
      await post(`/api/threads/${enc(threadID)}/approvals/${enc(request.id)}`, { decision });
    } catch (error) {
      toastError(error, 'Could not answer');
      buttons.forEach((b) => { b.disabled = false; });
      button.querySelector('.spinner')?.remove();
    }
  };
  for (const decision of options) {
    const button = h('button', {
      type: 'button',
      class: `button ${decision === 'accept' ? 'primary' : decision === 'acceptForSession' ? '' : 'ghost'}`,
      text: DECISION_TITLES[decision] ?? decision,
    });
    button.addEventListener('click', () => answer(decision, button));
    buttons.push(button);
  }
  const isCommand = request.kind === 'command';
  return h('section', { class: 'pending-card approval', 'aria-label': APPROVAL_TITLES[request.kind] ?? 'Approval' },
    h('div', { class: 'pending-head' }, icon('alert', { size: 18 }), h('h3', { text: APPROVAL_TITLES[request.kind] ?? 'Approval' })),
    request.reason ? h('p', { class: 'pending-reason', text: request.reason }) : null,
    isCommand
      ? h('pre', { class: 'pending-detail mono' }, h('code', { text: request.detail }))
      : h('p', { class: 'pending-detail', text: request.detail }),
    h('div', { class: 'pending-actions' }, buttons));
}

/** Per-request answer drafts so a re-render keeps what the user picked. */
const drafts = new Map();

function draftFor(request) {
  let draft = drafts.get(request.id);
  if (!draft) {
    draft = { index: 0, selected: {}, text: {} };
    for (const q of request.questions) {
      const initial = q.initialSelection ?? [];
      draft.selected[q.id] = new Set(q.allowsMultiple ? initial : initial.slice(0, 1));
      draft.text[q.id] = q.initialText ?? '';
    }
    drafts.set(request.id, draft);
  }
  return draft;
}

/** The answer values for one question, or null when it is not answerable yet. */
function answerFor(question, draft) {
  const selected = [...draft.selected[question.id]];
  const text = question.allowsOther ? draft.text[question.id].trim() : '';
  if (question.allowsMultiple) {
    const values = text ? [...selected, text] : selected;
    if (values.length || question.initialSelection != null) return values;
    return null;
  }
  if (text) return [text];
  return selected.length ? selected : null;
}

/** Question card: one question at a time, Next/Submit, Dismiss. `rerender` redraws the card. */
export function questionCard(threadID, request, rerender) {
  const draft = draftFor(request);
  const questions = request.questions;
  const index = Math.min(draft.index, questions.length - 1);
  const question = questions[index];
  const last = index === questions.length - 1;
  const name = `q-${request.id}-${question.id}`;
  let busy = false;

  const primary = h('button', { type: 'button', class: 'button primary', text: last ? 'Submit' : 'Next' });
  const back = index > 0 ? h('button', { type: 'button', class: 'button ghost', text: 'Back' }) : null;
  const dismiss = h('button', { type: 'button', class: 'button ghost', text: 'Dismiss' });
  const refresh = () => { primary.disabled = busy || answerFor(question, draft) == null; };

  const inputs = [];
  const optionRows = question.options.map((option, optionIndex) => {
    const id = `${name}-${optionIndex}`;
    const input = h('input', {
      type: question.allowsMultiple ? 'checkbox' : 'radio',
      name,
      id,
      value: option.label,
      checked: draft.selected[question.id].has(option.label),
    });
    inputs.push(input);
    input.addEventListener('change', () => {
      const set = draft.selected[question.id];
      if (question.allowsMultiple) {
        if (input.checked) set.add(option.label);
        else set.delete(option.label);
      } else {
        set.clear();
        if (input.checked) set.add(option.label);
        // A picked option replaces typed text for a single-choice question.
        if (textField) {
          textField.value = '';
          draft.text[question.id] = '';
        }
      }
      refresh();
    });
    return h('label', { class: 'option', for: id },
      input,
      h('span', { class: 'option-text' },
        h('span', { class: 'option-label', text: option.label }),
        option.description ? h('span', { class: 'option-description', text: option.description }) : null));
  });

  let textField = null;
  if (question.allowsOther) {
    textField = h('textarea', {
      class: 'field other-field',
      rows: 1,
      'aria-label': question.allowsMultiple ? 'Other answer' : 'Your answer',
      placeholder: question.options.length ? (question.allowsMultiple ? 'Something else…' : 'Or type an answer…') : 'Type your answer…',
      value: draft.text[question.id],
    });
    textField.addEventListener('input', () => {
      draft.text[question.id] = textField.value;
      if (!question.allowsMultiple && textField.value.trim()) {
        // Free text replaces the selection of a single-choice question.
        draft.selected[question.id].clear();
        inputs.forEach((input) => { input.checked = false; });
      }
      refresh();
    });
  }

  const setBusy = (value) => {
    busy = value;
    dismiss.disabled = value;
    if (back) back.disabled = value;
    refresh();
  };

  primary.addEventListener('click', async () => {
    if (answerFor(question, draft) == null) return;
    if (!last) {
      draft.index = index + 1;
      rerender();
      return;
    }
    const answers = {};
    for (const q of questions) answers[q.id] = answerFor(q, draft) ?? [];
    setBusy(true);
    primary.append(spinner('Sending'));
    try {
      await post(`/api/threads/${enc(threadID)}/inputs/${enc(request.id)}`, { answers });
      drafts.delete(request.id);
    } catch (error) {
      toastError(error, 'Could not send answers');
      primary.querySelector('.spinner')?.remove();
      setBusy(false);
    }
  });
  back?.addEventListener('click', () => {
    draft.index = index - 1;
    rerender();
  });
  dismiss.addEventListener('click', async () => {
    setBusy(true);
    try {
      await del(`/api/threads/${enc(threadID)}/inputs/${enc(request.id)}`);
      drafts.delete(request.id);
    } catch (error) {
      toastError(error, 'Could not dismiss');
      setBusy(false);
    }
  });
  refresh();

  const groupLabel = `${name}-label`;
  return h('section', { class: 'pending-card question', 'aria-label': 'Question from the agent' },
    h('div', { class: 'pending-head' },
      icon('question', { size: 18 }),
      question.header ? h('span', { class: 'chip chip-accent', text: question.header }) : null,
      questions.length > 1 ? h('span', { class: 'meta push', text: `${index + 1}/${questions.length}` }) : null),
    h('p', { class: 'question-text', id: groupLabel, text: question.question }),
    optionRows.length ? h('div', { class: 'options', role: question.allowsMultiple ? 'group' : 'radiogroup', 'aria-labelledby': groupLabel }, optionRows) : null,
    textField,
    h('div', { class: 'pending-actions row' }, dismiss, h('span', { class: 'spacer' }), back, primary));
}
