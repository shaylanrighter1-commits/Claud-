// Base "game view" for the demo arena: what a normal client would show, with fog-of-war for
// players hidden behind sight-blocking geometry. Debug layers draw on top of this.

import { hexA, bodyPath } from '../draw.js';
import { TEAM_PALETTE } from '../../core/defaults.js';
import { relationOf } from '../../core/util.js';

const KIND_STYLE = {
  wall: { fill: '#262a32', edge: '#3a404c' },
  crate: { fill: '#4a3c27', edge: '#6a573a' },
  barrel: { fill: '#573428', edge: '#7a4a38' },
  rock: { fill: '#2e3138', edge: '#454a55' },
  tree: { fill: '#1b4332', edge: '#2d6a4f' },
  bush: { fill: '#1f5a3d', edge: '#2f7d55' },
  glass: { fill: '#5aa8ff', edge: '#8cc4ff' },
};

export function drawWorld(rc) {
  const { ctx, snap, cfg, w, h, scale, cam } = rc;
  // background
  ctx.fillStyle = '#0c0e11';
  ctx.fillRect(0, 0, w, h);

  // world bounds + grid
  const x0 = rc.sx(0);
  const y0 = rc.sy(0);
  const x1 = rc.sx(snap.world.w);
  const y1 = rc.sy(snap.world.h);
  ctx.fillStyle = '#111419';
  ctx.fillRect(x0, y0, x1 - x0, y1 - y0);
  ctx.lineWidth = 1;
  ctx.strokeStyle = 'rgba(255,255,255,0.035)';
  ctx.beginPath();
  const step = 100;
  const gx0 = Math.max(0, Math.floor((cam.x - w / 2 / scale) / step) * step);
  const gx1 = Math.min(snap.world.w, cam.x + w / 2 / scale);
  const gy0 = Math.max(0, Math.floor((cam.y - h / 2 / scale) / step) * step);
  const gy1 = Math.min(snap.world.h, cam.y + h / 2 / scale);
  for (let gx = gx0; gx <= gx1; gx += step) {
    const sx = Math.round(rc.sx(gx)) + 0.5;
    ctx.moveTo(sx, rc.sy(gy0));
    ctx.lineTo(sx, rc.sy(gy1));
  }
  for (let gy = gy0; gy <= gy1; gy += step) {
    const sy = Math.round(rc.sy(gy)) + 0.5;
    ctx.moveTo(rc.sx(gx0), sy);
    ctx.lineTo(rc.sx(gx1), sy);
  }
  ctx.stroke();
  ctx.lineWidth = 2;
  ctx.strokeStyle = 'rgba(255,255,255,0.08)';
  ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);

  // obstacles
  const vis = cfg.visibility;
  const alpha = vis.enabled ? vis.wallAlpha / 100 : 1;
  for (const o of snap.obstacles) {
    const st = KIND_STYLE[o.kind] || KIND_STYLE.wall;
    const a = o.kind === 'glass' ? 0.28 * (0.4 + alpha * 0.6) : o.kind === 'bush' ? 0.78 * alpha : alpha;
    if (o.type === 'circle') {
      const sx = rc.sx(o.x);
      const sy = rc.sy(o.y);
      const r = o.r * scale;
      if (sx + r < 0 || sy + r < 0 || sx - r > w || sy - r > h) continue;
      ctx.beginPath();
      ctx.arc(sx, sy, r, 0, Math.PI * 2);
      ctx.fillStyle = hexA(st.fill, a);
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = hexA(st.edge, a);
      ctx.stroke();
      if (o.kind === 'tree') {
        ctx.beginPath();
        ctx.arc(sx, sy, r * 0.45, 0, Math.PI * 2);
        ctx.fillStyle = hexA('#0f2a1f', a);
        ctx.fill();
      }
    } else {
      const sx = rc.sx(o.x);
      const sy = rc.sy(o.y);
      const ww = o.w * scale;
      const hh = o.h * scale;
      if (sx + ww < 0 || sy + hh < 0 || sx > w || sy > h) continue;
      ctx.fillStyle = hexA(st.fill, a);
      ctx.fillRect(sx, sy, ww, hh);
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = hexA(st.edge, a);
      ctx.strokeRect(sx + 0.5, sy + 0.5, ww - 1, hh - 1);
    }
    if (vis.enabled && vis.obstacleOutline) {
      ctx.lineWidth = 1;
      ctx.strokeStyle = hexA(vis.silhouettes.color, 0.55);
      if (o.type === 'circle') {
        ctx.beginPath();
        ctx.arc(rc.sx(o.x), rc.sy(o.y), o.r * scale + 2, 0, Math.PI * 2);
        ctx.stroke();
      } else ctx.strokeRect(rc.sx(o.x) - 2, rc.sy(o.y) - 2, o.w * scale + 4, o.h * scale + 4);
    }
  }

  // loot (plain game-style dots; markers are drawn by the entity layer)
  for (const l of snap.loot) {
    const sx = rc.sx(l.x);
    const sy = rc.sy(l.y);
    if (sx < -10 || sy < -10 || sx > w + 10 || sy > h + 10) continue;
    ctx.beginPath();
    ctx.arc(sx, sy, 4 * scale + 1, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255,255,255,0.55)';
    ctx.fill();
  }

  // players (regular view: hidden players are NOT drawn; the visibility layer reveals them for debugging)
  const self = snap.self;
  const drawPlayer = (p, isSelf) => {
    const sx = rc.sx(p.x);
    const sy = rc.sy(p.y);
    const r = p.r * scale;
    if (sx < -40 || sy < -40 || sx > w + 40 || sy > h + 40) return;
    const rel = isSelf ? 'self' : relationOf(p, self);
    const col = isSelf ? '#e8eefc' : rel === 'ally' ? '#58c79a' : TEAM_PALETTE[Math.abs(Number(p.team) || 0) % TEAM_PALETTE.length];
    bodyPath(ctx, sx, sy, r, p.angle || 0);
    ctx.fillStyle = '#1a1d23';
    ctx.fill();
    ctx.lineWidth = 2.2;
    ctx.strokeStyle = col;
    ctx.stroke();
  };
  for (const p of snap.players) {
    const l = rc.vis && rc.vis.los.get(p.id);
    if (l && !l.visible) continue;
    drawPlayer(p, false);
  }
  drawPlayer(self, true);

  // bullets
  ctx.lineCap = 'round';
  for (const b of snap.bullets) {
    const sx = rc.sx(b.x);
    const sy = rc.sy(b.y);
    if (sx < -20 || sy < -20 || sx > w + 20 || sy > h + 20) continue;
    const sp = Math.hypot(b.vx, b.vy) || 1;
    const len = 22 * scale;
    ctx.lineWidth = 2;
    ctx.strokeStyle = b.owner === self.id ? 'rgba(120,180,255,0.95)' : 'rgba(255,196,120,0.9)';
    ctx.beginPath();
    ctx.moveTo(sx, sy);
    ctx.lineTo(sx - (b.vx / sp) * len, sy - (b.vy / sp) * len);
    ctx.stroke();
  }
  ctx.lineCap = 'butt';
}
