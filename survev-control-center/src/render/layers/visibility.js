// Visibility-debug layers: LOS polygon/rays, occlusion diagnostics, collision debugging, silhouettes.

import { hexA, chip, bodyPath } from '../draw.js';
import { TEAM_PALETTE } from '../../core/defaults.js';
import { relationOf } from '../../core/util.js';

const FLAG_COLORS = { move: '#4f8cff', bullets: '#ff9f43', sight: '#34d399' };

function entityColor(rc, p) {
  const t = rc.cfg.entities.teams;
  if (!t.enabled) return rc.cfg.theme.accent;
  if (t.mode === 'team') return TEAM_PALETTE[Math.abs(Number(p.team) || 0) % TEAM_PALETTE.length];
  return t.colors[relationOf(p, rc.snap.self)];
}

/** Drawn beneath entities. */
export function drawVisibilityUnder(rc) {
  const { ctx, snap, cfg, scale, vis, now } = rc;
  const v = cfg.visibility;
  const self = snap.self;
  const accent = cfg.theme.accent;
  const sxSelf = rc.sx(self.x);
  const sySelf = rc.sy(self.y);
  ctx.save();

  // obstacle ghosts (useful when the host page draws the world itself)
  if (rc.mode === 'overlay' && v.obstacleGhost) {
    ctx.lineWidth = 1;
    for (const o of snap.obstacles) {
      ctx.fillStyle = hexA('#8fa3c7', 0.1 * (v.wallAlpha / 100));
      ctx.strokeStyle = hexA('#8fa3c7', 0.35 * (v.wallAlpha / 100));
      if (o.type === 'circle') {
        ctx.beginPath();
        ctx.arc(rc.sx(o.x), rc.sy(o.y), o.r * scale, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
      } else {
        ctx.fillRect(rc.sx(o.x), rc.sy(o.y), o.w * scale, o.h * scale);
        ctx.strokeRect(rc.sx(o.x) + 0.5, rc.sy(o.y) + 0.5, o.w * scale, o.h * scale);
      }
    }
  }

  // visibility polygon
  if (v.los.showCone && vis.polygon && vis.polygon.length >= 6) {
    const pts = vis.polygon;
    ctx.beginPath();
    ctx.moveTo(rc.sx(pts[0]), rc.sy(pts[1]));
    for (let i = 2; i < pts.length; i += 2) ctx.lineTo(rc.sx(pts[i]), rc.sy(pts[i + 1]));
    ctx.closePath();
    ctx.fillStyle = hexA(accent, v.los.fillOpacity / 100);
    ctx.fill();
    ctx.lineWidth = 1.25;
    ctx.strokeStyle = hexA(accent, 0.35);
    ctx.stroke();
  }

  // collision debug: obstacle hitboxes coloured by what they block
  const c = v.collisions;
  if (c.hitboxes) {
    ctx.lineWidth = 1;
    for (const o of snap.obstacles) {
      const col = o.bullets && o.move && o.sight ? '#e9ecf2' : o.move ? FLAG_COLORS.move : o.bullets ? FLAG_COLORS.bullets : FLAG_COLORS.sight;
      ctx.strokeStyle = hexA(col, 0.8);
      ctx.setLineDash(o.sight ? [] : [4, 3]);
      if (o.type === 'circle') {
        ctx.beginPath();
        ctx.arc(rc.sx(o.x), rc.sy(o.y), o.r * scale, 0, Math.PI * 2);
        ctx.stroke();
      } else ctx.strokeRect(rc.sx(o.x) + 0.5, rc.sy(o.y) + 0.5, o.w * scale, o.h * scale);
    }
    ctx.setLineDash([]);
  }
  if (c.players) {
    ctx.lineWidth = 1;
    ctx.strokeStyle = 'rgba(255,255,255,0.55)';
    for (const p of [self, ...snap.players]) {
      ctx.beginPath();
      ctx.arc(rc.sx(p.x), rc.sy(p.y), p.r * scale, 0, Math.PI * 2);
      ctx.stroke();
    }
  }
  if (c.contacts) {
    for (const k of vis.contacts) {
      const sx = rc.sx(k.x);
      const sy = rc.sy(k.y);
      ctx.strokeStyle = k.pen > 0.5 ? '#ff4d5e' : '#fbbf24';
      ctx.fillStyle = ctx.strokeStyle;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(sx, sy);
      ctx.lineTo(sx + k.nx * 16, sy + k.ny * 16);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(sx, sy, 2.5, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  if (c.impacts) {
    for (const f of rc.fx) {
      const age = now - f.born;
      const life = 1.4;
      if (age > life) continue;
      const a = 1 - age / life;
      const col = f.kind === 'player' ? '#ff4d5e' : f.kind === 'expire' ? '#8b91a0' : '#ff9f43';
      const sx = rc.sx(f.x);
      const sy = rc.sy(f.y);
      ctx.strokeStyle = hexA(col, a);
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(sx, sy, 3 + age * 14, 0, Math.PI * 2);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(sx - 4, sy - 4);
      ctx.lineTo(sx + 4, sy + 4);
      ctx.moveTo(sx + 4, sy - 4);
      ctx.lineTo(sx - 4, sy + 4);
      ctx.stroke();
    }
  }

  // occlusion: highlight occluders + rays
  const occ = v.occlusion;
  const range = vis.range;
  if (occ.show || v.los.showRays) {
    for (const p of snap.players) {
      const l = vis.los.get(p.id);
      if (!l) continue;
      const d = l.dist;
      if (d > rc.maxDist) continue;
      const px = rc.sx(p.x);
      const py = rc.sy(p.y);
      if (v.los.showRays && d <= Math.max(range, 1) * 1.6) {
        ctx.lineWidth = 1;
        if (l.visible) {
          ctx.strokeStyle = hexA('#34d399', l.fraction >= 1 ? 0.5 : 0.35);
          ctx.setLineDash(l.fraction >= 1 ? [] : [5, 3]);
          ctx.beginPath();
          ctx.moveTo(sxSelf, sySelf);
          ctx.lineTo(px, py);
          ctx.stroke();
        } else {
          const hx = rc.sx(l.hx);
          const hy = rc.sy(l.hy);
          ctx.strokeStyle = hexA('#ff4d5e', 0.55);
          ctx.setLineDash([]);
          ctx.beginPath();
          ctx.moveTo(sxSelf, sySelf);
          ctx.lineTo(hx, hy);
          ctx.stroke();
          ctx.strokeStyle = hexA('#8b91a0', 0.35);
          ctx.setLineDash([3, 4]);
          ctx.beginPath();
          ctx.moveTo(hx, hy);
          ctx.lineTo(px, py);
          ctx.stroke();
        }
        ctx.setLineDash([]);
      }
      if (occ.show && !l.visible) {
        if (occ.blockerPoints) {
          const hx = rc.sx(l.hx);
          const hy = rc.sy(l.hy);
          ctx.strokeStyle = '#ff4d5e';
          ctx.lineWidth = 2;
          ctx.beginPath();
          ctx.moveTo(hx - 4, hy - 4);
          ctx.lineTo(hx + 4, hy + 4);
          ctx.moveTo(hx + 4, hy - 4);
          ctx.lineTo(hx - 4, hy + 4);
          ctx.stroke();
          if (occ.labels) {
            const upm = snap.meta.unitsPerMeter || 1;
            chip(ctx, `${(l.thickness / upm).toFixed(1)} m solid`, hx, hy - 14, { size: 9, mono: true, fg: '#ffb3ba', border: 'rgba(255,77,94,0.5)' });
          }
        }
      }
    }
    if (occ.show && occ.highlight && vis.occluders.size) {
      ctx.lineWidth = 2;
      ctx.strokeStyle = hexA('#ff4d5e', 0.7);
      for (const o of snap.obstacles) {
        if (!vis.occluders.has(o.id)) continue;
        if (o.type === 'circle') {
          ctx.beginPath();
          ctx.arc(rc.sx(o.x), rc.sy(o.y), o.r * scale + 2, 0, Math.PI * 2);
          ctx.stroke();
        } else ctx.strokeRect(rc.sx(o.x) - 1, rc.sy(o.y) - 1, o.w * scale + 2, o.h * scale + 2);
      }
    }
  }
  ctx.restore();
}

/** Silhouettes of hidden (and optionally visible) characters. */
export function drawSilhouettes(rc) {
  const { ctx, snap, cfg, scale, vis } = rc;
  const s = cfg.visibility.silhouettes;
  if (!s.show) return;
  const alpha = s.alpha / 100;
  ctx.save();
  ctx.lineJoin = 'round';
  let glowBudget = 24;
  for (const p of snap.players) {
    const l = vis.los.get(p.id);
    const hidden = l && !l.visible;
    if (!hidden && !s.outlineVisible) continue;
    if (l && l.dist > rc.maxDist) continue;
    const sx = rc.sx(p.x);
    const sy = rc.sy(p.y);
    const r = p.r * scale * 1.04;
    if (sx < -60 || sy < -60 || sx > rc.w + 60 || sy > rc.h + 60) continue;
    const col = s.colorMode === 'team' ? entityColor(rc, p) : s.color;
    bodyPath(ctx, sx, sy, r, p.angle || 0);
    if (hidden) {
      ctx.fillStyle = hexA(col, alpha);
      if (s.glow > 0 && glowBudget-- > 0) {
        ctx.shadowColor = hexA(col, 0.9);
        ctx.shadowBlur = s.glow;
      }
      ctx.fill();
      ctx.shadowBlur = 0;
    }
    if (s.outline > 0) {
      ctx.lineWidth = s.outline;
      ctx.strokeStyle = hexA(col, hidden ? Math.min(1, alpha + 0.4) : 0.9);
      if (s.glow > 0 && glowBudget-- > 0) {
        ctx.shadowColor = hexA(col, 0.8);
        ctx.shadowBlur = s.glow * 0.7;
      }
      ctx.stroke();
      ctx.shadowBlur = 0;
    }
  }
  ctx.restore();
}

