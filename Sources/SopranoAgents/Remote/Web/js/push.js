// Web Push subscription for this device.

import { del, get, post } from './api.js';

export const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
export const isStandalone = () => navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

/** {ok} or {ok: false, reason: 'home-screen' | 'unsupported'} */
export function pushSupport() {
  if (isIOS() && !isStandalone()) return { ok: false, reason: 'home-screen' };
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return { ok: false, reason: 'unsupported' };
  return { ok: true };
}

function base64UrlToBytes(value) {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function sameKey(buffer, bytes) {
  if (!buffer) return false;
  const existing = new Uint8Array(buffer);
  return existing.length === bytes.length && existing.every((b, i) => b === bytes[i]);
}

export async function currentSubscription() {
  if (!pushSupport().ok) return null;
  const registration = await navigator.serviceWorker.ready;
  return registration.pushManager.getSubscription();
}

/** Asks for permission (call from a tap), subscribes and registers the subscription with the Mac. */
export async function enablePush() {
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    throw new Error(isIOS()
      ? 'Notifications are off for this app. Turn them on in the iPhone’s Settings → Notifications → Agents.'
      : 'Notifications are blocked for this site.');
  }
  const { publicKey } = await get('/api/push/key');
  const key = base64UrlToBytes(publicKey);
  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (subscription && !sameKey(subscription.options?.applicationServerKey, key)) {
    await subscription.unsubscribe();
    subscription = null;
  }
  if (!subscription) subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  const json = subscription.toJSON();
  await post('/api/push/subscriptions', { endpoint: json.endpoint, keys: { p256dh: json.keys.p256dh, auth: json.keys.auth } });
}

export async function disablePush() {
  const subscription = await currentSubscription();
  if (!subscription) return;
  const { endpoint } = subscription;
  await subscription.unsubscribe();
  await del('/api/push/subscriptions', { endpoint });
}
