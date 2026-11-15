// Performance Boost controller: frame monitoring, presets, game-settings integration, auto optimization,
// before/after benchmarks and network diagnostics. One instance per page that hosts the dashboard.

import { Bus, clone } from '../core/util.js';
import { DEFAULT_CFG } from '../core/defaults.js';
import { FrameMonitor } from './frame-monitor.js';
import { summarize, compareRuns, rateRendering } from './stats.js';
import { GameSettings, GAME_SETTINGS } from './game-settings.js';
import { NetMonitor } from './net-monitor.js';
import { probeEnvironment, environmentFindings } from './env.js';
import { PRESETS, PRESET_ORDER, OVERLAY_PATHS, OVERLAY_LABELS, presetLevel } from './presets.js';

const AUTO_WINDOW = 10; // seconds evaluated
const AUTO_BELOW_NEEDED = 7; // of AUTO_WINDOW seconds below 90% of target
const AUTO_COOLDOWN_MS = 30000;
const AUTO_SETTLE_MS = 12000; // measure this long after a change before judging it

const settingLabel = (id) => (GAME_SETTINGS.find((s) => s.id === id) || { label: id }).label;

export class PerfController {
  /**
   * @param o.state State
   * @param o.app   App (for overlay cost + dev-API net data) or null
   * @param o.mode  'overlay' (private dev page) | 'live' (survev.io) | 'demo'
   */
  constructor({ state, app = null, mode = 'overlay', doc = document }) {
    this.state = state;
    this.app = app;
    this.mode = mode;
    this.bus = new Bus();
    this.monitor = new FrameMonitor();
    this.settings = new GameSettings(doc);
    const httpPage = /^https?:$/.test(location.protocol);
    this.net = new NetMonitor({ origin: location.origin, allowProbe: mode === 'overlay' && httpPage });
    this.env = null;
    this.bench = { running: null, progress: 0, cancel: null };
    this.auto = { lastChangeAt: 0, pending: null, ineffective: 0, note: 'Off', state: 'off' };
    this.lastResult = null;
    this.offs = [];
    this.netKey = '';
    this.started = false;
  }

  start() {
    if (this.started) return;
    this.started = true;
    this.offs.push(this.monitor.onTick(() => this._tick()));
    this.offs.push(
      this.settings.watch((id, checked, byPlayer) => {
        if (byPlayer) this.rememberPref(id, checked); // the player changed it in the game's own menu
        this.bus.emit('settings');
      })
    );
    this.offs.push(this.state.watch('cfg.perf', () => this._sync()));
    this.net.start();
    this._sync();
  }

  destroy() {
    this.started = false;
    for (const off of this.offs.splice(0)) off();
    if (this.bench.cancel) this.bench.cancel('Controller stopped');
    this.monitor.stop();
    this.net.stop();
    this.bus.clear();
  }

  get cfg() {
    return this.state.data.cfg.perf;
  }

  /** Start/stop the monitor and the optional probe so nothing runs that isn't needed. */
  _sync() {
    const p = this.cfg;
    const need = p.monitor || p.autoOptimize || !!this.bench.running;
    if (need) this.monitor.start();
    else this.monitor.stop();
    const key = JSON.stringify(p.net);
    if (key !== this.netKey) {
      this.netKey = key;
      this.net.setProbe(p.net);
    }
    if (!p.autoOptimize) {
      this.auto.pending = null;
      this.auto.ineffective = 0;
      this.auto.state = 'off';
      this.auto.note = 'Auto optimization is off.';
    } else if (this.auto.state === 'off') {
      this.auto.state = 'watching';
      this.auto.note = `Collecting ${AUTO_WINDOW} s of frame data…`;
    }
    this.bus.emit('config');
  }

  _tick() {
    const snapNet = this.app && this.app.lastSnap && this.app.lastSnap.net;
    if (snapNet) this.net.ingestGame(snapNet);
    if (this.cfg.autoOptimize) this._autoEval();
    this.bus.emit('tick');
  }

  // ------------------------------------------------------------------ live metrics
  effectiveTarget() {
    const t = this.cfg.targetFps;
    const r = this.monitor.refreshHz;
    return r && r < t ? { fps: r, capped: true, display: r } : { fps: t, capped: false, display: r };
  }

  live() {
    const win = this.cfg.window;
    const ft = this.monitor.window(win);
    const refresh = this.monitor.refreshHz;
    const s = summarize(ft, refresh);
    const tgt = this.effectiveTarget();
    return {
      running: this.monitor.running,
      cur: this.monitor.currentFps(),
      s,
      ft,
      win,
      refresh,
      target: tgt,
      status: this.status(s, tgt.fps),
      rating: rateRendering(s, tgt.fps),
      long: this.monitor.longFramesSince(win * 1000),
      loaf: this.monitor.loafSupported,
      drops: this.monitor.drops.slice(-5),
      sessionStutters: this.monitor.sessionStutters,
      sessionFrames: this.monitor.sessionFrames,
      res: this.settings.resolution(),
      overlayCost: this.app ? this.app.costMs : null,
    };
  }

  status(s, target) {
    if (!this.monitor.running) return { key: 'off', label: 'Monitoring off', tone: 'muted' };
    if (!s || s.frames < 30) return { key: 'measuring', label: 'Measuring…', tone: 'accent' };
    if (s.avgFps < target * 0.8) return { key: 'below', label: 'Below target', tone: 'red' };
    if (s.stuttersPerMin > 6 || s.low1Fps < target * 0.5) return { key: 'unstable', label: 'Unstable pacing', tone: 'amber' };
    if (s.avgFps >= target * 0.95) return { key: 'smooth', label: 'Smooth', tone: 'green' };
    return { key: 'near', label: 'Near target', tone: 'amber' };
  }

  async environment(force = false) {
    if (!this.env || force) this.env = await probeEnvironment();
    return { env: this.env, findings: environmentFindings(this.env, this.monitor.refreshHz), tier: this.settings.textureTier(this.env) };
  }

  // ------------------------------------------------------------------ presets / settings
  _saveOriginal() {
    if (this.state.data.loc.perf.original) return;
    const overlay = {};
    for (const [k, path] of Object.entries(OVERLAY_PATHS)) overlay[k] = this.state.get(path);
    const game = {};
    const read = this.settings.read();
    for (const [id, v] of Object.entries(read)) if (v.present) game[id] = v.checked;
    this.state.set('loc.perf.original', { at: Date.now(), overlay, game, preset: this.cfg.preset });
  }

  /** Apply a preset. Live-safe changes apply immediately; reload-type game settings are returned as `pending`. */
  applyPreset(id, { source = 'manual' } = {}) {
    const p = PRESETS[id];
    if (!p) throw new Error('Unknown preset');
    this._saveOriginal();
    const changes = [];
    const pending = [];
    for (const [k, v] of Object.entries(p.overlay)) {
      // On the live site there is no overlay renderer; only the dashboard's own weight matters.
      if (this.mode === 'live' && k !== 'liteUi') continue;
      const path = OVERLAY_PATHS[k];
      const cur = this.state.get(path);
      if (cur !== v) {
        this.state.set(path, v);
        changes.push({ kind: 'overlay', key: k, label: OVERLAY_LABELS[k], from: cur, to: v, status: 'applied' });
      }
    }
    for (const [sid, v] of Object.entries(p.game)) {
      const meta = GAME_SETTINGS.find((s) => s.id === sid);
      const r = this.settings.set(sid, v);
      const base = { kind: 'game', key: sid, label: meta.label, to: v };
      if (r === 'changed' || r === 'needs-reload' || r === 'unchanged') this.rememberPref(sid, v);
      if (r === 'changed') changes.push({ ...base, status: meta.applies === 'next-match' ? 'next-match' : 'applied' });
      else if (r === 'needs-reload') {
        changes.push({ ...base, status: 'needs-reload' });
        pending.push({ id: sid, value: v });
      } else if (r === 'missing') changes.push({ ...base, status: 'missing' });
      else if (r === 'disabled' || r === 'failed') changes.push({ ...base, status: r });
    }
    this.state.set('cfg.perf.preset', id);
    this.lastResult = { kind: 'preset', preset: id, source, at: Date.now(), changes, pending };
    this.bus.emit('settings');
    return this.lastResult;
  }

  /** Apply reload-type game settings through the game's control. The game reloads the page itself. */
  async applyPending() {
    const pending = (this.lastResult && this.lastResult.pending) || [];
    if (!pending.length) return false;
    await this.state._flush(); // make sure everything is persisted before the page goes away
    for (const { id, value } of pending) this.settings.set(id, value, { allowReload: true });
    return true;
  }

  setGameSetting(id, value) {
    const meta = GAME_SETTINGS.find((s) => s.id === id);
    if (!meta) return 'missing';
    this._saveOriginal();
    const r = this.settings.set(id, value, { allowReload: true });
    if (r === 'changed' || r === 'unchanged') this.rememberPref(id, value);
    this.bus.emit('settings');
    return r;
  }

  /** Remember the player's choice for one of the game's settings (persisted in chrome.storage.local). */
  rememberPref(id, value) {
    const prefs = this.cfg.gamePrefs || {};
    if (prefs[id] === value) return;
    this.state.set('cfg.perf.gamePrefs', { ...prefs, [id]: value });
  }

  /**
   * Re-apply saved preferences after the game has initialised its own settings (once per page load).
   * Settings that apply from the next match are set through the game's checkbox. High-res textures would make
   * the game reload the page, so it is never applied automatically — it is reported as pending instead.
   */
  applySavedPrefs() {
    const out = { applied: [], pending: [], at: Date.now() };
    if (!this.cfg.applyOnLoad) {
      this.loadApply = { ...out, skipped: true };
      return this.loadApply;
    }
    const read = this.settings.read();
    for (const [id, v] of Object.entries(this.cfg.gamePrefs || {})) {
      if (v == null || !read[id] || !read[id].present || read[id].checked === v) continue;
      const meta = GAME_SETTINGS.find((s) => s.id === id);
      const r = this.settings.set(id, v);
      if (r === 'changed') out.applied.push({ id, label: meta.label, value: v });
      else if (r === 'needs-reload') out.pending.push({ id, label: meta.label, value: v });
    }
    if (out.pending.length) this.lastResult = { kind: 'prefs', at: Date.now(), changes: [], pending: out.pending.map((p) => ({ id: p.id, value: p.value })) };
    this.loadApply = out;
    this.bus.emit('settings');
    return out;
  }

  restoreOriginal() {
    const o = this.state.data.loc.perf.original;
    if (!o) return { restored: 0, pending: [] };
    let restored = 0;
    for (const [k, path] of Object.entries(OVERLAY_PATHS)) {
      if (k in o.overlay && this.state.get(path) !== o.overlay[k]) {
        this.state.set(path, o.overlay[k]);
        restored++;
      }
    }
    const pending = [];
    for (const [id, v] of Object.entries(o.game || {})) {
      this.rememberPref(id, v);
      const r = this.settings.set(id, v);
      if (r === 'changed') restored++;
      else if (r === 'needs-reload') pending.push({ id, value: v });
    }
    this.state.set('cfg.perf.preset', o.preset || '');
    if (!pending.length) this.state.set('loc.perf.original', null);
    this.lastResult = { kind: 'restore', at: Date.now(), changes: [], pending };
    this.bus.emit('settings');
    return { restored, pending };
  }

  restoreDefaults() {
    const r = this.restoreOriginal();
    const keepProbe = this.cfg.net;
    this.state.set('cfg.perf', { ...clone(DEFAULT_CFG.perf), net: { ...clone(DEFAULT_CFG.perf.net), endpoint: keepProbe.endpoint } });
    this.auto = { lastChangeAt: 0, pending: null, ineffective: 0, note: 'Auto optimization is off.', state: 'off' };
    return r;
  }

  // ------------------------------------------------------------------ benchmark
  _context() {
    const read = this.settings.read();
    const game = {};
    for (const [id, v] of Object.entries(read)) if (v.present) game[id] = v.checked;
    const snap = this.app && this.app.lastSnap;
    return {
      preset: this.cfg.preset,
      game,
      liteUi: this.cfg.liteUi,
      master: this.state.data.loc.master,
      res: this.settings.resolution(),
      players: snap ? snap.players.length : null,
      host: location.host || this.mode,
    };
  }

  /** Measure `seconds` of real frames. phase = 'before' | 'after'. */
  runBenchmark(phase, seconds = this.cfg.benchSeconds) {
    if (this.bench.running) return Promise.reject(new Error('A measurement is already running'));
    if (document.hidden) return Promise.reject(new Error('Bring the game tab to the front first'));
    this.bench.running = phase;
    this.bench.progress = 0;
    this._sync();
    const total = seconds * 1000;
    return new Promise((resolve, reject) => {
      const ft = [];
      const perSecond = [];
      let start = null;
      let secN = 0;
      let secSum = 0;
      let lastFrame = performance.now();
      const cleanup = () => {
        offFrame();
        document.removeEventListener('visibilitychange', onVis);
        clearInterval(watchdog);
        this.bench.running = null;
        this.bench.cancel = null;
        this._sync();
        this.bus.emit('bench');
      };
      const fail = (msg) => {
        cleanup();
        reject(new Error(msg));
      };
      const onVis = () => document.hidden && fail('The tab was hidden, so the measurement was discarded. Keep the game visible while measuring.');
      const watchdog = setInterval(() => {
        if (performance.now() - lastFrame > 4000) fail('No frames were rendered for 4 s — measurement discarded.');
      }, 1000);
      const offFrame = this.monitor.onFrame((d, ts) => {
        lastFrame = performance.now();
        if (start == null) start = ts - d;
        ft.push(d);
        secN++;
        secSum += d;
        if (secSum >= 1000) {
          perSecond.push((secN * 1000) / secSum);
          secN = 0;
          secSum = 0;
        }
        this.bench.progress = Math.min(1, (ts - start) / total);
        if (ts - start >= total) {
          const s = summarize(ft, this.monitor.refreshHz);
          const result = { ...s, perSecond, seconds, at: Date.now(), context: this._context() };
          cleanup();
          this.state.set(`loc.perf.bench.${phase}`, result);
          if (phase === 'after') this._attribute();
          resolve(result);
        }
      });
      document.addEventListener('visibilitychange', onVis);
      this.bench.cancel = fail;
      this.bus.emit('bench');
    });
  }

  clearBenchmarks() {
    this.state.set('loc.perf.bench', { before: null, after: null });
  }

  /** Compare stored runs and describe what differed between them. */
  comparison() {
    const { before, after } = this.state.data.loc.perf.bench;
    if (!before || !after) return null;
    const cmp = compareRuns(before, after);
    const notes = [];
    const bc = before.context || {};
    const ac = after.context || {};
    const diffs = [];
    for (const id of new Set([...Object.keys(bc.game || {}), ...Object.keys(ac.game || {})])) {
      if ((bc.game || {})[id] !== (ac.game || {})[id]) diffs.push(`${settingLabel(id)}: ${fmtBool(bc.game?.[id])} → ${fmtBool(ac.game?.[id])}`);
    }
    if (bc.preset !== ac.preset) diffs.push(`Preset: ${presetName(bc.preset)} → ${presetName(ac.preset)}`);
    if (bc.liteUi !== ac.liteUi) diffs.push(`Lightweight dashboard: ${fmtBool(bc.liteUi)} → ${fmtBool(ac.liteUi)}`);
    if (bc.master !== ac.master) diffs.push(`Control Center overlays: ${bc.master ? 'on' : 'off'} → ${ac.master ? 'on' : 'off'}`);
    if (!diffs.length) notes.push('A/A check: no settings changed between the runs, so any difference is normal run-to-run variation.');
    if (bc.res && ac.res && (bc.res.backingW !== ac.res.backingW || bc.res.backingH !== ac.res.backingH)) notes.push(`Render resolution changed (${bc.res.backingW}×${bc.res.backingH} → ${ac.res.backingW}×${ac.res.backingH}).`);
    if (bc.players != null && ac.players != null && Math.abs(bc.players - ac.players) > Math.max(2, bc.players * 0.3)) notes.push(`Scene differed (${bc.players} vs ${ac.players} players on screen data).`);
    if (before.seconds !== after.seconds) notes.push('Runs used different measurement windows.');
    notes.push('Estimate: in-game conditions (map area, players, effects on screen) can differ between windows. Repeat both runs in a similar situation for a fair comparison.');
    return { ...cmp, diffs, notes, before, after };
  }

  _attribute() {
    const c = this.comparison();
    if (!c || c.verdict === 'insufficient') return;
    const bc = c.before.context.game || {};
    const ac = c.after.context.game || {};
    const changed = Object.keys(ac).filter((id) => id in bc && bc[id] !== ac[id]);
    if (!changed.length) return;
    const tests = { ...this.state.data.loc.perf.settingTests };
    const avg = c.rows[0];
    for (const id of changed) {
      tests[id] = { verdict: c.verdict, pct: avg.pct, p: c.p, to: ac[id], at: Date.now(), combined: changed.length > 1 ? changed : null };
    }
    this.state.set('loc.perf.settingTests', tests);
  }

  // ------------------------------------------------------------------ auto optimization
  _recentSeconds(n, sincePerf = 0) {
    const nowSec = performance.now() / 1000;
    return this.monitor.seconds.filter((b) => b.sec >= nowSec - n - 1.5 && b.sec * 1000 >= sincePerf).slice(-n);
  }

  _autoEval() {
    const A = this.auto;
    if (this.bench.running) return;
    const tgt = this.effectiveTarget().fps;
    const now = Date.now();

    if (A.pending) {
      if (now - A.pending.at < AUTO_SETTLE_MS) {
        A.state = 'verifying';
        A.note = `Measuring the effect of the change… ${Math.ceil((AUTO_SETTLE_MS - (now - A.pending.at)) / 1000)} s`;
        return;
      }
      const after = this._recentSeconds(AUTO_WINDOW, A.pending.atPerf + 2000);
      if (after.length < 6) return;
      const log = this.state.data.loc.perf.autoLog.map((e) => ({ ...e }));
      const entry = log.find((e) => e.id === A.pending.id);
      const avg = after.reduce((s, b) => s + b.fps, 0) / after.length;
      if (entry) {
        const gain = entry.before.avg ? (avg - entry.before.avg) / entry.before.avg : 0;
        entry.after = { avg, seconds: after.length };
        entry.effect = gain >= 0.03 ? `+${Math.round(gain * 100)}% average FPS (estimate)` : 'No measurable FPS gain from this step';
        if (gain < 0.03) A.ineffective++;
        this.state.set('loc.perf.autoLog', log);
      }
      A.pending = null;
      A.lastChangeAt = now;
      return;
    }

    // Only the tab you are actually playing in may change shared settings (prevents two open tabs fighting).
    if (document.hidden || !document.hasFocus()) {
      A.state = 'watching';
      A.note = 'Paused — this tab is not focused. Auto optimization acts only in the tab you are playing in.';
      return;
    }
    const last = this._recentSeconds(AUTO_WINDOW);
    if (last.length < AUTO_WINDOW) {
      A.state = 'watching';
      A.note = `Collecting ${AUTO_WINDOW} s of frame data… (${last.length}/${AUTO_WINDOW})`;
      return;
    }
    const avg = last.reduce((s, b) => s + b.fps, 0) / last.length;
    const below = last.filter((b) => b.fps < tgt * 0.9).length;
    const stutters = last.reduce((s, b) => s + b.stutters, 0);
    const poor = below >= AUTO_BELOW_NEEDED || stutters >= 8;
    if (now - A.lastChangeAt < AUTO_COOLDOWN_MS) {
      A.state = 'cooldown';
      A.note = `Cooldown after last change (${Math.ceil((AUTO_COOLDOWN_MS - (now - A.lastChangeAt)) / 1000)} s) — prevents rapid switching.`;
      return;
    }
    if (!poor) {
      A.state = 'ok';
      A.note = `Performance OK: ${avg.toFixed(0)} FPS average over ${AUTO_WINDOW} s (target ${tgt}). No change needed.`;
      return;
    }
    const level = presetLevel(this.cfg.preset || 'quality');
    if (level === 0 || A.ineffective >= 2) {
      A.state = 'exhausted';
      A.note =
        level === 0
          ? `Still below target (${avg.toFixed(0)} FPS) on the lightest preset. The remaining bottleneck is not a supported setting — check Environment below (GPU acceleration, Energy Saver, other tabs).`
          : `Lowering settings did not measurably raise FPS twice in a row, so auto optimization stopped changing things. The bottleneck is likely CPU / main-thread or system related.`;
      return;
    }
    const nextId = PRESET_ORDER[level - 1];
    const full = summarize(this.monitor.window(AUTO_WINDOW), this.monitor.refreshHz);
    const reason =
      below >= AUTO_BELOW_NEEDED
        ? `${below} of the last ${AUTO_WINDOW} s were below ${Math.round(tgt * 0.9)} FPS (90% of target ${tgt}); average ${avg.toFixed(0)} FPS.`
        : `${stutters} stutters in the last ${AUTO_WINDOW} s.`;
    const from = this.cfg.preset || 'quality';
    const res = this.applyPreset(nextId, { source: 'auto' });
    const id = Date.now();
    const entry = {
      id,
      at: id,
      from,
      to: nextId,
      reason,
      changes: res.changes.filter((c) => c.status !== 'missing').map((c) => describeChange(c)),
      recommended: res.pending.map((p) => `${settingLabel(p.id)} → ${fmtBool(p.value)} (reloads the page — apply manually between matches)`),
      before: { avg, low1: full ? full.low1Fps : null },
      after: null,
      effect: 'Measuring…',
    };
    const log = [...this.state.data.loc.perf.autoLog, entry].slice(-20);
    this.state.set('loc.perf.autoLog', log);
    A.pending = { id, at: now, atPerf: performance.now() };
    A.lastChangeAt = now;
    A.state = 'applied';
    A.note = `Switched to ${PRESETS[nextId].label}. ${reason}`;
  }
}

function fmtBool(v) {
  return v == null ? '—' : v ? 'on' : 'off';
}
function presetName(id) {
  return PRESETS[id] ? PRESETS[id].label : 'custom';
}
export function describeChange(c) {
  const v = typeof c.to === 'boolean' ? (c.to ? 'on' : 'off') : c.to;
  const tag = { applied: '', 'next-match': ' (next match)', 'needs-reload': ' (needs reload)', missing: ' (not on this page)', disabled: ' (control disabled)', failed: ' (failed)' }[c.status] || '';
  return `${c.label} → ${v}${tag}`;
}
