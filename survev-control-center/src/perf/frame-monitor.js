// Real frame-time monitor.
//
// Measures the cadence at which the browser actually produces frames for this page (requestAnimationFrame
// timestamps are vsync-aligned frame start times). When the game's rendering or the main thread falls behind,
// these intervals grow — so this reflects real rendered smoothness, not a counter the page reports.
// Long Animation Frames (Chrome 123+) / Long Tasks add attribution for janky frames.
//
// Cost per frame: one subtraction and two typed-array writes. Heavier statistics are computed on demand.

import { snapRefresh, stutterThreshold } from './stats.js';

const CAP = 8192;

export class FrameMonitor {
  constructor() {
    this.ft = new Float32Array(CAP);
    this.ts = new Float64Array(CAP);
    this.head = 0;
    this.count = 0;
    this.running = false;
    this.last = 0;
    this.skipNext = true;
    this.frameFns = new Set();
    this.tickFns = new Set();
    this.lastTick = 0;
    this.median = 16.7;
    this.refreshHz = null;
    this.bestP10 = Infinity;
    this.sessionFrames = 0;
    this.sessionStutters = 0;
    this.seconds = [];
    this.cur = null;
    this.drops = [];
    this.longFrames = [];
    this.observer = null;
    this.loafSupported = false;
    this._frame = this._frame.bind(this);
    this._vis = () => {
      this.skipNext = true;
      this.cur = null;
    };
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.skipNext = true;
    document.addEventListener('visibilitychange', this._vis);
    this._observe();
    this.raf = requestAnimationFrame(this._frame);
  }

  stop() {
    if (!this.running) return;
    this.running = false;
    cancelAnimationFrame(this.raf);
    document.removeEventListener('visibilitychange', this._vis);
    if (this.observer) this.observer.disconnect();
    this.observer = null;
  }

  reset() {
    this.head = 0;
    this.count = 0;
    this.seconds = [];
    this.cur = null;
    this.drops = [];
    this.longFrames = [];
    this.sessionFrames = 0;
    this.sessionStutters = 0;
    this.bestP10 = Infinity;
    this.refreshHz = null;
    this.skipNext = true;
  }

  onFrame(fn) {
    this.frameFns.add(fn);
    return () => this.frameFns.delete(fn);
  }

  onTick(fn) {
    this.tickFns.add(fn);
    return () => this.tickFns.delete(fn);
  }

  _observe() {
    const types = (globalThis.PerformanceObserver && PerformanceObserver.supportedEntryTypes) || [];
    const type = types.includes('long-animation-frame') ? 'long-animation-frame' : types.includes('longtask') ? 'longtask' : null;
    this.loafSupported = type === 'long-animation-frame';
    if (!type) return;
    try {
      this.observer = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          let ext = false;
          if (e.scripts) for (const s of e.scripts) if (String(s.sourceURL || '').startsWith('chrome-extension://')) ext = true;
          this.longFrames.push({ t: e.startTime + e.duration, dur: e.duration, block: e.blockingDuration || Math.max(0, e.duration - 50), ext });
        }
        if (this.longFrames.length > 400) this.longFrames.splice(0, this.longFrames.length - 400);
      });
      this.observer.observe({ type, buffered: false });
    } catch (_) {
      this.observer = null;
    }
  }

  _frame(ts) {
    if (!this.running) return;
    this.raf = requestAnimationFrame(this._frame);
    if (this.skipNext || document.hidden) {
      this.skipNext = document.hidden;
      this.last = ts;
      return;
    }
    const d = ts - this.last;
    this.last = ts;
    if (d <= 0 || d > 1000) return; // tab switch / resume gap, not a rendered frame interval
    this.ft[this.head] = d;
    this.ts[this.head] = ts;
    this.head = (this.head + 1) % CAP;
    if (this.count < CAP) this.count++;
    this.sessionFrames++;
    const stutter = d > stutterThreshold(this.median);
    if (stutter) this.sessionStutters++;
    this._second(ts, d, stutter);
    for (const fn of this.frameFns) fn(d, ts, stutter);
    if (ts - this.lastTick >= 250) {
      this.lastTick = ts;
      this._calibrate(ts);
      for (const fn of this.tickFns) fn(ts);
    }
  }

  _second(ts, d, stutter) {
    const sec = Math.floor(ts / 1000);
    if (!this.cur || this.cur.sec !== sec) {
      if (this.cur && this.cur.frames > 0) {
        const done = { sec: this.cur.sec, fps: (this.cur.frames * 1000) / this.cur.sum, frames: this.cur.frames, stutters: this.cur.stutters, worst: this.cur.worst };
        this.seconds.push(done);
        if (this.seconds.length > 180) this.seconds.shift();
        this._detectDrop(done);
      }
      this.cur = { sec, frames: 0, sum: 0, stutters: 0, worst: 0 };
    }
    this.cur.frames++;
    this.cur.sum += d;
    if (stutter) this.cur.stutters++;
    if (d > this.cur.worst) this.cur.worst = d;
  }

  _detectDrop(done) {
    const prev = this.seconds.slice(-11, -1);
    if (prev.length < 5) return;
    const base = prev.reduce((s, b) => s + b.fps, 0) / prev.length;
    if (base >= 20 && done.fps < base * 0.6) {
      this.drops.push({ at: Date.now(), from: base, to: done.fps });
      if (this.drops.length > 30) this.drops.shift();
    }
  }

  /** Frame times (ms, chronological) recorded in the last `sec` seconds. */
  window(sec) {
    const now = this.count ? this.ts[(this.head - 1 + CAP) % CAP] : 0;
    const from = now - sec * 1000;
    let n = 0;
    for (let i = 1; i <= this.count; i++) {
      if (this.ts[(this.head - i + CAP) % CAP] < from) break;
      n++;
    }
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = this.ft[(this.head - n + i + CAP) % CAP];
    return out;
  }

  /** FPS over the last ~0.5 s. */
  currentFps() {
    const w = this.window(0.5);
    if (w.length < 2) return null;
    let s = 0;
    for (let i = 0; i < w.length; i++) s += w[i];
    return (w.length * 1000) / s;
  }

  _calibrate() {
    const w = this.window(2);
    if (w.length < 20) return;
    const s = Float64Array.from(w).sort();
    this.median = s[Math.floor(s.length / 2)];
    const p10 = s[Math.floor(s.length * 0.1)];
    // The fastest sustained cadence seen approximates the display refresh / browser frame cap.
    // (Only ever tightened, so lag spikes can't make the display look slower than it is.)
    if (p10 >= 2) this.bestP10 = Math.min(this.bestP10, p10);
    if (Number.isFinite(this.bestP10)) this.refreshHz = snapRefresh(1000 / this.bestP10);
  }

  longFramesSince(msAgo) {
    const from = performance.now() - msAgo;
    let n = 0;
    let block = 0;
    let ext = 0;
    for (let i = this.longFrames.length - 1; i >= 0; i--) {
      const f = this.longFrames[i];
      if (f.t < from) break;
      n++;
      block += f.block;
      if (f.ext) ext++;
    }
    return { count: n, blockingMs: block, extension: ext };
  }
}
