// Canvas renderer: composes the base world (demo only) and the debug layers.

import { drawWorld } from './layers/world.js';
import { drawVisibilityUnder, drawSilhouettes } from './layers/visibility.js';
import { drawEntities } from './layers/entities.js';
import { drawAiming } from './layers/aiming.js';
import { chip } from './draw.js';

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: true });
    this.dpr = 1;
    this.cssW = 0;
    this.cssH = 0;
    this.fx = [];
    this.rc = {
      ctx: this.ctx,
      fx: this.fx,
      sx: null,
      sy: null,
    };
    this.rc.sx = (x) => (x - this.rc.cam.x) * this.rc.scale + this.rc.w / 2;
    this.rc.sy = (y) => (y - this.rc.cam.y) * this.rc.scale + this.rc.h / 2;
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(this.canvas.clientWidth));
    const h = Math.max(1, Math.round(this.canvas.clientHeight));
    if (w === this.cssW && h === this.cssH && dpr === this.dpr) return;
    this.dpr = dpr;
    this.cssW = w;
    this.cssH = h;
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
  }

  clear() {
    this.ctx.setTransform(1, 0, 0, 1, 0, 0);
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
  }

  /** Register one-shot events (impacts, hits) for the effects layer. */
  addEvents(events, now) {
    for (const e of events) {
      if (e.type === 'hit') this.fx.push({ x: e.x, y: e.y, born: now, kind: 'player' });
      else if (e.type === 'impact') this.fx.push({ x: e.x, y: e.y, born: now, kind: 'obstacle' });
      else if (e.type === 'expire') this.fx.push({ x: e.x, y: e.y, born: now, kind: 'expire' });
    }
    if (this.fx.length > 80) this.fx.splice(0, this.fx.length - 80);
  }

  /**
   * @param f {snap, cfg, master, mode, aim, vis, cursor, now, fps, label}
   */
  render(f) {
    this.resize();
    const { ctx, rc } = this;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, this.cssW, this.cssH);
    const snap = f.snap;
    const cam = snap.camera;
    const view = cam.view || { left: 0, top: 0, width: this.cssW, height: this.cssH };

    // drop expired fx
    for (let i = this.fx.length - 1; i >= 0; i--) if (f.now - this.fx[i].born > 1.5) this.fx.splice(i, 1);

    ctx.save();
    ctx.translate(view.left, view.top);
    ctx.beginPath();
    ctx.rect(0, 0, view.width, view.height);
    ctx.clip();

    rc.snap = snap;
    rc.cfg = f.cfg;
    rc.mode = f.mode;
    rc.aim = f.aim;
    rc.vis = f.vis;
    rc.now = f.now;
    rc.cam = cam;
    rc.scale = cam.scale || 1;
    rc.w = view.width;
    rc.h = view.height;
    rc.maxDist = f.cfg.entities.maxDistance * (snap.meta.unitsPerMeter || 1);
    rc.cursor = f.cursor ? { x: f.cursor.x - view.left, y: f.cursor.y - view.top } : null;

    if (f.mode === 'demo') drawWorld(rc);
    if (f.master) {
      if (f.cfg.visibility.enabled) drawVisibilityUnder(rc);
      if (f.cfg.visibility.enabled) drawSilhouettes(rc);
      if (f.cfg.entities.enabled) drawEntities(rc);
      drawAiming(rc);
    }
    if (f.cfg.hud.show) {
      const n = snap.players.length;
      const txt = `${f.label}  ·  ${Math.round(f.fps)} fps  ·  ${n} players  ·  ${f.master ? 'ACTIVE' : 'MASTER OFF'}`;
      chip(ctx, txt, 12, view.height - 16, { align: 'left', size: 10, mono: true, fg: f.master ? '#c7d2ea' : '#ff8a96', bg: 'rgba(8,9,12,0.7)', border: 'rgba(255,255,255,0.07)' });
    }
    ctx.restore();
  }
}
