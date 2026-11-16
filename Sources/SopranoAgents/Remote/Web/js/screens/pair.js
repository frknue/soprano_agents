// Pair screen: explains pairing and redeems a pasted pairing link.

import { pair, parsePairCode } from '../api.js';
import { h, icon, spinner } from '../dom.js';

export function mountPair(root, { onPaired, message = null }) {
  const input = h('input', {
    class: 'field',
    id: 'pair-link',
    type: 'url',
    inputmode: 'url',
    autocapitalize: 'off',
    autocorrect: 'off',
    spellcheck: 'false',
    placeholder: 'https://…/#pair=…',
  });
  const error = h('p', { class: 'form-hint error-text', role: 'alert', hidden: !message, text: message ?? '' });
  const submit = h('button', { type: 'submit', class: 'button primary wide', text: 'Pair' });
  const form = h('form', { class: 'form' },
    h('div', { class: 'form-field' }, h('label', { class: 'form-label', for: 'pair-link', text: 'Pairing link' }), input),
    error,
    submit);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const code = parsePairCode(input.value);
    if (!code) {
      error.textContent = 'That does not look like a pairing link. Copy it from Settings → Phone on the Mac.';
      error.hidden = false;
      return;
    }
    error.hidden = true;
    submit.disabled = true;
    submit.append(spinner('Pairing'));
    try {
      await pair(code);
      onPaired();
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
      submit.disabled = false;
      submit.querySelector('.spinner')?.remove();
    }
  });

  root.replaceChildren(h('div', { class: 'screen pair' },
    h('main', { class: 'scroll pair-scroll' },
      h('div', { class: 'lane pair-lane' },
        h('img', { class: 'pair-icon', src: '/icon-192.png', alt: '', width: 72, height: 72 }),
        h('h1', { text: 'Pair with your Mac' }),
        h('ol', { class: 'steps' },
          h('li', null, 'On the Mac, open ', h('strong', { text: 'Soprano Agents' }), ' → ', h('strong', { text: 'Settings' }), ' → ', h('strong', { text: 'Phone' }), '.'),
          h('li', null, 'Scan the QR code with the iPhone camera, or open the pairing link on this device.'),
          h('li', null, 'Or copy the pairing link on the Mac and paste it here.')),
        form,
        h('p', { class: 'form-hint center' }, icon('info', { size: 14 }), ' The app only reaches your Mac over your tailnet.')))));
  return { update() {}, destroy() {} };
}
