// Reactive, persisted application state.
//   state.data.cfg  -> profile-able configuration
//   state.data.loc  -> device-local state (master switch, UI position, saved profiles, dev token)
// Paths look like "cfg.aiming.fovRadius". Every context (popup, overlay, demo) shares the same
// chrome.storage.local keys and stays in sync via storage.onChanged.

import { DEFAULT_CFG, DEFAULT_LOCAL } from './defaults.js';
import { clone, debounce, isObj } from './util.js';

const KEYS = { cfg: 'scc.config', loc: 'scc.local' };
const FREE_FORM = new Set(['profiles', 'settingTests', 'gamePrefs']);

/** Merge saved values over defaults, dropping unknown keys and wrongly-typed values. */
export function mergeDefaults(def, sav, key = '') {
  if (isObj(def)) {
    const out = {};
    for (const k of Object.keys(def)) {
      if (FREE_FORM.has(k)) out[k] = isObj(sav && sav[k]) ? sav[k] : clone(def[k]);
      else out[k] = mergeDefaults(def[k], sav ? sav[k] : undefined, k);
    }
    return out;
  }
  if (Array.isArray(def)) return Array.isArray(sav) ? sav : def.slice();
  if (typeof def === 'number') return Number.isFinite(sav) ? sav : def;
  return typeof sav === typeof def ? sav : def;
}

export class State {
  constructor(storage) {
    this.storage = storage;
    this.data = { cfg: clone(DEFAULT_CFG), loc: clone(DEFAULT_LOCAL) };
    this.watchers = new Set();
    this.dirty = new Set();
    this.lastWritten = {};
    this.off = null;
    this.flush = debounce(() => this._flush(), 120);
  }

  get cfg() {
    return this.data.cfg;
  }
  get loc() {
    return this.data.loc;
  }

  async load() {
    const raw = await this.storage.get([KEYS.cfg, KEYS.loc]);
    this.data.cfg = mergeDefaults(DEFAULT_CFG, raw[KEYS.cfg]);
    this.data.loc = mergeDefaults(DEFAULT_LOCAL, raw[KEYS.loc]);
    this.lastWritten[KEYS.cfg] = JSON.stringify(this.data.cfg);
    this.lastWritten[KEYS.loc] = JSON.stringify(this.data.loc);
    this.off = this.storage.onChanged((changes) => this._remote(changes));
    return this;
  }

  destroy() {
    this.flush.flush && this._flush();
    this.flush.cancel();
    if (this.off) this.off();
    this.off = null;
    this.watchers.clear();
  }

  get(path) {
    let o = this.data;
    for (const k of path.split('.')) {
      if (o == null) return undefined;
      o = o[k];
    }
    return o;
  }

  set(path, value) {
    const parts = path.split('.');
    let o = this.data;
    for (let i = 0; i < parts.length - 1; i++) {
      if (!isObj(o[parts[i]])) o[parts[i]] = {};
      o = o[parts[i]];
    }
    const last = parts[parts.length - 1];
    if (o[last] === value) return;
    o[last] = value;
    this.dirty.add(parts[0]);
    this._notify(path);
    this.flush();
  }

  toggle(path) {
    this.set(path, !this.get(path));
  }

  /** Subscribe to a path (prefix match). Empty path = everything. Returns an unsubscribe fn. */
  watch(path, fn) {
    const w = { path, fn };
    this.watchers.add(w);
    return () => this.watchers.delete(w);
  }

  replaceCfg(cfg) {
    this.data.cfg = mergeDefaults(DEFAULT_CFG, cfg);
    this.dirty.add('cfg');
    this._notify('cfg');
    this.flush();
  }

  resetCfg() {
    this.replaceCfg(clone(DEFAULT_CFG));
  }

  _notify(path) {
    for (const w of [...this.watchers]) {
      if (!w.path || path.startsWith(w.path) || w.path.startsWith(path)) {
        try {
          w.fn(this.get(w.path || path), path);
        } catch (e) {
          console.error('[SCC] watcher error', path, e);
        }
      }
    }
  }

  async _flush() {
    if (!this.dirty.size) return;
    const out = {};
    for (const root of this.dirty) {
      const key = KEYS[root];
      const json = JSON.stringify(this.data[root]);
      if (this.lastWritten[key] !== json) {
        this.lastWritten[key] = json;
        out[key] = this.data[root];
      }
    }
    this.dirty.clear();
    if (Object.keys(out).length) await this.storage.set(out);
  }

  _remote(changes) {
    for (const root of ['cfg', 'loc']) {
      const key = KEYS[root];
      if (!(key in changes) || changes[key] == null) continue;
      const json = JSON.stringify(changes[key]);
      if (json === this.lastWritten[key]) continue; // our own write echoing back
      this.lastWritten[key] = json;
      this.data[root] = mergeDefaults(root === 'cfg' ? DEFAULT_CFG : DEFAULT_LOCAL, changes[key]);
      this._notify(root);
    }
  }
}
