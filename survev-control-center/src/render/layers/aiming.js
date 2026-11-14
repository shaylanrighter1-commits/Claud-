// Aiming visualization: FOV circle, candidate scoring, lock brackets, projectile lead + ghost
// projectile, aim trajectory with spread cone, raw-vs-assisted aim.

import { hexA, haloText, chip, crosshair, bracket } from '../draw.js';
import { TAU, clamp } from '../../core/math.js';

const REASONS = { friendly: 'ALLY', range: 'RANGE', fov: '', sight: 'NO SIGHT', shot: 'BLOCKED' };

export function drawAiming(rc) {
  const { ctx, snap, cfg, aim, scale, now, w, h } = rc;
  const a = cfg.aiming;
  if (!a.enabled || !aim) return;
  const self = snap.self;
  const upm = snap.meta.unitsPerMeter || 1;
  const accent = cfg.theme.accent;
  const sxSelf = rc.sx(self.x);
  const sySelf = rc.sy(self.y);
  const cur = rc.cursor || { x: w / 2, y: h / 2 };
  const active = aim.active;
  ctx.save();
  ctx.lineJoin = 'round';

  // ---- FOV circle -------------------------------------------------------------
  if (a.showFov) {
    const pulse = a.fovPulse ? Math.sin(now * 2.4) * 0.5 + 0.5 : 0;
    ctx.beginPath();
    ctx.arc(cur.x, cur.y, a.fovRadius, 0, TAU);
    ctx.fillStyle = hexA(a.fovColor, (a.fovOpacity / 100) * (active ? 1.7 : 1));
    ctx.fill();
    ctx.lineWidth = active ? 2 : 1.4 + pulse * 0.6;
    ctx.strokeStyle = hexA(a.fovColor, active ? 0.95 : 0.55 + pulse * 0.15);
    ctx.setLineDash(active ? [] : [7, 6]);
    ctx.lineDashOffset = -now * 22;
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.lineWidth = 1;
    ctx.strokeStyle = hexA(a.fovColor, 0.5);
    for (let i = 0; i < 4; i++) {
      const ang = (i * Math.PI) / 2;
      ctx.beginPath();
      ctx.moveTo(cur.x + Math.cos(ang) * (a.fovRadius - 7), cur.y + Math.sin(ang) * (a.fovRadius - 7));
      ctx.lineTo(cur.x + Math.cos(ang) * (a.fovRadius + 3), cur.y + Math.sin(ang) * (a.fovRadius + 3));
      ctx.stroke();
    }
    crosshair(ctx, cur.x, cur.y, 7, 2);
    ctx.strokeStyle = 'rgba(255,255,255,0.7)';
    ctx.stroke();
    chip(ctx, `FOV ${Math.round(a.fovRadius)}px`, cur.x, cur.y - a.fovRadius - 12, { size: 9, mono: true, fg: hexA(a.fovColor, 1), border: hexA(a.fovColor, 0.3) });
  }

  // ---- candidates -------------------------------------------------------------
  if (a.showCandidates) {
    for (const c of aim.cands) {
      if (c.id === aim.target) continue;
      const p = snap.players.find((q) => q.id === c.id);
      if (!p) continue;
      const sx = rc.sx(p.x);
      const sy = rc.sy(p.y);
      const near = c.px <= a.fovRadius * 1.15;
      if (!near) continue;
      const bad = c.reason && c.reason !== 'fov';
      ctx.strokeStyle = bad ? 'rgba(255,77,94,0.45)' : 'rgba(233,236,242,0.28)';
      ctx.setLineDash(bad ? [3, 4] : []);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(cur.x, cur.y);
      ctx.lineTo(sx, sy);
      ctx.stroke();
      ctx.setLineDash([]);
      const txt = c.reason && REASONS[c.reason] ? REASONS[c.reason] : `${Math.round(c.px)}px`;
      haloText(ctx, txt, sx, sy + p.r * scale + 24, bad ? '#ff8a96' : 'rgba(233,236,242,0.75)', 9, 700);
    }
  }

  // ---- target + lead + ghost projectile -----------------------------------------------
  const t = aim.targetEnt;
  if (t) {
    const tx = rc.sx(t.x);
    const ty = rc.sy(t.y);
    const half = Math.max(14, t.r * scale * 1.7);
    ctx.lineWidth = 2;
    ctx.strokeStyle = hexA(accent, active ? 1 : 0.6);
    bracket(ctx, tx, ty, half, 8);
    ctx.stroke();
    if (a.showCandidates || active) {
      ctx.strokeStyle = hexA(accent, active ? 0.9 : 0.4);
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.moveTo(cur.x, cur.y);
      ctx.lineTo(tx, ty);
      ctx.stroke();
    }
    chip(ctx, active ? 'LOCKED' : 'CANDIDATE', tx, ty - half - 12, { size: 9, weight: 700, fg: active ? '#ffffff' : '#c7d2ea', bg: active ? hexA(accent, 0.85) : 'rgba(10,11,14,0.78)', border: hexA(accent, 0.6) });

    const lead = aim.lead;
    if (lead && !lead.off) {
      const lx = rc.sx(lead.x);
      const ly = rc.sy(lead.y);
      if (a.prediction.showPath) {
        ctx.setLineDash([2, 5]);
        ctx.lineWidth = 1.5;
        ctx.strokeStyle = hexA('#ffd166', 0.8);
        ctx.beginPath();
        ctx.moveTo(tx, ty);
        ctx.lineTo(lx, ly);
        ctx.stroke();
        ctx.setLineDash([]);
        // 100 ms ticks along the predicted path
        const steps = Math.floor(lead.lead * 10);
        for (let i = 1; i <= steps; i++) {
          const f = (i / 10) / Math.max(lead.lead, 1e-6);
          ctx.fillStyle = 'rgba(255,209,102,0.8)';
          ctx.fillRect(tx + (lx - tx) * f - 1.5, ty + (ly - ty) * f - 1.5, 3, 3);
        }
      }
      if (a.prediction.showMarker) {
        ctx.strokeStyle = '#ffd166';
        ctx.lineWidth = 1.8;
        ctx.beginPath();
        ctx.arc(lx, ly, 9, 0, TAU);
        ctx.stroke();
        crosshair(ctx, lx, ly, 14, 5);
        ctx.stroke();
        chip(ctx, `LEAD ${Math.round(lead.lead * 1000)} ms${lead.clamped ? ' (max)' : ''}`, lx, ly + 22, { size: 9, mono: true, fg: '#ffd166', border: 'rgba(255,209,102,0.35)' });
      }
      if (a.prediction.showGhost) {
        const tof = Math.max(lead.tof, 0.05);
        const phase = (now % (tof + 0.5)) / tof;
        const f = clamp(phase, 0, 1);
        const gx = sxSelf + (lx - sxSelf) * f;
        const gy = sySelf + (ly - sySelf) * f;
        const trail = 0.18;
        const g = ctx.createLinearGradient(sxSelf + (lx - sxSelf) * Math.max(0, f - trail), sySelf + (ly - sySelf) * Math.max(0, f - trail), gx, gy);
        g.addColorStop(0, 'rgba(255,209,102,0)');
        g.addColorStop(1, 'rgba(255,209,102,0.9)');
        ctx.strokeStyle = g;
        ctx.lineWidth = 2.5;
        ctx.beginPath();
        ctx.moveTo(sxSelf + (lx - sxSelf) * Math.max(0, f - trail), sySelf + (ly - sySelf) * Math.max(0, f - trail));
        ctx.lineTo(gx, gy);
        ctx.stroke();
        ctx.fillStyle = '#fff3c4';
        ctx.beginPath();
        ctx.arc(gx, gy, 3, 0, TAU);
        ctx.fill();
        // "predicted target" ghost at the interception time
        if (f >= 1) {
          ctx.strokeStyle = 'rgba(255,209,102,0.6)';
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.arc(lx, ly, 14 + (phase - 1) * 40, 0, TAU);
          ctx.stroke();
        }
      }
    }
  }

  // ---- trajectory + spread cone ---------------------------------------------------------
  const tr = aim.traj;
  if (tr && (a.showTrajectory || a.showSpread)) {
    const x1 = rc.sx(tr.x1);
    const y1 = rc.sy(tr.y1);
    if (a.showSpread && tr.spread > 0) {
      const len = tr.len * scale;
      ctx.beginPath();
      ctx.moveTo(sxSelf, sySelf);
      ctx.lineTo(sxSelf + Math.cos(tr.angle - tr.spread) * len, sySelf + Math.sin(tr.angle - tr.spread) * len);
      ctx.lineTo(sxSelf + Math.cos(tr.angle + tr.spread) * len, sySelf + Math.sin(tr.angle + tr.spread) * len);
      ctx.closePath();
      ctx.fillStyle = hexA(accent, 0.09);
      ctx.fill();
    }
    if (a.showTrajectory) {
      const g = ctx.createLinearGradient(sxSelf, sySelf, x1, y1);
      g.addColorStop(0, hexA(accent, 0.15));
      g.addColorStop(1, hexA(accent, active ? 0.95 : 0.7));
      ctx.strokeStyle = g;
      ctx.lineWidth = 1.6;
      ctx.beginPath();
      ctx.moveTo(sxSelf, sySelf);
      ctx.lineTo(x1, y1);
      ctx.stroke();
      if (a.showImpact) {
        const hit = tr.hit;
        const col = hit.kind === 'player' ? '#ff4d5e' : hit.kind === 'obstacle' ? '#ff9f43' : '#8b91a0';
        ctx.strokeStyle = col;
        ctx.lineWidth = 1.8;
        ctx.beginPath();
        ctx.arc(x1, y1, 5, 0, TAU);
        ctx.stroke();
        const label = hit.kind === 'player' ? `HIT ${hit.name}` : hit.kind === 'obstacle' ? `BLOCKED · ${hit.name}` : 'MAX RANGE';
        chip(ctx, `${label} · ${(tr.len / upm).toFixed(0)} m`, x1, y1 - 14, { size: 9, mono: true, fg: col, border: hexA(col, 0.35) });
      }
    }
    // raw (unassisted) aim direction for comparison
    if (aim.locked && Math.abs(aim.rawAngle - aim.appliedAngle) > 0.01) {
      ctx.setLineDash([2, 5]);
      ctx.strokeStyle = 'rgba(233,236,242,0.3)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(sxSelf, sySelf);
      ctx.lineTo(sxSelf + Math.cos(aim.rawAngle) * 130, sySelf + Math.sin(aim.rawAngle) * 130);
      ctx.stroke();
      ctx.setLineDash([]);
      haloText(ctx, 'raw', sxSelf + Math.cos(aim.rawAngle) * 142, sySelf + Math.sin(aim.rawAngle) * 142, 'rgba(233,236,242,0.55)', 9, 600);
    }
    if (aim.errorDeg != null && aim.locked) {
      haloText(ctx, `${aim.errorDeg >= 0 ? '+' : ''}${aim.errorDeg.toFixed(1)}°`, sxSelf, sySelf - self.r * scale - 14, hexA(accent, 1), 10, 700);
    }
  }
  ctx.restore();
}
