// Survevr Pass manager — reads the game's own pass panel and (optionally) presses the game's own Confirm button
// on the "new item unlocked" window.
//
// From the client bundle (BGmvCf-g.js):
//   * #pass-progress-level / #pass-progress-xp-current / #pass-progress-xp-target are written by the pass UI
//     from server data (XP animates toward the server value; placeholders are level 1 / 0 XP when logged out,
//     with #pass-locked shown).
//   * #pass-quest-<idx> holds .pass-quest-desc, .pass-quest-counter-current, .pass-quest-counter-target,
//     .pass-quest-xp and .pass-quest-timer.
//   * #modal-item-confirm is shown only for items the server already granted (account "pending confirm" list).
//     Clicking one of its `.close` elements hides it -> confirmNextItem(); if the clicked element has
//     data-confirm-all it calls confirmAllItems(). Both just acknowledge (ItemStatus.Ackd) already-owned items.
//
// This module never edits pass values, never calls game APIs, and never creates rewards. It reads text and,
// when Auto Claim is on, clicks the same button a player would click.

import { Bus } from '../core/util.js';

export const PASS_IDS = {
  level: 'pass-progress-level',
  xpCur: 'pass-progress-xp-current',
  xpTarget: 'pass-progress-xp-target',
  quests: ['pass-quest-0', 'pass-quest-1'],
  modal: 'modal-item-confirm',
  modalName: 'modal-item-confirm-name',
  locked: 'pass-locked',
};

/** "1,250 XP" -> 1250 ; returns null when no digits. */
export function parseIntLoose(text) {
  const m = String(text == null ? '' : text).replace(/[,\s]/g, '').match(/-?\d+/);
  return m ? Number(m[0]) : null;
}

function txt(el) {
  return el ? el.textContent.replace(/\s+/g, ' ').trim() : '';
}

export function isShown(el) {
  if (!el || !el.isConnected) return false;
  const cs = getComputedStyle(el);
  return cs.display !== 'none' && cs.visibility !== 'hidden' && Number(cs.opacity) > 0.05 && el.getClientRects().length > 0;
}

export class PassManager {
  constructor({ state, doc = document }) {
    this.state = state;
    this.doc = doc;
    this.bus = new Bus();
    this.observers = [];
    this.retry = 0;
    this.debounce = 0;
    this.settle = 0;
    this.claimTimer = 0;
    this.lastClick = 0;
    this.session = { startedAt: Date.now(), gained: 0, claims: 0 };
    this.prevQuests = new Map();
    this.status = 'Looking for the pass panel…';
    this._changed = this._changed.bind(this);
    this._modal = this._modal.bind(this);
  }

  start() {
    this._attach();
    this.offCfg = this.state.watch('cfg.pass.autoClaim', () => this._modal());
  }

  stop() {
    for (const o of this.observers) o.disconnect();
    this.observers = [];
    clearTimeout(this.retry);
    clearTimeout(this.debounce);
    clearTimeout(this.settle);
    clearTimeout(this.claimTimer);
    if (this.offCfg) this.offCfg();
    this.bus.clear();
  }

  $(id) {
    return this.doc.getElementById(id);
  }

  _attach(tries = 0) {
    const targets = [PASS_IDS.level, PASS_IDS.xpCur, PASS_IDS.xpTarget, ...PASS_IDS.quests].map((id) => this.$(id)).filter(Boolean);
    const modal = this.$(PASS_IDS.modal);
    if (!targets.length && !modal) {
      this.status = 'Pass panel not found on this page yet.';
      // The menu markup is static on survev.io; retry a few times in case it is still loading. No permanent polling.
      if (tries < 40) this.retry = setTimeout(() => this._attach(tries + 1), 3000);
      this.bus.emit('change');
      return;
    }
    for (const o of this.observers) o.disconnect();
    this.observers = [];
    if (targets.length) {
      const mo = new MutationObserver(this._changed);
      for (const t of targets) mo.observe(t, { childList: true, characterData: true, subtree: true });
      this.observers.push(mo);
    }
    const locked = this.$(PASS_IDS.locked);
    if (locked) {
      const lo = new MutationObserver(this._changed);
      lo.observe(locked, { attributes: true, attributeFilter: ['style', 'class'] });
      this.observers.push(lo);
    }
    if (modal) {
      const mo = new MutationObserver(this._modal);
      mo.observe(modal, { attributes: true, attributeFilter: ['style', 'class'] });
      this.observers.push(mo);
    }
    this.status = 'Watching the game’s pass panel.';
    this._changed();
    this._modal();
  }

  /** Current pass state read from the game's DOM. */
  read() {
    const lockedEl = this.$(PASS_IDS.locked);
    const level = parseIntLoose(txt(this.$(PASS_IDS.level)));
    const xp = parseIntLoose(txt(this.$(PASS_IDS.xpCur)));
    const target = parseIntLoose(txt(this.$(PASS_IDS.xpTarget)));
    const quests = PASS_IDS.quests.map((id, idx) => {
      const el = this.$(id);
      if (!el) return { idx, present: false };
      const q = (sel) => el.querySelector(sel);
      const cur = parseIntLoose(txt(q('.pass-quest-counter-current')));
      const tgt = parseIntLoose(txt(q('.pass-quest-counter-target')));
      return {
        idx,
        present: true,
        desc: txt(q('.pass-quest-desc')), // empty until the game loads quests (logged out / loading)
        cur,
        target: tgt,
        xp: parseIntLoose(txt(q('.pass-quest-xp'))),
        timer: txt(q('.pass-quest-timer')),
        complete: cur != null && tgt != null && tgt > 0 && cur >= tgt,
      };
    });
    const present = level != null || xp != null;
    return {
      present,
      locked: !!lockedEl && isShown(lockedEl),
      level,
      xp,
      target,
      pct: xp != null && target ? Math.max(0, Math.min(1, xp / target)) : null,
      toNext: xp != null && target != null ? Math.max(0, target - xp) : null,
      quests,
      modal: this.modalState(),
    };
  }

  modalState() {
    const m = this.$(PASS_IDS.modal);
    if (!m) return { present: false, open: false };
    return { present: true, open: isShown(m), item: txt(this.$(PASS_IDS.modalName)), hasAll: !!m.querySelector('[data-confirm-all="true"]') };
  }

  _changed() {
    clearTimeout(this.debounce);
    this.debounce = setTimeout(() => this.bus.emit('change'), 150);
    // XP animates toward the server value; record history only once the numbers have settled.
    clearTimeout(this.settle);
    this.settle = setTimeout(() => this._record(), 1600);
  }

  _record() {
    if (!this.state.data.cfg.pass.track) return;
    const r = this.read();
    if (!r.present || r.locked || r.level == null || r.xp == null) return;
    const last = this.state.data.loc.pass.last;
    const now = Date.now();
    const entries = [];
    if (last && (last.level !== r.level || last.xp !== r.xp)) {
      let gained = null;
      if (r.level === last.level && r.xp > last.xp) gained = r.xp - last.xp;
      else if (r.level === last.level + 1 && last.target != null) gained = last.target - last.xp + r.xp;
      if (gained != null && gained > 0) this.session.gained += gained;
      entries.push({ at: now, kind: r.level > last.level ? 'level' : 'xp', level: r.level, xp: r.xp, target: r.target, gained, prevLevel: last.level });
    }
    for (const q of r.quests) {
      if (!q.present) continue;
      const key = `${q.idx}|${q.desc}`;
      const prev = this.prevQuests.get(q.idx);
      if (prev && prev.key === key && !prev.complete && q.complete) entries.push({ at: now, kind: 'quest', desc: q.desc, xp: q.xp });
      this.prevQuests.set(q.idx, { key, complete: q.complete });
    }
    if (!last || last.level !== r.level || last.xp !== r.xp || last.target !== r.target) {
      this.state.set('loc.pass.last', { level: r.level, xp: r.xp, target: r.target, at: now });
    }
    if (entries.length) this.state.set('loc.pass.history', [...this.state.data.loc.pass.history, ...entries].slice(-100));
    this.bus.emit('change');
  }

  // ------------------------------------------------------------------ claiming
  _modal() {
    const ms = this.modalState();
    this.bus.emit('change');
    if (!ms.open || !this.state.data.cfg.pass.autoClaim) return;
    clearTimeout(this.claimTimer);
    // The game fills the item name ~200 ms after showing the window; give it a moment and act like a person would.
    this.claimTimer = setTimeout(() => this.confirm('auto'), 700);
  }

  /** Press the game's own Confirm button. Returns a result string. */
  confirm(source = 'manual') {
    const m = this.$(PASS_IDS.modal);
    if (!m || !isShown(m)) return 'no-window';
    if (Date.now() - this.lastClick < 900) {
      this.claimTimer = setTimeout(() => this.confirm(source), 900);
      return 'rate-limited';
    }
    const mode = this.state.data.cfg.pass.claimMode;
    const all = m.querySelector('[data-confirm-all="true"]');
    let btn = null;
    if (mode === 'all' && all && isShown(all)) btn = all;
    else btn = [...m.querySelectorAll('.close')].find((b) => !b.matches('[data-confirm-all="true"]') && isShown(b)) || (all && isShown(all) ? all : null);
    if (!btn) {
      this.status = 'Unlock window is open but no Confirm button was found.';
      this.bus.emit('change');
      return 'no-button';
    }
    const item = txt(this.$(PASS_IDS.modalName)) || 'Unlocked item';
    const isAll = btn.matches('[data-confirm-all="true"]');
    this.lastClick = Date.now();
    btn.click(); // the game's own handler acknowledges the already-granted item(s)
    this.session.claims++;
    const claims = [...this.state.data.loc.pass.claims, { at: Date.now(), item, all: isAll, source }].slice(-100);
    this.state.set('loc.pass.claims', claims);
    this.bus.emit('change');
    return isAll ? 'confirmed-all' : 'confirmed';
  }
}
