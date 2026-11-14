// Aim analysis: target selection, projectile lead prediction, smoothing and trajectory diagnostics.
//
// This module is a *visualization / test harness*. It computes where a test reticle would point so the
// result can be drawn and measured. In the demo arena the result drives the simulated test shooter; for
// dev-API sessions and replays it is read-only analysis. It never emits input to any page.

import { clamp, lerp, angleDiff, raycast, rayCircle, rad, deg } from '../core/math.js';
import { relationOf } from '../core/util.js';
import { getObsLists } from './visibility.js';

/** Smallest positive time t where a projectile of `speed` launched now meets a constant-velocity target. */
export function interceptTime(dx, dy, vx, vy, speed) {
  const a = vx * vx + vy * vy - speed * speed;
  const b = 2 * (dx * vx + dy * vy);
  const c = dx * dx + dy * dy;
  if (Math.abs(a) < 1e-6) {
    if (Math.abs(b) < 1e-9) return null;
    const t = -c / b;
    return t > 0 ? t : null;
  }
  const disc = b * b - 4 * a * c;
  if (disc < 0) return null;
  const s = Math.sqrt(disc);
  const t1 = (-b - s) / (2 * a);
  const t2 = (-b + s) / (2 * a);
  let t = Infinity;
  if (t1 > 1e-6) t = t1;
  if (t2 > 1e-6 && t2 < t) t = t2;
  return Number.isFinite(t) ? t : null;
}

/** Predicted aim point for a moving target. `o` = { strength 0..1.5, maxLead s, latency s }. */
export function leadPoint(shooter, target, speed, o) {
  const dx = target.x - shooter.x;
  const dy = target.y - shooter.y;
  const vx = target.vx || 0;
  const vy = target.vy || 0;
  const direct = Math.hypot(dx, dy) / speed;
  const t = interceptTime(dx, dy, vx, vy, speed);
  const solved = t != null;
  let lead = ((solved ? t : direct) + o.latency) * o.strength;
  const clamped = lead > o.maxLead;
  lead = Math.min(lead, o.maxLead);
  const x = target.x + vx * lead;
  const y = target.y + vy * lead;
  return { x, y, lead, solved, clamped, tof: Math.hypot(x - shooter.x, y - shooter.y) / speed };
}

/** Probability (0..1) that a shot with uniform `spread` (rad half-angle) lands inside a target of angular half-width `halfW`. */
export function hitProbability(errRad, halfW, spreadRad) {
  if (spreadRad < 1e-6) return Math.abs(errRad) <= halfW ? 1 : 0;
  const lo = Math.max(errRad - halfW, -spreadRad);
  const hi = Math.min(errRad + halfW, spreadRad);
  return clamp((hi - lo) / (2 * spreadRad), 0, 1);
}

export function smoothAngle(cur, desired, dt, smoothing, maxTurnDeg) {
  const s = clamp(smoothing / 100, 0, 1);
  const diff = angleDiff(cur, desired);
  if (s <= 0.001) return desired;
  const speed = lerp(30, 2.2, Math.pow(s, 0.7));
  let step = diff * (1 - Math.exp(-speed * dt));
  const maxStep = rad(maxTurnDeg) * dt;
  step = clamp(step, -maxStep, maxStep);
  return cur + step;
}

function scoreOf(mode, c, p, self) {
  switch (mode) {
    case 'distance':
      return c.dist;
    case 'health':
      return p.hp + c.dist * 0.01;
    case 'threat': {
      const bearing = Math.atan2(self.y - p.y, self.x - p.x);
      return Math.abs(angleDiff(p.angle || 0, bearing)) * 100 + c.dist * 0.05;
    }
    default:
      return c.px;
  }
}

export class AimEngine {
  constructor() {
    this.reset();
  }

  reset() {
    this.lockedId = null;
    this.lockedAt = 0;
    this.wasActive = false;
    this.activeSince = 0;
    this.acquireDelay = null;
    this.acquired = false;
  }

  /**
   * @param snap       current snapshot
   * @param cfg        full config
   * @param cursor     {x,y} raw cursor in world coordinates
   * @param lockActive whether the aim-lock test key is engaged
   * @param dt         seconds since last frame
   * @param interactive true if the result drives a simulated shooter (demo), false for read-only analysis
   * @param vis        result of computeVisibility()
   */
  update(snap, cfg, cursor, lockActive, dt, interactive, vis) {
    const a = cfg.aiming;
    const self = snap.self;
    const w = self.weapon;
    const scale = snap.camera.scale || 1;
    const upm = snap.meta.unitsPerMeter || 1;
    const lists = getObsLists(snap.obstacles);
    const raw = Math.atan2(cursor.y - self.y, cursor.x - self.x);
    const curAngle = Number.isFinite(self.angle) ? self.angle : raw;

    const out = {
      enabled: a.enabled,
      active: false,
      locked: false,
      cursor,
      rawAngle: raw,
      appliedAngle: interactive ? raw : curAngle,
      desiredAngle: null,
      errorDeg: null,
      cands: [],
      target: null,
      targetEnt: null,
      lead: null,
      aimPoint: null,
      hitProb: null,
      traj: null,
      weapon: w,
      fovWorld: a.fovRadius / scale,
      acquireDelay: this.acquireDelay,
    };
    if (!a.enabled) {
      this.reset();
      return out;
    }

    const active = !!lockActive;
    out.active = active;
    if (active && !this.wasActive) {
      this.activeSince = snap.t;
      this.acquireDelay = null;
      this.acquired = false;
    }
    if (!active) this.lockedId = null;
    this.wasActive = active;

    // --- candidate evaluation -------------------------------------------------
    const mode = a.visibilityCheck;
    let best = null;
    for (const p of snap.players) {
      if (p.hp <= 0) continue;
      const rel = relationOf(p, self);
      const d = Math.hypot(p.x - self.x, p.y - self.y);
      const px = Math.hypot(p.x - cursor.x, p.y - cursor.y) * scale;
      const c = { id: p.id, name: p.name, dist: d, px, inFov: px <= a.fovRadius, sightOk: true, shotOk: true, reason: null, score: 0, rel };
      const l = vis && vis.los.get(p.id);
      if (l) c.sightOk = l.visible;
      if (mode === 'shot' || mode === 'both') {
        c.shotOk = !raycast(self.x, self.y, p.x - self.x, p.y - self.y, 1, lists.bullets, 'bullets');
      }
      if (a.enemiesOnly && rel !== 'enemy') c.reason = 'friendly';
      else if (d > w.range * 1.05) c.reason = 'range';
      else if (!c.inFov) c.reason = 'fov';
      else if ((mode === 'sight' || mode === 'both') && !c.sightOk) c.reason = 'sight';
      else if ((mode === 'shot' || mode === 'both') && !c.shotOk) c.reason = 'shot';
      c.score = scoreOf(a.targetMode, c, p, self);
      out.cands.push(c);
      if (!c.reason && (!best || c.score < best.score)) best = c;
    }

    // Sticky targeting: don't flip between near-equal targets for stickyMs.
    if (active && this.lockedId != null) {
      const cur = out.cands.find((c) => c.id === this.lockedId && !c.reason);
      if (cur && best && best.id !== cur.id && snap.t - this.lockedAt < a.stickyMs / 1000) best = cur;
    }
    if (best) {
      if (active && this.lockedId !== best.id) {
        this.lockedId = best.id;
        this.lockedAt = snap.t;
        if (!this.acquired) {
          this.acquired = true;
          this.acquireDelay = Math.max(0, snap.t - this.activeSince);
          out.acquireDelay = this.acquireDelay;
        }
      }
      out.target = best.id;
      out.targetEnt = snap.players.find((p) => p.id === best.id) || null;
      out.locked = active;
    } else if (active) {
      this.lockedId = null;
    }

    // --- prediction ------------------------------------------------------------
    const t = out.targetEnt;
    if (t) {
      const pr = a.prediction;
      if (pr.enabled) {
        out.lead = leadPoint(self, t, w.bulletSpeed, {
          strength: pr.strength / 100,
          maxLead: pr.maxLeadMs / 1000,
          latency: pr.latencyMs / 1000,
        });
        out.aimPoint = { x: out.lead.x, y: out.lead.y };
      } else {
        out.aimPoint = { x: t.x, y: t.y };
        out.lead = { x: t.x, y: t.y, lead: 0, solved: false, clamped: false, tof: Math.hypot(t.x - self.x, t.y - self.y) / w.bulletSpeed, off: true };
      }
      out.desiredAngle = Math.atan2(out.aimPoint.y - self.y, out.aimPoint.x - self.x);
    }

    // --- angle -----------------------------------------------------------------
    if (interactive) {
      out.appliedAngle = out.locked && out.desiredAngle != null ? smoothAngle(curAngle, out.desiredAngle, dt, a.smoothing, a.maxTurnRate) : raw;
    }
    if (out.desiredAngle != null) out.errorDeg = deg(angleDiff(out.appliedAngle, out.desiredAngle));

    if (t) {
      const d = Math.hypot(t.x - self.x, t.y - self.y);
      const bearing = Math.atan2(t.y - self.y, t.x - self.x);
      const halfW = Math.asin(clamp((t.r + 1.5) / Math.max(d, t.r + 1.6), 0, 1));
      out.hitProb = hitProbability(angleDiff(out.appliedAngle, bearing), halfW, rad(w.spread));
    }

    // --- trajectory ------------------------------------------------------------
    const dx = Math.cos(out.appliedAngle);
    const dy = Math.sin(out.appliedAngle);
    let len = w.range;
    let hit = { kind: 'range' };
    const wallHit = raycast(self.x, self.y, dx, dy, len, lists.bullets, 'bullets');
    if (wallHit) {
      len = wallHit.t;
      hit = { kind: 'obstacle', id: wallHit.obstacle.id, name: wallHit.obstacle.kind };
    }
    for (const p of snap.players) {
      if (p.hp <= 0 || (a.enemiesOnly && relationOf(p, self) !== 'enemy')) continue;
      const r = rayCircle(self.x, self.y, dx, dy, p.x, p.y, p.r + 1.5);
      if (r && r[1] >= 0) {
        const tt = Math.max(r[0], 0);
        if (tt < len) {
          len = tt;
          hit = { kind: 'player', id: p.id, name: p.name };
        }
      }
    }
    out.traj = { x0: self.x, y0: self.y, x1: self.x + dx * len, y1: self.y + dy * len, len, hit, spread: rad(w.spread), angle: out.appliedAngle, upm };
    return out;
  }
}
