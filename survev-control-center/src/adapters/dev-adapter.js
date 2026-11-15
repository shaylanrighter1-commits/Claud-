// Developer API adapter (protocol "scc-dev" v1).
//
// Receives snapshots from YOUR OWN game build over window.postMessage, but only when ALL of these hold:
//   1. the page is a loopback / private-network host (see host-policy.js) - never a public site;
//   2. the page answers the extension's handshake with env = "development" | "private-test";
//   3. the page presents the session token configured in Settings -> Developer Session;
//   4. every message comes from the same window and same origin.
// The adapter is READ-ONLY: it never sends input to the page and never makes network requests.

import { evaluateLocation } from './host-policy.js';
import { sanitizeSnapshot, sanitizeObstacles } from '../core/schema.js';

export const PROTOCOL = 1;
const STALE_MS = 1500;

function randomNonce() {
  const a = new Uint8Array(12);
  crypto.getRandomValues(a);
  return Array.from(a, (b) => b.toString(16).padStart(2, '0')).join('');
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

export class DevAdapter {
  constructor({ state, win = window }) {
    this.kind = 'dev';
    this.interactive = false;
    this.label = 'Dev API';
    this.state = state;
    this.win = win;
    this.onChange = null;
    this.status = { phase: 'idle', reason: '', env: '', sessionId: '', host: win.location.hostname, app: '', frames: 0 };
    this.nonce = null;
    this.timer = 0;
    this.started = 0;
    this.pending = null;
    this.map = null;
    this.mapRev = 0;
    this.last = null;
    this.lastRecv = 0;
    this.seq = 0;
    this._onMsg = this._onMsg.bind(this);
  }

  _set(phase, reason = '', extra = {}) {
    const changed = this.status.phase !== phase || this.status.reason !== reason;
    Object.assign(this.status, { phase, reason }, extra);
    if (changed && this.onChange) this.onChange(this.status);
  }

  start() {
    this.stop(false);
    const pol = evaluateLocation(this.win.location);
    if (!pol.ok) {
      this._set('blocked', pol.reason);
      return false;
    }
    this.win.addEventListener('message', this._onMsg);
    this.started = performance.now();
    this._set('probing', 'Waiting for the page to answer the handshake…');
    this._hello();
    return true;
  }

  /** Restart the handshake (e.g. after changing the token). */
  reconnect() {
    this.pending = null;
    this.last = null;
    this.status.frames = 0;
    this.start();
  }

  stop(notify = true) {
    clearTimeout(this.timer);
    this.timer = 0;
    this.win.removeEventListener('message', this._onMsg);
    if (this.status.phase === 'authorized' || this.status.phase === 'stale') this._post({ type: 'revoke' });
    this.nonce = null;
    this.pending = null;
    if (notify && this.status.phase !== 'blocked') this._set('idle', '');
  }

  _post(msg) {
    try {
      this.win.postMessage({ source: 'scc-extension', v: PROTOCOL, ...msg }, this.win.location.origin);
    } catch (_) {
      /* ignore */
    }
  }

  _hello() {
    clearTimeout(this.timer);
    if (this.status.phase !== 'probing' && this.status.phase !== 'rejected') return;
    this.nonce = randomNonce();
    this._post({ type: 'hello', nonce: this.nonce, ext: 'scc', version: '1.4.0' });
    const age = performance.now() - this.started;
    this.timer = setTimeout(() => this._hello(), age < 60000 ? 2500 : 15000);
  }

  _onMsg(e) {
    if (e.source !== this.win || e.origin !== this.win.location.origin) return;
    const d = e.data;
    if (!d || typeof d !== 'object' || d.source !== 'scc-dev-api' || d.v !== PROTOCOL) return;
    switch (d.type) {
      case 'authorize':
        return this._authorize(d);
      case 'map':
        if (this.status.phase === 'authorized' || this.status.phase === 'stale') {
          this.map = { obstacles: sanitizeObstacles(d.map && d.map.obstacles), world: d.map && d.map.world, meta: d.map && d.map.meta };
          this.mapRev++;
        }
        return;
      case 'snapshot':
        if (this.status.phase === 'authorized' || this.status.phase === 'stale') {
          this.pending = d.frame;
          this.lastRecv = performance.now();
          if (this.status.phase === 'stale') this._set('authorized', '');
        }
        return;
      case 'bye':
        this.last = null;
        this._set('probing', 'Page ended the session');
        this.started = performance.now();
        this._hello();
    }
  }

  _authorize(d) {
    if (this.status.phase === 'authorized' || this.status.phase === 'stale') return;
    const fail = (why) => this._set('rejected', why, { env: String(d.env || '').slice(0, 24) });
    if (!this.nonce || d.nonce !== this.nonce) return fail('Handshake nonce mismatch');
    if (d.env !== 'development' && d.env !== 'private-test') return fail(`Environment "${String(d.env).slice(0, 24)}" is not a development or private-test session`);
    const token = this.state.data.loc.dev.token;
    if (!token) return fail('No session token configured in Settings → Developer Session');
    if (!safeEqual(String(d.token || ''), token)) return fail('Session token does not match the one configured in Settings');
    this.status.sessionId = String(d.sessionId || '').slice(0, 40);
    this._set('authorized', '', { env: d.env, app: String(d.app || '').slice(0, 40), sessionId: this.status.sessionId });
    clearTimeout(this.timer);
    this._post({ type: 'ack', sessionId: this.status.sessionId });
  }

  /** Latest sanitized snapshot (or null before the first frame). */
  update() {
    const now = performance.now();
    if (this.pending) {
      const raw = this.pending;
      this.pending = null;
      if (this.map && (!raw.obstacles || !raw.obstacles.length)) {
        raw.obstacles = this.map.obstacles;
        if (!raw.world && this.map.world) raw.world = this.map.world;
        if (!raw.meta && this.map.meta) raw.meta = this.map.meta;
      }
      const s = sanitizeSnapshot(raw, { source: 'dev' });
      if (s) {
        s.t = now / 1000;
        s.seq = ++this.seq;
        s.mapRev = this.mapRev;
        s.meta.source = 'dev';
        this.last = s;
        this.status.frames++;
      }
    }
    if (this.status.phase === 'authorized' && now - this.lastRecv > STALE_MS && this.last) {
      this._set('stale', 'No snapshots received');
    }
    return this.last;
  }
}
