// Declarative control builders for the dashboard.
// A control spec is a plain object ({type, path, label, ...}); buildControl() returns an element
// bound to the shared State and registers cleanup in ctx.disposers.

import { h } from '../core/util.js';
import { icon } from './icons.js';
import { comboFromEvent, prettyCombo, prettyCode, isModifierCode } from '../core/keys.js';

const el = (html) => h('span', { class: 'scc-ico', html });

function rowShell(spec, control, stacked = false) {
  const head = h('div', { class: 'scc-row-text' },
    h('div', { class: 'scc-label' }, spec.label, spec.badge ? h('span', { class: 'scc-badge', text: spec.badge }) : null),
    spec.hint ? h('div', { class: 'scc-hint', text: spec.hint }) : null);
  return h('div', { class: 'scc-row' + (stacked ? ' stacked' : '') }, head, control);
}

function toggleControl(spec, ctx) {
  const sw = h('button', { class: 'scc-switch', type: 'button', role: 'switch', 'aria-label': spec.label || 'toggle' }, h('span', { class: 'scc-knob' }));
  const upd = () => {
    const on = !!ctx.state.get(spec.path);
    sw.classList.toggle('on', on);
    sw.setAttribute('aria-checked', String(on));
  };
  sw.addEventListener('click', () => ctx.state.toggle(spec.path));
  ctx.watch(spec.path, upd);
  upd();
  return sw;
}

function sliderControl(spec, ctx) {
  const input = h('input', { type: 'range', min: spec.min, max: spec.max, step: spec.step || 1, 'aria-label': spec.label });
  const out = h('span', { class: 'scc-val' });
  const upd = () => {
    const v = Number(ctx.state.get(spec.path));
    if (Number(input.value) !== v) input.value = v;
    out.textContent = spec.format ? spec.format(v) : `${v}${spec.unit || ''}`;
    input.style.setProperty('--p', `${((v - spec.min) / (spec.max - spec.min)) * 100}%`);
  };
  input.addEventListener('input', () => {
    ctx.state.set(spec.path, Number(input.value));
    upd();
  });
  ctx.watch(spec.path, upd);
  upd();
  const body = h('div', { class: 'scc-slider' }, input);
  const row = rowShell({ ...spec, badge: null }, body, true);
  row.querySelector('.scc-label').append(out);
  return row;
}

function segControl(spec, ctx) {
  const opts = spec.options.map((o) => (typeof o === 'string' ? { v: o, l: o } : o));
  const wrap = h('div', { class: 'scc-seg', role: 'radiogroup', 'aria-label': spec.label });
  const btns = opts.map((o) => {
    const b = h('button', { type: 'button', role: 'radio', text: o.l });
    b.addEventListener('click', () => ctx.state.set(spec.path, o.v));
    wrap.append(b);
    return [o.v, b];
  });
  const upd = () => {
    const cur = ctx.state.get(spec.path);
    for (const [v, b] of btns) {
      b.classList.toggle('on', v === cur);
      b.setAttribute('aria-checked', String(v === cur));
    }
  };
  ctx.watch(spec.path, upd);
  upd();
  return spec.label ? rowShell(spec, wrap, true) : wrap;
}

function colorControl(spec, ctx) {
  const input = h('input', { type: 'color', 'aria-label': spec.label });
  const sw = h('span', { class: 'scc-swatch' });
  const hex = h('span', { class: 'scc-hex' });
  const upd = () => {
    const v = ctx.state.get(spec.path);
    input.value = v;
    sw.style.background = v;
    hex.textContent = String(v).toUpperCase();
  };
  input.addEventListener('input', () => ctx.state.set(spec.path, input.value));
  ctx.watch(spec.path, upd);
  upd();
  return rowShell(spec, h('label', { class: 'scc-color' }, hex, sw, input));
}

function keyControl(spec, ctx) {
  const btn = h('button', { class: 'scc-key', type: 'button' });
  const upd = () => {
    const v = ctx.state.get(spec.path);
    btn.textContent = spec.single ? (v ? prettyCode(v) : 'Unbound') : prettyCombo(v);
    btn.classList.toggle('unbound', !v);
  };
  let capturing = null;
  const stop = () => {
    if (capturing) window.removeEventListener('keydown', capturing, true);
    capturing = null;
    btn.classList.remove('capture');
    upd();
  };
  btn.addEventListener('click', () => {
    if (capturing) return stop();
    btn.classList.add('capture');
    btn.textContent = spec.single ? 'Press a key…' : 'Press shortcut…';
    capturing = (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === 'Escape') return stop();
      if (e.key === 'Backspace' || e.key === 'Delete') {
        ctx.state.set(spec.path, '');
        return stop();
      }
      let val;
      if (spec.single) val = e.code;
      else {
        if (isModifierCode(e.code)) return; // wait for the main key
        val = comboFromEvent(e);
        if (!e.altKey && !e.ctrlKey && !e.metaKey) {
          btn.textContent = 'Hold Alt/Ctrl/⌘ + key';
          return;
        }
      }
      const clash = (spec.conflicts || []).find((p) => p !== spec.path && ctx.state.get(p) === val);
      if (clash) {
        btn.classList.add('error');
        btn.textContent = 'Already in use';
        setTimeout(() => btn.classList.remove('error'), 900);
        return;
      }
      ctx.state.set(spec.path, val);
      stop();
    };
    window.addEventListener('keydown', capturing, true);
  });
  btn.addEventListener('blur', stop);
  ctx.watch(spec.path, upd);
  ctx.disposers.push(stop);
  upd();
  return rowShell(spec, btn);
}

function buttonControl(spec) {
  const b = h('button', { class: 'scc-btn ' + (spec.variant || ''), type: 'button' }, spec.icon ? el(icon(spec.icon, 15)) : null, spec.text);
  b.addEventListener('click', (e) => spec.onClick(e, b));
  return b;
}

export function buildControl(spec, ctx) {
  let node;
  switch (spec.type) {
    case 'toggle':
      node = rowShell(spec, toggleControl(spec, ctx));
      break;
    case 'slider':
      node = sliderControl(spec, ctx);
      break;
    case 'seg':
      node = segControl(spec, ctx);
      break;
    case 'color':
      node = colorControl(spec, ctx);
      break;
    case 'key':
      node = keyControl(spec, ctx);
      break;
    case 'note':
      node = h('p', { class: 'scc-note ' + (spec.tone || ''), text: spec.text });
      break;
    case 'custom':
      node = spec.render(ctx);
      break;
    default:
      node = h('div');
  }
  if (spec.advanced) node.classList.add('adv');
  if (spec.showIf) {
    const upd = () => node.classList.toggle('scc-hidden', !spec.showIf(ctx.state));
    ctx.watch('', upd);
    upd();
  }
  return node;
}

export { buttonControl, el };
