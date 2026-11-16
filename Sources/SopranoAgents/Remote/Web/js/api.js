// HTTP API client: device token, JSON requests, pairing.

const TOKEN_KEY = 'soprano.token';

let unauthorizedHandler = () => {};

/** Called once whenever a request is answered 401 (token revoked or unknown). */
export function onUnauthorized(handler) {
  unauthorizedHandler = handler;
}

export function token() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(value) {
  localStorage.setItem(TOKEN_KEY, value);
}

export function clearToken() {
  localStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export function authHeaders(extra = {}) {
  const value = token();
  return value ? { ...extra, Authorization: `Bearer ${value}` } : { ...extra };
}

export const enc = encodeURIComponent;

export function reportUnauthorized() {
  unauthorizedHandler();
}

async function errorMessage(response) {
  try {
    const body = await response.json();
    if (body?.error) return body.error;
  } catch {
    // Not JSON.
  }
  return `${response.status} ${response.statusText || 'Request failed'}`.trim();
}

/** JSON request; resolves to the parsed body (null for 204), throws ApiError. */
export async function api(path, { method = 'GET', body, signal } = {}) {
  const headers = authHeaders({ Accept: 'application/json' });
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let response;
  try {
    response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal, cache: 'no-store' });
  } catch (error) {
    if (error?.name === 'AbortError') throw error;
    throw new ApiError('The Mac is not reachable. Check that it is awake and on the tailnet.', 0);
  }
  if (response.status === 401) {
    unauthorizedHandler();
    throw new ApiError('This device is not paired.', 401);
  }
  if (!response.ok) throw new ApiError(await errorMessage(response), response.status);
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

export const get = (path, options) => api(path, options);
export const post = (path, body = {}) => api(path, { method: 'POST', body });
export const patch = (path, body) => api(path, { method: 'PATCH', body });
export const del = (path, body) => api(path, { method: 'DELETE', body });

/** The pairing code in a pairing link (`…/#pair=<code>`), or a bare code; null when none. */
export function parsePairCode(input) {
  const text = String(input ?? '').trim();
  const match = text.match(/[#?&]pair=([A-Za-z0-9_\-%=]+)/);
  if (match) return decodeURIComponent(match[1]);
  return /^[A-Za-z0-9_-]{16,}={0,2}$/.test(text) ? text : null;
}

/** A readable name for this device, shown in the Mac's device list. */
export function deviceName() {
  const ua = navigator.userAgent;
  const device = /iPhone/.test(ua) ? 'iPhone'
    : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? 'iPad'
      : /Android/.test(ua) ? 'Android'
        : /Macintosh/.test(ua) ? 'Mac'
          : /Windows/.test(ua) ? 'Windows PC'
            : /Linux/.test(ua) ? 'Linux'
              : 'Browser';
  const browser = /CriOS|Chrome\//.test(ua) && !/Edg/.test(ua) ? 'Chrome'
    : /FxiOS|Firefox\//.test(ua) ? 'Firefox'
      : /Edg/.test(ua) ? 'Edge'
        : /Safari\//.test(ua) ? 'Safari'
          : null;
  const standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
  if (standalone) return `${device} (home screen app)`;
  return browser ? `${device} (${browser})` : device;
}

/** Redeems a pairing code for a device token and stores it. */
export async function pair(code) {
  let response;
  try {
    response = await fetch('/api/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ code, name: deviceName() }),
      cache: 'no-store',
    });
  } catch {
    throw new ApiError('The Mac is not reachable. Check that it is awake and on the tailnet.', 0);
  }
  if (response.status === 403) {
    throw new ApiError('This pairing link is no longer valid. Open Settings → Phone on the Mac for the current one.', 403);
  }
  if (!response.ok) throw new ApiError(await errorMessage(response), response.status);
  const body = await response.json();
  if (!body?.token) throw new ApiError('The Mac did not return a device token.', 500);
  setToken(body.token);
}
