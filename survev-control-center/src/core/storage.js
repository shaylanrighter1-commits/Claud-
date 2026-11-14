// Storage abstraction: chrome.storage.local inside the extension, localStorage fallback elsewhere
// (lets the UI be opened from a plain http server for development).

export function createStorage(onInvalidated) {
  const c = globalThis.chrome;
  try {
    if (c && c.storage && c.storage.local) return new ChromeStorage(c, onInvalidated);
  } catch (_) {
    /* fall through */
  }
  return new LocalStorage();
}

class ChromeStorage {
  constructor(c, onInvalidated) {
    this.c = c;
    this.onInvalidated = onInvalidated;
    this.alive = true;
    this.kind = 'chrome.storage.local';
  }
  _err(e) {
    if (/context invalidated/i.test((e && e.message) || '')) {
      if (this.alive) {
        this.alive = false;
        if (this.onInvalidated) this.onInvalidated();
      }
    } else {
      console.warn('[SCC] storage error', e);
    }
  }
  async get(keys) {
    if (!this.alive) return {};
    try {
      return await this.c.storage.local.get(keys);
    } catch (e) {
      this._err(e);
      return {};
    }
  }
  async set(obj) {
    if (!this.alive) return;
    try {
      await this.c.storage.local.set(obj);
    } catch (e) {
      this._err(e);
    }
  }
  onChanged(cb) {
    const fn = (changes, area) => {
      if (area !== 'local') return;
      const out = {};
      for (const k of Object.keys(changes)) out[k] = changes[k].newValue;
      cb(out);
    };
    try {
      this.c.storage.onChanged.addListener(fn);
    } catch (e) {
      this._err(e);
    }
    return () => {
      try {
        this.c.storage.onChanged.removeListener(fn);
      } catch (_) {
        /* context gone */
      }
    };
  }
}

class LocalStorage {
  constructor() {
    this.kind = 'localStorage (fallback)';
    this.alive = true;
  }
  async get(keys) {
    const out = {};
    for (const k of keys) {
      try {
        const v = localStorage.getItem('scc:' + k);
        if (v != null) out[k] = JSON.parse(v);
      } catch (_) {
        /* ignore */
      }
    }
    return out;
  }
  async set(obj) {
    for (const k of Object.keys(obj)) {
      try {
        localStorage.setItem('scc:' + k, JSON.stringify(obj[k]));
      } catch (_) {
        /* quota or blocked */
      }
    }
  }
  onChanged(cb) {
    const fn = (e) => {
      if (!e.key || !e.key.startsWith('scc:')) return;
      try {
        cb({ [e.key.slice(4)]: e.newValue ? JSON.parse(e.newValue) : undefined });
      } catch (_) {
        /* ignore */
      }
    };
    window.addEventListener('storage', fn);
    return () => window.removeEventListener('storage', fn);
  }
}
