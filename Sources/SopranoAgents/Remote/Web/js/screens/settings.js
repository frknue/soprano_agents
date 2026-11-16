// Settings sheet: connection, notifications, forget this device.

import { clearToken } from '../api.js';
import { h, sheet, spinner, toastError } from '../dom.js';
import { currentSubscription, disablePush, enablePush, isIOS, pushSupport } from '../push.js';
import { store } from '../store.js';

let forgetHandler = () => {};

/** The app's sign-out: stop the event stream and show the pair screen. */
export function onForget(handler) {
  forgetHandler = handler;
}

function notificationsSection() {
  const support = pushSupport();
  const hint = h('p', { class: 'form-hint' });
  const toggle = h('input', { type: 'checkbox', role: 'switch', class: 'switch', id: 'push-toggle', disabled: true });
  const busy = h('span');
  const row = h('label', { class: 'switch-row', for: 'push-toggle' },
    h('span', null, h('span', { class: 'strong', text: 'Notifications' }),
      h('span', { class: 'form-hint block', text: 'When a thread is done, failed or waits for you while you are away from the Mac.' })),
    busy, toggle);

  if (!support.ok) {
    hint.textContent = support.reason === 'home-screen'
      ? 'On iPhone, notifications need the app on the Home Screen: tap Share, then “Add to Home Screen”, and open Agents from there.'
      : 'This browser cannot receive push notifications.';
  } else {
    currentSubscription().then((subscription) => {
      toggle.checked = Boolean(subscription) && Notification.permission === 'granted';
      toggle.disabled = false;
    }).catch(() => { toggle.disabled = false; });
    toggle.addEventListener('change', async () => {
      const enable = toggle.checked;
      toggle.disabled = true;
      busy.replaceChildren(spinner(enable ? 'Turning on' : 'Turning off'));
      try {
        if (enable) await enablePush();
        else await disablePush();
      } catch (error) {
        toggle.checked = !enable;
        toastError(error, enable ? 'Could not turn on notifications' : 'Could not turn off notifications');
      } finally {
        toggle.disabled = false;
        busy.replaceChildren();
      }
    });
  }
  return h('section', { class: 'settings-section' }, row, hint.textContent ? hint : null);
}

export function openSettings() {
  sheet('Settings', (close) => {
    const state = store.state;
    const status = { open: 'Connected', connecting: 'Connecting…', closed: 'Disconnected' }[store.connection];
    const forget = h('button', { type: 'button', class: 'button danger wide', text: 'Forget this device' });
    forget.addEventListener('click', async () => {
      forget.disabled = true;
      try {
        await disablePush();
      } catch {
        // The token goes either way.
      }
      clearToken();
      close();
      forgetHandler();
    });
    return [
      h('section', { class: 'settings-section' },
        h('dl', { class: 'info-list' },
          h('div', null, h('dt', { text: 'Mac' }), h('dd', { text: state?.host ?? '—' })),
          h('div', null, h('dt', { text: 'Connection' }), h('dd', { text: status })),
          state?.version ? h('div', null, h('dt', { text: 'Version' }), h('dd', { text: state.version })) : null)),
      notificationsSection(),
      h('section', { class: 'settings-section' },
        forget,
        h('p', { class: 'form-hint', text: isIOS()
          ? 'Removes this iPhone’s access token. Revoke it on the Mac too under Settings → Phone.'
          : 'Removes this device’s access token. Revoke it on the Mac too under Settings → Phone.' })),
    ];
  });
}
