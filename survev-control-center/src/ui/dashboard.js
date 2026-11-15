// Dashboard: tabbed control surface. Floating (draggable + minimizable) in the demo page and the
// in-page overlay; embedded (fills its container) in the toolbar popup.

import { h, Bus } from '../core/util.js';
import { THEMES, VERSION } from '../core/defaults.js';
import { prettyCombo } from '../core/keys.js';
import { logo, icon } from './icons.js';
import { buildControl } from './controls.js';
import { ALL_TABS, TAB_SETS } from './tabs.js';

const MODE_TEXT = { demo: 'Demo Arena', dev: 'Dev session', replay: 'Replay', popup: 'Control panel', live: 'Survev.io' };

export class Dashboard {
  /**
   * @param o.state State
   * @param o.app   App | null  (null in the popup: live widgets show a hint instead)
   * @param o.mode  'floating' | 'embedded'
   * @param o.parent element to mount into
   * @param o.getDevStatus async () => status
   * @param o.actions { reconnect?: fn }
   */
  constructor({ state, app = null, perf = null, pass = null, mode = 'floating', parent, getDevStatus, actions = {}, tabs = 'dev', label = null, defaultSide = 'right' }) {
    this.state = state;
    this.app = app;
    this.mode = mode;
    this.parent = parent;
    this.label = label;
    this.defaultSide = defaultSide;
    const ids = Array.isArray(tabs) ? tabs : TAB_SETS[tabs] || TAB_SETS.dev;
    this.tabs = ALL_TABS.filter((t) => ids.includes(t.id));
    this.disposers = [];
    this.toastTimer = 0;
    this.ctx = {
      state,
      app,
      perf,
      pass,
      bus: app ? app.bus : new Bus(),
      disposers: this.disposers,
      isShown: (el) => !!(el && el.closest('.scc-page.on') && !this.root.classList.contains('min') && !this.root.classList.contains('gone') && !document.hidden),
      watch: (path, fn) => {
        const off = state.watch(path, fn);
        this.disposers.push(off);
        return off;
      },
      toast: (t) => this.toast(t),
      getDevStatus: getDevStatus || (async () => ({ phase: 'none' })),
      actions,
    };
  }

  mount() {
    const { state } = this;
    const floating = this.mode === 'floating';

    this.panel = h('section', { class: 'scc-panel', role: 'region', 'aria-label': 'SURVEV.IO Control Center' });
    this.root = h('div', { class: 'scc-root ' + (floating ? 'floating' : 'embedded'), 'data-scc-ui': '' });
    this.float = h('div', { class: 'scc-float' });

    // ---- header
    this.statusText = h('span', { class: 'scc-status-text' });
    this.statusDot = h('span', { class: 'scc-dot' });
    this.powerBtn = h('button', { class: 'scc-iconbtn power', type: 'button', title: 'Master ON / OFF', 'aria-label': 'Master ON or OFF', html: icon('power', 17) });
    this.powerBtn.addEventListener('click', () => state.toggle('loc.master'));
    const minBtn = floating ? h('button', { class: 'scc-iconbtn', type: 'button', title: 'Minimize', 'aria-label': 'Minimize', html: icon('minus', 17) }) : null;
    if (minBtn) minBtn.addEventListener('click', () => state.set('loc.ui.minimized', true));
    this.header = h('header', { class: 'scc-head' },
      h('div', { class: 'scc-logo', html: logo() }),
      h('div', { class: 'scc-brand' },
        h('div', { class: 'scc-title' }, 'SURVEV.IO', h('i', { text: '|' }), h('span', { text: 'CONTROL CENTER' })),
        h('div', { class: 'scc-sub' }, this.statusDot, this.statusText)),
      h('div', { class: 'scc-head-actions' }, this.powerBtn, minBtn));

    // ---- tabs
    const many = this.tabs.length > 5;
    const tablist = h('nav', { class: 'scc-tabs' + (this.tabs.length > 4 ? ' many' : '') + (many ? ' six' : ''), role: 'tablist' });
    tablist.style.setProperty('--tabs', String(this.tabs.length));
    this.indicator = h('span', { class: 'scc-ind' });
    tablist.append(this.indicator);
    this.tabBtns = new Map();
    this.pages = new Map();
    const body = h('main', { class: 'scc-body' });
    for (const tab of this.tabs) {
      const b = h('button', { class: 'scc-tab', type: 'button', role: 'tab', id: `scc-tab-${tab.id}`, title: tab.title }, h('span', { class: 'scc-tab-i', html: icon(tab.icon, 17) }), h('span', { class: 'scc-tab-l', text: many ? tab.short : tab.label }));
      b.addEventListener('click', () => state.set('loc.ui.tab', tab.id));
      tablist.append(b);
      this.tabBtns.set(tab.id, b);
      const page = this.buildPage(tab);
      this.pages.set(tab.id, page);
      body.append(page);
    }
    this.banner = h('div', { class: 'scc-banner', text: 'Master is OFF — overlays are hidden. Settings are preserved.' });
    this.toastEl = h('div', { class: 'scc-toast', role: 'status' });

    this.panel.append(this.header, tablist, this.banner, body);
    if (floating && this.app) this.panel.append(this.buildTransport());
    this.panel.append(this.toastEl);

    // ---- minimized pill
    this.pill = h('button', { class: 'scc-pill', type: 'button', title: `SURVEV.IO | CONTROL CENTER v${VERSION} — click to expand, drag to move`, 'aria-label': 'Expand Control Center' },
      h('span', { class: 'scc-logo sm', html: logo() }), h('span', { class: 'scc-dot pill-dot' }));

    this.float.append(this.panel, this.pill);
    this.root.append(this.float);
    this.parent.append(this.root);
    if (floating) this.isolateInput();

    this.ctx.watch('cfg.theme', () => this.applyTheme());
    this.ctx.watch('cfg.perf.liteUi', () => this.applyTheme());
    this.ctx.watch('loc.master', () => this.refresh());
    this.ctx.watch('cfg.perf.monitor', () => setTimeout(() => this.refresh(), 0));
    this.ctx.watch('cfg.pass', () => this.refresh());
    this.ctx.watch('loc.ui', () => this.refresh());
    if (this.app) this.disposers.push(this.app.bus.on('status', () => this.refresh()));
    this.applyTheme();
    this.refresh();
    if (floating) {
      this.initDrag();
      this._onResize = () => this.place(false);
      window.addEventListener('resize', this._onResize);
      this.place(false);
    }
    requestAnimationFrame(() => this.root.classList.add('ready'));
  }

  destroy() {
    for (const d of this.disposers.splice(0)) {
      try {
        d();
      } catch (_) {
        /* ignore */
      }
    }
    if (this._onResize) window.removeEventListener('resize', this._onResize);
    clearTimeout(this.toastTimer);
    this.root && this.root.remove();
  }

  // ------------------------------------------------------------------ pages / cards
  buildPage(tab) {
    const page = h('section', { class: 'scc-page', role: 'tabpanel', 'aria-labelledby': `scc-tab-${tab.id}` },
      h('div', { class: 'scc-page-head' }, h('h2', { text: tab.title }), h('p', { text: tab.sub })));
    for (const card of tab.cards) page.append(this.buildCard(card));
    if (tab.cards.some((c) => c.advanced) || tab.id === 'settings') {
      const more = h('button', { class: 'scc-more', type: 'button' });
      more.addEventListener('click', () => this.state.toggle('loc.ui.advanced'));
      const upd = () => (more.textContent = this.state.get('loc.ui.advanced') ? 'Hide advanced settings' : 'Show advanced settings');
      this.ctx.watch('loc.ui.advanced', upd);
      upd();
      page.append(more);
    }
    return page;
  }

  buildCard(card) {
    const ctx = this.ctx;
    const inner = h('div', { class: 'scc-card-inner' });
    for (const r of card.rows) inner.append(buildControl(r, ctx));
    const collapse = h('div', { class: 'scc-collapse' }, inner);
    const chev = h('span', { class: 'scc-chev', html: icon('chevron', 16) });
    const titleBtn = h('button', { class: 'scc-card-t', type: 'button', 'aria-expanded': 'true' },
      h('span', { class: 'scc-card-tt' }, h('b', { text: card.title }), card.sub ? h('small', { text: card.sub }) : null), chev);
    const head = h('div', { class: 'scc-card-h' }, titleBtn);
    const el = h('div', { class: 'scc-card' + (card.advanced ? ' adv' : '') }, head, collapse);
    titleBtn.addEventListener('click', () => {
      const closed = el.classList.toggle('closed');
      titleBtn.setAttribute('aria-expanded', String(!closed));
    });
    if (card.enable) {
      const sw = h('button', { class: 'scc-switch', type: 'button', role: 'switch', 'aria-label': `Enable ${card.title}` }, h('span', { class: 'scc-knob' }));
      const upd = () => {
        const on = !!this.state.get(card.enable);
        sw.classList.toggle('on', on);
        sw.setAttribute('aria-checked', String(on));
        el.classList.toggle('off', !on);
      };
      sw.addEventListener('click', () => this.state.toggle(card.enable));
      ctx.watch(card.enable, upd);
      upd();
      head.append(sw);
    }
    return el;
  }

  // ------------------------------------------------------------------ transport (record / replay)
  buildTransport() {
    const app = this.app;
    const rec = h('button', { class: 'scc-tbtn', type: 'button', title: 'Record (start / stop)', 'aria-label': 'Record', html: icon('rec', 16) });
    const rep = h('button', { class: 'scc-tbtn', type: 'button', title: 'Replay last recording', 'aria-label': 'Replay', html: icon('play', 16) });
    const pau = h('button', { class: 'scc-tbtn', type: 'button', title: 'Pause / resume', 'aria-label': 'Pause', html: icon('pause', 16) });
    const sav = h('button', { class: 'scc-tbtn', type: 'button', title: 'Save recording as JSON', 'aria-label': 'Save recording', html: icon('download', 16) });
    const lod = h('button', { class: 'scc-tbtn', type: 'button', title: 'Load a recording', 'aria-label': 'Load recording', html: icon('upload', 16) });
    const scrub = h('input', { class: 'scc-scrub', type: 'range', min: 0, max: 1000, value: 0, 'aria-label': 'Replay position' });
    const label = h('span', { class: 'scc-tlabel' });
    const bar = h('footer', { class: 'scc-transport' }, rec, rep, pau, sav, lod, label, scrub);

    rec.addEventListener('click', () => app.toggleRecording());
    rep.addEventListener('click', () => {
      if (app.replay) app.exitReplay();
      else if (!app.enterReplay()) this.toast('Record something first (● button)');
    });
    pau.addEventListener('click', () => app.togglePause());
    sav.addEventListener('click', () => (app.exportReplay() ? this.toast('Recording saved') : this.toast('Nothing recorded yet')));
    lod.addEventListener('click', async () => {
      try {
        if (await app.importReplay()) this.toast('Replay loaded');
      } catch (e) {
        this.toast(e.message);
      }
    });
    let scrubbing = false;
    scrub.addEventListener('pointerdown', () => (scrubbing = true));
    scrub.addEventListener('input', () => app.seek(Number(scrub.value) / 1000));
    window.addEventListener('pointerup', () => (scrubbing = false));

    const upd = (s) => {
      const st = s || app.getStatus();
      rec.classList.toggle('on', st.recording);
      rec.innerHTML = icon(st.recording ? 'stop' : 'rec', 16);
      rec.disabled = !!st.replay;
      rep.innerHTML = icon(st.replay ? 'x' : 'play', 16);
      rep.title = st.replay ? 'Exit replay' : 'Replay last recording';
      rep.disabled = st.recording || (!st.replay && st.frames < 2);
      const playing = st.replay ? st.replay.playing : !st.paused;
      pau.innerHTML = icon(playing ? 'pause' : 'play', 16);
      pau.disabled = !st.replay && app.source.kind !== 'demo';
      sav.disabled = st.frames < 2;
      scrub.classList.toggle('scc-hidden', !st.replay);
      if (st.replay) {
        if (!scrubbing) scrub.value = Math.round(st.replay.fraction * 1000);
        label.textContent = `REPLAY ${(st.replay.fraction * st.replay.duration).toFixed(1)} / ${st.replay.duration.toFixed(1)} s`;
      } else if (st.recording) label.textContent = `● REC ${st.duration.toFixed(1)} s`;
      else label.textContent = st.frames >= 2 ? `${st.duration.toFixed(1)} s saved` : st.paused ? 'Paused' : 'Live';
      label.classList.toggle('rec', st.recording);
    };
    this.disposers.push(app.bus.on('status', upd));
    upd();
    return bar;
  }

  // ------------------------------------------------------------------ state sync
  refresh() {
    const { state } = this;
    const loc = state.data.loc;
    const tabId = this.pages.has(loc.ui.tab) ? loc.ui.tab : this.tabs[0].id;
    let idx = 0;
    let i = 0;
    for (const [id, b] of this.tabBtns) {
      const on = id === tabId;
      b.classList.toggle('on', on);
      b.setAttribute('aria-selected', String(on));
      this.pages.get(id).classList.toggle('on', on);
      if (on) idx = i;
      i++;
    }
    this.indicator.style.transform = `translateX(${idx * 100}%)`;
    this.indicator.style.width = `${100 / this.tabBtns.size}%`;
    this.root.dataset.master = loc.master ? 'on' : 'off';
    this.root.classList.toggle('simple', !loc.ui.advanced);
    const st = this.app ? this.app.getStatus() : null;
    const label = this.label || (st ? (st.mode === 'dev' ? MODE_TEXT.dev : MODE_TEXT[st.mode] || st.label) : MODE_TEXT.popup);
    this.statusText.textContent = `${label} · ${loc.master ? 'ACTIVE' : 'MASTER OFF'}`;
    const tone = !loc.master ? 'red' : st && st.recording ? 'red' : st && st.mode === 'replay' ? 'amber' : 'green';
    this.statusDot.className = `scc-dot ${tone}`;
    this.pill.querySelector('.pill-dot').className = `scc-dot pill-dot ${tone}`;
    const parts = [`SURVEV.IO | CONTROL CENTER v${VERSION}`, loc.master ? 'Active' : 'Master OFF'];
    if (this.ctx.perf) parts.push(this.ctx.perf.monitor.running ? 'FPS monitoring on' : 'FPS monitoring off');
    if (this.ctx.pass) parts.push(state.data.cfg.pass.track ? 'Pass tracking on' : 'Pass tracking off');
    if (this.ctx.pass && state.data.cfg.pass.autoClaim) parts.push('Auto claim on');
    parts.push(`${prettyCombo(state.data.cfg.shortcuts.dashboard)} or click to open`);
    this.pill.title = parts.join(' · ');
    this.powerBtn.classList.toggle('off', !loc.master);
    if (this.mode === 'floating') {
      const min = !!loc.ui.minimized;
      const changed = this.root.classList.contains('min') !== min;
      this.root.classList.toggle('min', min);
      // Size changes between icon and panel: re-clamp so the expanded panel is always fully on screen.
      if (changed && this.pos) requestAnimationFrame(() => this.place(false, this.state.data.loc.ui.x < 0 ? null : this.pos));
      this.root.classList.toggle('gone', !!loc.ui.hidden);
    }
  }

  applyTheme() {
    const t = this.state.data.cfg.theme;
    const accent = /^#[0-9a-f]{6}$/i.test(t.accent) ? t.accent : THEMES.electric.accent;
    const r = this.root.style;
    r.setProperty('--accent', accent);
    r.setProperty('--radius', `${t.radius}px`);
    r.setProperty('--panel-a', String(t.panelOpacity / 100));
    this.root.classList.toggle('compact', !!t.compact);
    this.root.dataset.motion = t.motion ? 'on' : 'off';
    this.root.classList.toggle('lite', !!this.state.data.cfg.perf.liteUi);
  }

  toast(text) {
    this.toastEl.textContent = text;
    this.toastEl.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.toastEl.classList.remove('show'), 2200);
  }

  /**
   * Keep the game from seeing interactions with the panel: presses, clicks, wheel and typing inside the panel
   * do not propagate to page listeners. Releases (mouseup/pointerup) are left alone so the game never gets a
   * stuck button. After a mouse click, buttons release focus so movement keys go straight back to the game.
   */
  isolateInput() {
    const stop = (e) => e.stopPropagation();
    for (const ev of ['mousedown', 'pointerdown', 'click', 'dblclick', 'wheel', 'contextmenu', 'touchstart']) {
      this.root.addEventListener(ev, stop, { passive: ev === 'wheel' || ev === 'touchstart' });
    }
    const keys = (e) => {
      const t = e.composedPath()[0];
      if (t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA')) e.stopPropagation();
    };
    for (const ev of ['keydown', 'keyup', 'keypress']) this.root.addEventListener(ev, keys);
    this.root.addEventListener('click', (e) => {
      if (e.detail === 0) return; // keyboard activation keeps focus for accessibility
      const t = e.composedPath()[0];
      const b = t && t.closest && t.closest('button, input[type=range]');
      if (b) b.blur();
    });
  }

  // ------------------------------------------------------------------ drag + placement
  place(save, override) {
    const ui = this.state.data.loc.ui;
    const w = this.float.offsetWidth || 384;
    let x = override ? override.x : ui.x;
    let y = override ? override.y : ui.y;
    if (x < 0 || y < 0) {
      // First run: pick a side that doesn't cover the host page's most important UI.
      x = this.defaultSide === 'left' ? 20 : Math.max(12, window.innerWidth - w - 20);
      y = 20;
    }
    x = Math.min(Math.max(8, x), Math.max(8, window.innerWidth - w - 8));
    const minH = this.state.data.loc.ui.minimized ? 56 : 280;
    y = Math.min(Math.max(8, y), Math.max(8, window.innerHeight - minH));
    this.float.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
    // keep the whole panel (including the transport bar) on screen wherever it is dragged
    this.panel.style.maxHeight = `${Math.max(260, Math.min(780, window.innerHeight - y - 12))}px`;
    this.pos = { x, y };
    if (save) {
      this.state.set('loc.ui.x', Math.round(x));
      this.state.set('loc.ui.y', Math.round(y));
    }
  }

  initDrag() {
    const start = (e, handle) => {
      if (e.button !== 0 || (e.target.closest && e.target.closest('button') && handle === this.header)) return;
      const sx = e.clientX;
      const sy = e.clientY;
      const ox = this.pos.x;
      const oy = this.pos.y;
      let moved = false;
      handle.setPointerCapture && handle.setPointerCapture(e.pointerId);
      const move = (ev) => {
        const dx = ev.clientX - sx;
        const dy = ev.clientY - sy;
        if (!moved && Math.hypot(dx, dy) < 4) return;
        moved = true;
        this.root.classList.add('dragging');
        this.place(false, { x: ox + dx, y: oy + dy });
      };
      const up = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', up);
        handle.removeEventListener('pointercancel', up);
        this.root.classList.remove('dragging');
        if (moved) this.place(true, this.pos);
        else if (handle === this.pill) this.state.set('loc.ui.minimized', false);
        handle._moved = moved;
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', up);
      handle.addEventListener('pointercancel', up);
    };
    this.header.addEventListener('pointerdown', (e) => start(e, this.header));
    this.pill.addEventListener('pointerdown', (e) => start(e, this.pill));
    this.pill.addEventListener('click', (e) => {
      e.preventDefault();
      if (e.detail === 0) this.state.set('loc.ui.minimized', false); // keyboard activation
    });
    this.header.addEventListener('dblclick', (e) => {
      if (!e.target.closest('button')) this.state.set('loc.ui.minimized', true);
    });
  }
}

