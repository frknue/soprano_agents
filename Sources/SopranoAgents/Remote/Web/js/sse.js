// Server-sent events over fetch (EventSource cannot send the Authorization header).

import { authHeaders, reportUnauthorized } from './api.js';

/** Returns a feed(chunk) function that calls onMessage(event, data) per complete SSE message. */
export function sseParser(onMessage) {
  let buffer = '';
  let event = '';
  let data = [];
  return (chunk) => {
    buffer += chunk;
    for (;;) {
      const index = buffer.search(/[\r\n]/);
      if (index < 0) break;
      // A trailing CR may be the first half of CRLF: wait for the next chunk.
      if (buffer[index] === '\r' && index === buffer.length - 1) break;
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + (buffer[index] === '\r' && buffer[index + 1] === '\n' ? 2 : 1));
      if (line === '') {
        if (data.length) onMessage(event || 'message', data.join('\n'));
        event = '';
        data = [];
      } else if (line[0] !== ':') {
        const colon = line.indexOf(':');
        const field = colon < 0 ? line : line.slice(0, colon);
        let value = colon < 0 ? '' : line.slice(colon + 1);
        if (value[0] === ' ') value = value.slice(1);
        if (field === 'event') event = value;
        else if (field === 'data') data.push(value);
      }
    }
  };
}

/**
 * A reconnecting SSE stream. Handlers: onEvent(name, json), onStatus('connecting'|'open'|'closed'),
 * onOpen() (each new connection), onFatal(status) (a 4xx other than 401 ends the stream).
 * `idleTimeout` (ms) reconnects a stream that went silent (the event stream pings every 15 s).
 */
export class SSEStream {
  constructor(url, { onEvent, onStatus, onOpen, onFatal, idleTimeout = 0, minDelay = 1000, maxDelay = 15000 } = {}) {
    Object.assign(this, { url, onEvent, onStatus, onOpen, onFatal, idleTimeout, minDelay, maxDelay });
    this.delay = minDelay;
    this.running = false;
    this.status = 'closed';
    this.lastActivity = 0;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.generation = (this.generation ?? 0) + 1;
    this.loop(this.generation);
  }

  stop() {
    this.running = false;
    this.controller?.abort();
    this.wake?.();
  }

  /** Reconnect now: after a wake from the background, or when the network came back. */
  kick({ force = false } = {}) {
    if (!this.running) return;
    this.delay = this.minDelay;
    if (this.status === 'open') {
      if (force || (this.idleTimeout && Date.now() - this.lastActivity > this.idleTimeout / 2)) this.controller?.abort();
    } else {
      this.wake?.();
    }
  }

  setStatus(status) {
    if (this.status === status) return;
    this.status = status;
    this.onStatus?.(status);
  }

  armWatchdog() {
    if (!this.idleTimeout) return;
    clearTimeout(this.watchdog);
    const controller = this.controller;
    this.watchdog = setTimeout(() => controller.abort(), this.idleTimeout);
  }

  async loop(generation) {
    const live = () => this.running && this.generation === generation;
    while (live()) {
      this.controller = new AbortController();
      let received = false;
      try {
        this.setStatus('connecting');
        const response = await fetch(this.url, {
          headers: authHeaders({ Accept: 'text/event-stream' }),
          signal: this.controller.signal,
          cache: 'no-store',
        });
        if (response.status === 401) {
          this.running = false;
          reportUnauthorized();
          break;
        }
        if (response.status >= 400 && response.status < 500) {
          this.running = false;
          this.onFatal?.(response.status);
          break;
        }
        if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
        this.lastActivity = Date.now();
        this.setStatus('open');
        this.onOpen?.();
        this.armWatchdog();
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        const feed = sseParser((name, data) => {
          received = true;
          let payload;
          try {
            payload = data ? JSON.parse(data) : null;
          } catch {
            payload = data;
          }
          try {
            this.onEvent?.(name, payload);
          } catch (error) {
            console.warn('SSE handler failed', name, error);
          }
        });
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          this.lastActivity = Date.now();
          this.armWatchdog();
          feed(decoder.decode(value, { stream: true }));
          if (!live()) break;
        }
      } catch {
        // Network error or abort: reconnect below.
      }
      clearTimeout(this.watchdog);
      if (!live()) break;
      this.setStatus('closed');
      if (received) this.delay = this.minDelay;
      await new Promise((resolve) => {
        this.wake = resolve;
        setTimeout(resolve, this.delay);
      });
      this.wake = null;
      this.delay = Math.min(this.delay * 2, this.maxDelay);
    }
    if (this.generation === generation) this.setStatus('closed');
  }
}
