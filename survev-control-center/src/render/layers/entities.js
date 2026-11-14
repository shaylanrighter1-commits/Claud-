// Entity visualization: bounding boxes, names, health, distance, weapons, team colours,
// loot markers, connector lines and off-screen indicators.

import { hexA, haloText, chip, healthColor, arrowHead, roundRectPath } from '../draw.js';
import { RARITY, TEAM_PALETTE } from '../../core/defaults.js';
import { relationOf } from '../../core/util.js';
import { TAU, clamp, lerp } from '../../core/math.js';

export function colorFor(cfg, p, self) {
  const t = cfg.entities.teams;
  if (!t.enabled) return cfg.theme.accent;
  if (t.mode === 'team') return TEAM_PALETTE[Math.abs(Number(p.team) || 0) % TEAM_PALETTE.length];
  return t.colors[relationOf(p, self)];
}

function drawBox(ctx, x, y, half, style, thick, color, dashed) {
  ctx.lineWidth = thick;
  ctx.strokeStyle = color;
  ctx.setLineDash(dashed ? [5, 4] : []);
  if (style === 'full' || style === 'filled') {
    if (style === 'filled') {
      ctx.fillStyle = color.replace(/[\d.]+\)$/, '0.12)');
      ctx.fillRect(x - half, y - half, half * 2, half * 2);
    }
    ctx.strokeRect(x - half, y - half, half * 2, half * 2);
  } else {
    const len = Math.max(5, half * 0.55);
    ctx.beginPath();
    for (const [sx, sy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
      const cx = x + sx * half;
      const cy = y + sy * half;
      ctx.moveTo(cx - sx * len, cy);
      ctx.lineTo(cx, cy);
      ctx.lineTo(cx, cy - sy * len);
    }
    ctx.stroke();
  }
  ctx.setLineDash([]);
}

function lootGlyph(ctx, kind, x, y, r) {
  ctx.beginPath();
  switch (kind) {
    case 'gun':
      ctx.rect(x - r * 0.7, y - r * 0.18, r * 1.4, r * 0.36);
      ctx.rect(x - r * 0.15, y, r * 0.3, r * 0.6);
      break;
    case 'ammo':
      for (let i = -1; i <= 1; i++) ctx.rect(x + i * r * 0.5 - r * 0.14, y - r * 0.45, r * 0.28, r * 0.9);
      break;
    case 'heal':
      ctx.rect(x - r * 0.15, y - r * 0.55, r * 0.3, r * 1.1);
      ctx.rect(x - r * 0.55, y - r * 0.15, r * 1.1, r * 0.3);
      break;
    case 'armor':
      ctx.moveTo(x - r * 0.5, y - r * 0.5);
      ctx.lineTo(x + r * 0.5, y - r * 0.5);
      ctx.lineTo(x + r * 0.5, y + r * 0.1);
      ctx.lineTo(x, y + r * 0.6);
      ctx.lineTo(x - r * 0.5, y + r * 0.1);
      ctx.closePath();
      break;
    case 'scope':
      ctx.arc(x, y, r * 0.5, 0, TAU);
      ctx.moveTo(x + r * 0.15, y);
      ctx.arc(x, y, r * 0.15, 0, TAU);
      break;
    default:
      ctx.arc(x, y, r * 0.35, 0, TAU);
  }
}

export function drawEntities(rc) {
  const { ctx, snap, cfg, scale, w, h, now, vis } = rc;
  const e = cfg.entities;
  const self = snap.self;
  const upm = snap.meta.unitsPerMeter || 1;
  const maxD = rc.maxDist;
  const op = e.teams.opacity / 100;
  const ls = e.labels.scale / 100;
  const sxSelf = rc.sx(self.x);
  const sySelf = rc.sy(self.y);
  const off = [];
  ctx.save();
  ctx.lineJoin = 'round';

  // ---- loot ---------------------------------------------------------------
  if (e.loot.show) {
    for (const l of snap.loot) {
      if (l.rarity < e.loot.minRarity) continue;
      const d = Math.hypot(l.x - self.x, l.y - self.y);
      if (d > maxD) continue;
      const sx = rc.sx(l.x);
      const sy = rc.sy(l.y);
      if (sx < -20 || sy < -20 || sx > w + 20 || sy > h + 20) continue;
      const rar = RARITY[l.rarity] || RARITY[0];
      const r = e.loot.size * Math.max(0.7, Math.min(1.4, scale));
      if (l.rarity >= 3) {
        const pulse = (now * 0.9 + l.id * 0.37) % 1;
        ctx.strokeStyle = hexA(rar.color, (1 - pulse) * 0.6);
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(sx, sy, r + pulse * 12, 0, TAU);
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.arc(sx, sy, r, 0, TAU);
      ctx.fillStyle = hexA(rar.color, 0.2 * op + 0.1);
      ctx.fill();
      ctx.lineWidth = 1.6;
      ctx.strokeStyle = hexA(rar.color, op);
      ctx.stroke();
      lootGlyph(ctx, l.kind, sx, sy, r);
      ctx.fillStyle = hexA(rar.color, op);
      ctx.fill();
      if (e.loot.labels && d < maxD * 0.65) {
        haloText(ctx, l.name || l.kind, sx, sy + r + 11 * ls, hexA(rar.color, 0.95), 9.5 * ls, 600);
      }
    }
  }

  // ---- players --------------------------------------------------------------
  const lb = e.labels;
  for (const p of snap.players) {
    if (p.hp <= 0) continue;
    const d = Math.hypot(p.x - self.x, p.y - self.y);
    if (d > maxD) continue;
    const sx = rc.sx(p.x);
    const sy = rc.sy(p.y);
    const base = colorFor(cfg, p, self);
    const color = hexA(base, op);
    const l = vis.los.get(p.id);
    const occluded = !!l && !l.visible;
    const inside = sx > -40 && sy > -40 && sx < w + 40 && sy < h + 40;

    if (!inside) {
      if (e.offscreen.show) off.push({ p, d, base });
      continue;
    }
    if (e.lines.show) {
      ctx.strokeStyle = hexA(base, clamp(0.55 - (d / maxD) * 0.4, 0.12, 0.55));
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(sxSelf, sySelf);
      ctx.lineTo(sx, sy);
      ctx.stroke();
    }
    const half = Math.max(9, p.r * scale * (e.boxes.scale / 100));
    if (e.boxes.show) drawBox(ctx, sx, sy, half, e.boxes.style, e.boxes.thickness, color, e.boxes.dashedOccluded && occluded);

    // name (above)
    let top = sy - half - 5;
    if (lb.names) {
      haloText(ctx, p.name, sx, top, hexA(base, Math.min(1, op + 0.05)), 11 * ls, 700);
      top -= 12 * ls;
    }
    // health (below)
    let y = sy + half + 4;
    if (lb.health) {
      const frac = clamp(p.hp / p.maxHp, 0, 1);
      const bw = Math.max(26, half * 2);
      const bh = Math.max(3, 4 * ls);
      const bx = sx - bw / 2;
      ctx.fillStyle = 'rgba(8,9,12,0.8)';
      roundRectPath(ctx, bx - 1, y - 1, bw + 2, bh + 2, 3);
      ctx.fill();
      ctx.fillStyle = healthColor(frac);
      if (lb.healthStyle === 'segments') {
        const n = 5;
        const gap = 2;
        const segW = (bw - gap * (n - 1)) / n;
        for (let i = 0; i < n; i++) {
          const fill = clamp(frac * n - i, 0, 1);
          if (fill > 0) ctx.fillRect(bx + i * (segW + gap), y, segW * fill, bh);
        }
      } else {
        ctx.fillRect(bx, y, bw * frac, bh);
      }
      y += bh + 9 * ls;
      if (lb.hpText) {
        haloText(ctx, String(Math.round(p.hp)), sx, y, 'rgba(233,236,242,0.95)', 9 * ls, 600);
        y += 10 * ls;
      }
    }
    const info = [];
    if (lb.distance) info.push(lb.unit === 'm' ? `${(d / upm).toFixed(0)} m` : `${d.toFixed(0)} u`);
    if (lb.weapon && p.weapon) info.push(p.weapon);
    if (info.length) haloText(ctx, info.join(' · '), sx, y + 2, 'rgba(210,216,228,0.92)', 9.5 * ls, 600);
  }

  // ---- off-screen indicators ----------------------------------------------------
  if (off.length) {
    off.sort((a, b) => a.d - b.d);
    const m = e.offscreen.margin;
    const ox = clamp(sxSelf, m + 1, w - m - 1);
    const oy = clamp(sySelf, m + 1, h - m - 1);
    const n = Math.min(off.length, e.offscreen.maxCount);
    for (let i = 0; i < n; i++) {
      const { p, d, base } = off[i];
      const dx = rc.sx(p.x) - ox;
      const dy = rc.sy(p.y) - oy;
      const tx = dx > 0 ? (w - m - ox) / dx : dx < 0 ? (m - ox) / dx : Infinity;
      const ty = dy > 0 ? (h - m - oy) / dy : dy < 0 ? (m - oy) / dy : Infinity;
      const k = Math.min(tx, ty);
      const ex = ox + dx * k;
      const ey = oy + dy * k;
      const ang = Math.atan2(dy, dx);
      const size = e.offscreen.size * lerp(1.25, 0.75, clamp(d / maxD, 0, 1));
      ctx.save();
      ctx.translate(ex, ey);
      ctx.rotate(ang);
      arrowHead(ctx, size);
      ctx.fillStyle = hexA(base, 0.92 * op + 0.08);
      ctx.shadowColor = hexA(base, 0.6);
      ctx.shadowBlur = 8;
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.lineWidth = 1.2;
      ctx.strokeStyle = 'rgba(6,7,9,0.8)';
      ctx.stroke();
      ctx.restore();
      if (e.offscreen.labels) {
        const lx = ex - Math.cos(ang) * (size + 16);
        const ly = ey - Math.sin(ang) * (size + 10);
        chip(ctx, `${(d / upm).toFixed(0)} m`, lx, ly, { size: 9, mono: true, fg: hexA(base, 1), border: hexA(base, 0.35) });
      }
    }
  }
  ctx.restore();
}

