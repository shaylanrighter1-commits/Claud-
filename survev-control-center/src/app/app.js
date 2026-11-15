// Application controller: owns the frame loop and wires source -> analysis -> renderer.
// Used by both the Demo Arena page and the in-page overlay (content script).

import { AimEngine } from '../engine/aiming.js';
import { computeVisibility } from '../engine/visibility.js';
import { AimDiagnostics } from '../engine/diagnostics.js';
import { Renderer } from '../render/renderer.js';
import { Recorder, ReplaySource } from '../sim/replay.js';
import { Bus, downloadJson, pickJsonFile, stamp, toggleDashboard } from '../core/util.js';
import { matchCombo, isTypingTarget } from '../core/keys.js';
import { WEAPONS } from '../core/defaults.js';
import { lerp } from '../core/math.js';

export class App {
  /**
   * @param o.state   State
   * @param o.canvas  overlay/world canvas (CSS-sized by the host page)
   * @param o.mode    'demo' (draws its own world, interactive) | 'overlay' (draws on top of a host page)
   * @param o.source  snapshot source ({ update(dt,input), interactive, label, kind })
   */
  constructor({ state, canvas, mode, source }) {
    this.state = state;
    this.canvas = canvas;
    this.mode = mode;
    this.source = source;
    this.replay = null;
    this.bus = new Bus();
    this.renderer = new Renderer(canvas);
    this.aimEngine = new AimEngine();
    this.diag = new AimDiagnostics();
    this.recorder = new Recorder();
    this.paused = false;
    this.running = false;
    this.fps = 60;
    this.last = 0;
    this.lastSnap = null;
    this.lastSeq = -1;
    this.vis = null;
    this.aim = null;
    this.errors = 0;
    this.costMs = 0;
    this.canvasHidden = false;
    this.emitAt = 0;
    this.keys = new Set();
    this.mouse = { x: 0, y: 0, has: false, down: false };
    this.lockHeld = false;
    this.lockToggled = false;
    this.listeners = [];
    this._frame = this._frame.bind(this);
    this._bindInput();
  }

  // ------------------------------------------------------------------ lifecycle
  start() {
    if (this.running) return;
    this.running = true;
    this.last = performance.now();
    this.raf = requestAnimationFrame(this._frame);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  destroy() {
    this.stop();
    for (const [t, ev, fn, opt] of this.listeners) t.removeEventListener(ev, fn, opt);
    this.listeners = [];
    this.renderer.clear();
    this.recorder.clear();
    this.bus.clear();
  }

  _on(target, ev, fn, opt) {
    target.addEventListener(ev, fn, opt);
    this.listeners.push([target, ev, fn, opt]);
  }

  // ------------------------------------------------------------------ input
  _bindInput() {
    const ui = (e) => e.target && e.target.closest && e.target.closest('[data-scc-ui]');
    this._on(window, 'keydown', (e) => {
      if (isTypingTarget(e.target) || e.defaultPrevented) return;
      const sc = this.state.data.cfg.shortcuts;
      if (matchCombo(e, sc.master)) return this._shortcut(e, () => this.state.toggle('loc.master'));
      if (matchCombo(e, sc.dashboard)) return this._shortcut(e, () => toggleDashboard(this.state));
      if (matchCombo(e, sc.pause)) return this._shortcut(e, () => this.togglePause());
      if (matchCombo(e, sc.record)) return this._shortcut(e, () => this.toggleRecording());
      const lk = this.state.data.cfg.aiming.lockKey;
      if (e.code === lk) {
        if (this.state.data.cfg.aiming.lockMode === 'toggle') {
          if (!e.repeat) this.lockToggled = !this.lockToggled;
        } else this.lockHeld = true;
      }
      if (this.mode === 'demo' && !e.metaKey && !e.ctrlKey) {
        this.keys.add(e.code);
        if (/^(KeyW|KeyA|KeyS|KeyD|ArrowUp|ArrowDown|ArrowLeft|ArrowRight|Space)$/.test(e.code)) e.preventDefault();
      }
    }, true);
    this._on(window, 'keyup', (e) => {
      if (e.code === this.state.data.cfg.aiming.lockKey && this.state.data.cfg.aiming.lockMode === 'hold') this.lockHeld = false;
      this.keys.delete(e.code);
    }, true);
    this._on(window, 'blur', () => {
      this.keys.clear();
      this.lockHeld = false;
      this.mouse.down = false;
    });
    this._on(window, 'mousemove', (e) => {
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.mouse.has = true;
    }, { passive: true });
    this._on(document.documentElement, 'mouseleave', () => (this.mouse.has = false));
    if (this.mode === 'demo') {
      this._on(window, 'mousedown', (e) => {
        if (e.button === 0 && !ui(e)) this.mouse.down = true;
      });
      this._on(window, 'mouseup', (e) => {
        if (e.button === 0) this.mouse.down = false;
      });
      this._on(this.canvas, 'wheel', (e) => {
        e.preventDefault();
        if (this.source.setZoom) this.source.setZoom(this.source.zoom * (e.deltaY < 0 ? 1.08 : 1 / 1.08));
      }, { passive: false });
    }
  }

  _shortcut(e, fn) {
    e.preventDefault();
    e.stopPropagation();
    fn();
  }

  // ------------------------------------------------------------------ transport / replay
  togglePause() {
    if (this.replay) this.replay.playing = !this.replay.playing;
    else if (this.source.interactive) this.paused = !this.paused;
    this._status();
  }

  toggleRecording() {
    if (this.recorder.recording) this.stopRecording();
    else this.startRecording();
  }

  startRecording() {
    if (this.replay) return;
    this.recorder.start();
    this._status();
  }

  stopRecording() {
    this.recorder.stop();
    this._status();
  }

  enterReplay() {
    if (this.recorder.frames.length < 2) return false;
    this.recorder.stop();
    this.replay = new ReplaySource(this.recorder.frames, this.recorder.maps);
    this._resetAnalysis();
    this._status();
    return true;
  }

  exitReplay() {
    this.replay = null;
    this._resetAnalysis();
    this._status();
  }

  seek(fraction) {
    if (this.replay) this.replay.seek(fraction);
  }

  exportReplay() {
    if (this.recorder.frames.length < 2) return false;
    downloadJson(`scc-replay-${stamp()}.json`, this.recorder.serialize());
    return true;
  }

  async importReplay() {
    const data = await pickJsonFile();
    if (!data) return false;
    this.recorder.load(data);
    return this.enterReplay();
  }

  resetDiagnostics() {
    this.diag.reset();
    this.aimEngine.reset();
  }

  _resetAnalysis() {
    this.diag.reset();
    this.aimEngine.reset();
    this.lastSeq = -1;
    this.renderer.fx.length = 0;
  }

  getStatus() {
    const r = this.replay;
    return {
      mode: r ? 'replay' : this.source.kind,
      label: r ? 'Replay' : this.source.label,
      paused: this.paused,
      fps: this.fps,
      recording: this.recorder.recording,
      frames: this.recorder.frames.length,
      duration: this.recorder.duration,
      replay: r ? { playing: r.playing, fraction: r.fraction, duration: r.duration, loop: r.loop } : null,
    };
  }

  _status() {
    this.bus.emit('status', this.getStatus());
  }

  // ------------------------------------------------------------------ frame loop
  _frame(ts) {
    if (!this.running) return;
    this.raf = requestAnimationFrame(this._frame);
    const dt = Math.min(0.05, Math.max(0.001, (ts - this.last) / 1000));
    this.last = ts;
    this.fps = lerp(this.fps, 1 / dt, 0.08);
    try {
      const t0 = performance.now();
      this._tick(dt, ts / 1000);
      this.costMs = this.costMs * 0.95 + (performance.now() - t0) * 0.05;
    } catch (e) {
      if (++this.errors <= 5) console.error('[SCC] frame error', e);
      if (this.errors > 50) {
        console.error('[SCC] too many frame errors, stopping loop');
        this.stop();
      }
    }
  }

  /** In overlay mode an idle full-screen canvas still costs compositing every frame, so hide it. */
  _setCanvasVisible(on) {
    if (this.mode !== 'overlay' || this.canvasHidden === !on) return;
    this.canvasHidden = !on;
    if (!on) this.renderer.clear();
    this.canvas.style.display = on ? '' : 'none';
  }

  _viewOf(snap) {
    const v = snap && snap.camera && snap.camera.view;
    return v || { left: 0, top: 0, width: this.canvas.clientWidth, height: this.canvas.clientHeight };
  }

  _cursorWorld(snap) {
    if (this.replay && snap.self.cursor) return snap.self.cursor;
    if (this.mouse.has) {
      const v = this._viewOf(snap);
      const c = snap.camera;
      return { x: (this.mouse.x - v.left - v.width / 2) / c.scale + c.x, y: (this.mouse.y - v.top - v.height / 2) / c.scale + c.y };
    }
    if (snap.self.cursor) return snap.self.cursor;
    const a = snap.self.angle || 0;
    return { x: snap.self.x + Math.cos(a) * 200, y: snap.self.y + Math.sin(a) * 200 };
  }

  _lockActive(cfg) {
    return this.state.data.loc.master && cfg.aiming.enabled && (cfg.aiming.lockMode === 'toggle' ? this.lockToggled : this.lockHeld);
  }

  _tick(dt, now) {
    const { cfg, loc } = this.state.data;
    const master = loc.master;
    let snap = null;
    let aim = null;
    let vis = this.vis;
    const interactive = !this.replay && this.source.interactive;

    if (this.replay) {
      snap = this.replay.update(dt);
    } else if (interactive) {
      if (this.paused && this.lastSnap) snap = this.lastSnap;
      else {
        const prev = this.lastSnap;
        const weapon = WEAPONS[cfg.aiming.weapon] || WEAPONS.rifle;
        const input = {
          moveX: (this.keys.has('KeyD') || this.keys.has('ArrowRight') ? 1 : 0) - (this.keys.has('KeyA') || this.keys.has('ArrowLeft') ? 1 : 0),
          moveY: (this.keys.has('KeyS') || this.keys.has('ArrowDown') ? 1 : 0) - (this.keys.has('KeyW') || this.keys.has('ArrowUp') ? 1 : 0),
          angle: prev ? prev.self.angle : 0,
          fire: this.mouse.down || this.keys.has('Space'),
          weapon,
          cursor: null,
        };
        if (prev) {
          const cursor = this._cursorWorld(prev);
          input.cursor = cursor;
          const lock = this._lockActive(cfg);
          const a = this.aimEngine.update(prev, cfg, cursor, lock, dt, true, vis || { los: new Map() });
          input.angle = a.appliedAngle;
          if (cfg.aiming.autoFire && a.locked && a.hitProb != null && a.hitProb > 0.25) input.fire = true;
        }
        snap = this.source.update(dt, input);
      }
    } else {
      snap = this.source.update(dt);
    }

    if (!snap || (this.mode === 'overlay' && !master)) {
      this.lastSnap = snap || null;
      this._setCanvasVisible(false);
      return;
    }
    this._setCanvasVisible(true);
    this.lastSnap = snap;

    // visibility (LOS flags are always needed; polygon/contacts only when drawn)
    const v = cfg.visibility;
    const drawVis = master && v.enabled;
    vis = computeVisibility(snap, cfg, { polygon: drawVis && v.los.showCone, contacts: drawVis && v.collisions.contacts });
    this.vis = vis;

    // aim analysis (read-only for replay / dev, already computed for the interactive demo but re-run on the new snapshot for drawing)
    const cursor = this._cursorWorld(snap);
    aim = this.aimEngine.update(snap, cfg, cursor, this._lockActive(cfg), dt, false, vis);
    if (interactive) {
      // keep the interactive "applied" angle (what the simulated shooter actually used) for drawing
      aim.appliedAngle = snap.self.angle;
      aim.traj && (aim.traj.angle = snap.self.angle);
    }
    this.aim = aim;

    const fresh = snap.seq !== this.lastSeq;
    if (fresh) {
      this.lastSeq = snap.seq;
      if (snap.events.length) this.renderer.addEvents(snap.events, now);
    }
    const idle = (this.paused && !this.replay) || (this.replay && !this.replay.playing);
    if (!idle) {
      this.diag.ingest(snap, aim, fresh);
      this.recorder.capture(snap);
    }

    const cursorScreen = this.mouse.has ? { x: this.mouse.x, y: this.mouse.y } : null;
    this.renderer.render({
      snap, cfg, master, mode: this.mode, aim, vis, cursor: cursorScreen, now, fps: this.fps,
      label: this.replay ? 'REPLAY' : this.source.kind === 'demo' ? 'DEMO' : 'DEV LIVE',
    });

    if (now - this.emitAt > 0.1) {
      this.emitAt = now;
      this.bus.emit('diag', this._payload(snap, vis));
      if (this.replay || this.recorder.recording) this._status();
    }
  }

  _payload(snap, vis) {
    const upm = snap.meta.unitsPerMeter || 1;
    const rows = [];
    let visible = 0;
    let occluded = 0;
    for (const p of snap.players) {
      const l = vis.los.get(p.id);
      if (!l) continue;
      if (l.visible) visible++;
      else occluded++;
      rows.push({ name: p.name, dist: l.dist / upm, fraction: l.fraction, visible: l.visible, occluder: l.occluder, thickness: l.thickness / upm });
    }
    rows.sort((a, b) => a.dist - b.dist);
    return {
      ...this.diag.stats(),
      series: this.diag.getSeries(),
      vis: rows.slice(0, 8),
      counts: { players: snap.players.length, visible, occluded, loot: snap.loot.length, bullets: snap.bullets.length, obstacles: snap.obstacles.length, contacts: vis.contacts.length },
      aimActive: !!(this.aim && this.aim.active),
      source: snap.meta.source,
    };
  }
}

