// Attachments: preparing and uploading picked files, the pending tray above a composer, fetching
// sent attachments for thumbnails, and the full-screen image viewer.

import { ApiError, authHeaders, enc, reportUnauthorized, token } from './api.js';
import { h, icon, iconButton, spinner, toast, toastError } from './dom.js';

const MAX_BYTES = 25 * 1024 * 1024;
const MAX_EDGE = 2048;
const JPEG_QUALITY = 0.85;

// Images that lose what makes them useful as a flattened JPEG stay as they are.
const KEEP_FORMAT = new Set(['image/gif', 'image/svg+xml']);

const isImage = (file) => file.type.startsWith('image/') || /\.(heic|heif|jpe?g|png|gif|webp|bmp|tiff?)$/i.test(file.name);

async function decodeImage(file) {
  if ('createImageBitmap' in window) {
    try {
      const bitmap = await createImageBitmap(file);
      return { source: bitmap, width: bitmap.width, height: bitmap.height, release: () => bitmap.close() };
    } catch {
      // Fall back to <img>, which decodes more formats (HEIC) in Safari.
    }
  }
  const url = URL.createObjectURL(file);
  const image = new Image();
  image.src = url;
  try {
    await image.decode();
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
  return { source: image, width: image.naturalWidth, height: image.naturalHeight, release: () => URL.revokeObjectURL(url) };
}

/** A picked image re-encoded as JPEG (longest edge ≤ 2048 px; turns HEIC into JPEG); null when it cannot be decoded. */
async function toJPEG(file) {
  let decoded;
  try {
    decoded = await decodeImage(file);
  } catch {
    return null;
  }
  try {
    if (!decoded.width || !decoded.height) return null;
    const scale = Math.min(1, MAX_EDGE / Math.max(decoded.width, decoded.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(decoded.width * scale));
    canvas.height = Math.max(1, Math.round(decoded.height * scale));
    const context = canvas.getContext('2d');
    // JPEG has no alpha: flatten transparent areas onto white like a printed page.
    context.fillStyle = 'white';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(decoded.source, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', JPEG_QUALITY));
    if (!blob) return null;
    const base = file.name.replace(/\.[^.]+$/, '') || 'image';
    return new File([blob], `${base}.jpg`, { type: 'image/jpeg' });
  } finally {
    decoded.release();
  }
}

function uploadRequest(file, onProgress) {
  const xhr = new XMLHttpRequest();
  const done = new Promise((resolve, reject) => {
    xhr.open('POST', '/api/attachments');
    xhr.setRequestHeader('Authorization', `Bearer ${token() ?? ''}`);
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    xhr.setRequestHeader('X-Filename', encodeURIComponent(file.name));
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) onProgress(event.loaded / event.total);
    };
    xhr.onload = () => {
      if (xhr.status === 401) {
        reportUnauthorized();
        reject(new ApiError('This device is not paired.', 401));
        return;
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          resolve(JSON.parse(xhr.responseText));
        } catch {
          reject(new ApiError('The Mac sent an unreadable answer.', xhr.status));
        }
        return;
      }
      let message = null;
      try {
        message = JSON.parse(xhr.responseText).error;
      } catch {
        // Not JSON.
      }
      reject(new ApiError(message || (xhr.status === 413 ? 'The file is larger than 25 MB.' : `Upload failed (${xhr.status}).`), xhr.status));
    };
    xhr.onerror = () => reject(new ApiError('The upload failed. Check the connection to the Mac.', 0));
    xhr.onabort = () => reject(new ApiError('Cancelled', -1));
    xhr.send(file);
  });
  return { done, abort: () => xhr.abort() };
}

// Sent attachments by id → object URL (shared by thumbnails and the viewer).
const urls = new Map();

/** Object URL of an attachment's bytes, fetched once with the device token. */
export function attachmentURL(id) {
  if (!urls.has(id)) {
    const promise = (async () => {
      const response = await fetch(`/api/attachments/${enc(id)}`, { headers: authHeaders() });
      if (response.status === 401) reportUnauthorized();
      if (!response.ok) throw new ApiError(`Could not load the attachment (${response.status}).`, response.status);
      return URL.createObjectURL(await response.blob());
    })();
    promise.catch(() => urls.delete(id));
    urls.set(id, promise);
  }
  return urls.get(id);
}

/** Pending (picked, not yet sent) attachments per composer key; kept in memory for the session. */
class PendingList {
  constructor() {
    this.items = [];
    this.listeners = new Set();
  }

  emit() {
    for (const fn of [...this.listeners]) fn();
  }

  remove(item) {
    this.items = this.items.filter((i) => i !== item);
    item.request?.abort();
    // Keep the preview while its upload finished: a sent message reuses it as the thumbnail.
    if (!item.attachment && item.previewURL) URL.revokeObjectURL(item.previewURL);
    this.emit();
  }
}

const lists = new Map();

function listFor(key) {
  if (!lists.has(key)) lists.set(key, new PendingList());
  return lists.get(key);
}

async function addFile(list, original) {
  const item = { localID: Math.random().toString(36).slice(2), name: original.name || 'file', kind: isImage(original) ? 'image' : 'file', status: 'preparing', progress: 0 };
  list.items.push(item);
  list.emit();
  let file = original;
  if (item.kind === 'image' && !KEEP_FORMAT.has(original.type)) {
    file = (await toJPEG(original)) ?? original;
  }
  if (!list.items.includes(item)) return;
  if (file.size > MAX_BYTES) {
    toast(`“${file.name}” is larger than 25 MB.`, { kind: 'error' });
    list.remove(item);
    return;
  }
  item.name = file.name;
  if (item.kind === 'image') item.previewURL = URL.createObjectURL(file);
  item.status = 'uploading';
  item.request = uploadRequest(file, (progress) => {
    item.progress = progress;
    list.emit();
  });
  list.emit();
  try {
    item.attachment = await item.request.done;
    item.status = 'done';
    item.request = null;
    if (item.previewURL) urls.set(item.attachment.id, Promise.resolve(item.previewURL));
    list.emit();
  } catch (error) {
    if (error?.status === -1) return;
    toastError(error, `Could not upload “${item.name}”`);
    item.request = null;
    list.remove(item);
  }
}

function chip(list, item) {
  const busy = item.status !== 'done';
  const preview = item.kind === 'image' && item.previewURL
    ? h('img', { src: item.previewURL, alt: '' })
    : h('span', { class: 'attachment-chip-file' }, icon(item.kind === 'image' ? 'image' : 'file', { size: 18 }));
  const progress = busy
    ? h('span', { class: 'attachment-chip-progress', role: 'status', 'aria-label': item.status === 'preparing' ? 'Preparing' : `Uploading ${Math.round(item.progress * 100)}%` },
      item.status === 'uploading' && item.progress > 0
        ? h('span', { class: 'progress-ring', style: { '--progress': `${Math.round(item.progress * 100)}%` } })
        : spinner('Uploading'))
    : null;
  return h('li', { class: `attachment-chip${item.kind === 'image' ? ' image' : ''}${busy ? ' busy' : ''}` },
    h('span', { class: 'attachment-chip-preview' }, preview, progress),
    item.kind === 'image' ? null : h('span', { class: 'attachment-chip-name', text: item.name }),
    iconButton('x', `Remove ${item.name}`, () => list.remove(item), 'attachment-chip-remove'));
}

/**
 * The attach button, hidden file input and pending tray for one composer. `onChange` runs whenever
 * the pending list changes. Call `destroy()` when the composer goes away (uploads keep running).
 */
export function attachmentTray(key, onChange) {
  const list = listFor(key);
  const input = h('input', { type: 'file', multiple: true, accept: 'image/*,*/*', class: 'visually-hidden', tabindex: '-1', 'aria-hidden': 'true' });
  const button = h('button', { type: 'button', class: 'composer-attach', 'aria-label': 'Attach photos or files', title: 'Attach' }, icon('paperclip', { size: 20 }));
  const tray = h('ul', { class: 'attachment-tray', 'aria-label': 'Attachments to send' });

  const addFiles = (files) => {
    for (const file of files) addFile(list, file);
  };
  button.addEventListener('click', () => input.click());
  input.addEventListener('change', () => {
    addFiles([...input.files]);
    input.value = '';
  });

  const render = (notify = true) => {
    tray.replaceChildren(...list.items.map((item) => chip(list, item)));
    tray.hidden = list.items.length === 0;
    if (notify) onChange?.();
  };
  list.listeners.add(render);
  // The owner syncs itself after construction; it may not be ready for a callback yet.
  render(false);

  return {
    button,
    input,
    tray,
    addFiles,
    /** Ids of finished uploads. */
    ids: () => list.items.filter((i) => i.status === 'done').map((i) => i.attachment.id),
    busy: () => list.items.some((i) => i.status !== 'done'),
    /** Drops the attachments that were just sent. */
    clearSent(ids) {
      list.items = list.items.filter((i) => !(i.attachment && ids.includes(i.attachment.id)));
      list.emit();
    },
    /** Images pasted into a text field. */
    handlePaste(event) {
      const files = [...(event.clipboardData?.files ?? [])];
      if (!files.length) return;
      addFiles(files);
      if (!event.clipboardData.types.includes('text/plain')) event.preventDefault();
    },
    destroy() {
      list.listeners.delete(render);
    },
  };
}

/** Full-screen viewer for an image attachment. */
export function openImageViewer(id, name) {
  const previousFocus = document.activeElement;
  const image = h('img', { class: 'viewer-image', alt: name ?? '' });
  const close = () => {
    document.removeEventListener('keydown', onKey);
    overlay.remove();
    if (previousFocus instanceof HTMLElement) previousFocus.focus({ preventScroll: true });
  };
  const onKey = (event) => {
    if (event.key === 'Escape') close();
  };
  const closeButton = iconButton('x', 'Close', close, 'viewer-close');
  const overlay = h('div', { class: 'viewer', role: 'dialog', 'aria-modal': 'true', 'aria-label': name ?? 'Image' },
    h('div', { class: 'viewer-bar' }, h('span', { class: 'viewer-title', text: name ?? '' }), closeButton),
    h('div', { class: 'viewer-stage' }, spinner('Loading'), image));
  overlay.addEventListener('click', (event) => {
    if (event.target === overlay || event.target.classList.contains('viewer-stage')) close();
  });
  document.addEventListener('keydown', onKey);
  document.body.append(overlay);
  closeButton.focus({ preventScroll: true });
  attachmentURL(id).then((url) => {
    image.src = url;
    overlay.querySelector('.viewer-stage .spinner')?.remove();
  }).catch((error) => {
    toastError(error);
    close();
  });
}

/** A sent message's attachments: image thumbnails that open the viewer, files as name chips. */
export function attachmentList(attachments) {
  return h('ul', { class: 'attachments', 'aria-label': 'Attachments' }, attachments.map((attachment) => {
    if (attachment.kind !== 'image') {
      return h('li', { class: 'attachment-file' }, icon('paperclip', { size: 14 }), h('span', { text: attachment.name }));
    }
    const image = h('img', { alt: '' });
    const thumb = h('button', { type: 'button', class: 'attachment-thumb loading', 'aria-label': `Open image ${attachment.name}` }, image);
    thumb.addEventListener('click', () => openImageViewer(attachment.id, attachment.name));
    attachmentURL(attachment.id).then((url) => {
      image.src = url;
      thumb.classList.remove('loading');
    }).catch(() => {
      thumb.classList.remove('loading');
      thumb.classList.add('broken');
      thumb.replaceChildren(icon('image', { size: 20 }), h('span', { class: 'attachment-thumb-name', text: attachment.name }));
    });
    return h('li', null, thumb);
  }));
}
