// Small shared utilities: DOM builder, event bus, file helpers.

export const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
export const clone = (v) => JSON.parse(JSON.stringify(v));

export function deepMerge(target, patch) {
  for (const k of Object.keys(patch)) {
    if (isObj(patch[k]) && isObj(target[k])) deepMerge(target[k], patch[k]);
    else target[k] = isObj(patch[k]) ? clone(patch[k]) : patch[k];
  }
  return target;
}

export function debounce(fn, ms) {
  let t = 0;
  const wrapped = (...a) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...a), ms);
  };
  wrapped.cancel = () => clearTimeout(t);
  wrapped.flush = (...a) => {
    clearTimeout(t);
    fn(...a);
  };
  return wrapped;
}

export class Bus {
  constructor() {
    this.map = new Map();
  }
  on(evt, fn) {
    let set = this.map.get(evt);
    if (!set) this.map.set(evt, (set = new Set()));
    set.add(fn);
    return () => set.delete(fn);
  }
  emit(evt, ...args) {
    const set = this.map.get(evt);
    if (!set) return;
    for (const fn of [...set]) {
      try {
        fn(...args);
      } catch (e) {
        console.error('[SCC] listener error', evt, e);
      }
    }
  }
  clear() {
    this.map.clear();
  }
}

/** Relationship of a player to the local player: 'self' | 'ally' | 'enemy' | 'neutral'. */
export function relationOf(p, self) {
  if (p.id === self.id) return 'self';
  if (p.team == null || self.team == null) return 'neutral';
  return p.team === self.team ? 'ally' : 'enemy';
}

/** Tiny hyperscript helper. Pass `type` before `value` for inputs. */
export function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  if (props) {
    for (const k of Object.keys(props)) {
      const v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
      else if (k === 'html') el.innerHTML = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k.length > 2 && k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k in el && !k.includes('-')) el[k] = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  append(el, kids);
  return el;
}

function append(el, kids) {
  for (const k of kids) {
    if (k == null || k === false) continue;
    if (Array.isArray(k)) append(el, k);
    else el.append(k.nodeType ? k : document.createTextNode(String(k)));
  }
}

export const stamp = () => new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);

export function downloadJson(name, obj) {
  const blob = new Blob([JSON.stringify(obj)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export function pickJsonFile() {
  return new Promise((resolve, reject) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'application/json,.json';
    input.style.display = 'none';
    input.addEventListener('change', async () => {
      const f = input.files && input.files[0];
      input.remove();
      if (!f) return resolve(null);
      if (f.size > 64 * 1024 * 1024) return reject(new Error('File is larger than 64 MB'));
      try {
        resolve(JSON.parse(await f.text()));
      } catch (e) {
        reject(new Error('Not a valid JSON file'));
      }
    });
    document.body.append(input);
    input.click();
  });
}
