// Line-of-sight, occlusion and collision diagnostics over a snapshot's obstacle set.

import { TAU, raycast, insideLength, angleDiff, clamp, rad } from '../core/math.js';

const listCache = new WeakMap();

/** Obstacles pre-filtered by the property they affect (cached per obstacle array). */
export function getObsLists(obstacles) {
  let l = listCache.get(obstacles);
  if (!l) {
    l = {
      sight: obstacles.filter((o) => o.sight),
      bullets: obstacles.filter((o) => o.bullets),
      move: obstacles.filter((o) => o.move),
    };
    listCache.set(obstacles, l);
  }
  return l;
}

/** Visibility of one player from `self`. Four sample points on the player's hit circle. */
export function losFor(self, p, sightObs) {
  const dx = p.x - self.x;
  const dy = p.y - self.y;
  const d = Math.hypot(dx, dy);
  const res = { visible: true, fraction: 1, occluder: null, thickness: 0, hx: p.x, hy: p.y, dist: d };
  if (d < 1e-6 || sightObs.length === 0) return res;
  const ux = dx / d;
  const uy = dy / d;
  const r = (p.r || 14) * 0.85;
  const samples = [
    [p.x, p.y],
    [p.x - uy * r, p.y + ux * r],
    [p.x + uy * r, p.y - ux * r],
    [p.x - ux * r, p.y - uy * r],
  ];
  let seen = 0;
  for (let i = 0; i < samples.length; i++) {
    const sx = samples[i][0] - self.x;
    const sy = samples[i][1] - self.y;
    const hit = raycast(self.x, self.y, sx, sy, 1, sightObs, 'sight');
    if (!hit) seen++;
    else if (i === 0) {
      res.occluder = hit.obstacle.id;
      res.hx = self.x + sx * hit.t;
      res.hy = self.y + sy * hit.t;
      let thick = 0;
      for (const o of sightObs) thick += insideLength(o, self.x, self.y, sx, sy, 1);
      res.thickness = thick;
    }
  }
  res.fraction = seen / samples.length;
  res.visible = seen > 0;
  if (res.visible && res.occluder == null) res.occluder = null;
  return res;
}

function nearObstacles(list, ox, oy, range) {
  const out = [];
  for (const o of list) {
    if (o.type === 'circle') {
      if (Math.hypot(o.x - ox, o.y - oy) <= range + o.r) out.push(o);
    } else {
      const cx = clamp(ox, o.x, o.x + o.w);
      const cy = clamp(oy, o.y, o.y + o.h);
      if (Math.hypot(cx - ox, cy - oy) <= range) out.push(o);
    }
  }
  return out;
}

/**
 * Visibility polygon around (ox,oy) limited by `range` and an optional view cone.
 * Returns a flat [x0,y0,x1,y1,...] array (cone polygons start at the origin).
 */
export function visibilityPolygon(ox, oy, sightObs, range, facing, fov) {
  const near = nearObstacles(sightObs, ox, oy, range);
  const full = fov >= TAU - 0.01;
  const half = fov / 2;
  const rels = [];
  const add = (a) => {
    const rel = angleDiff(facing, a);
    if (full || Math.abs(rel) <= half + 1e-9) rels.push(rel);
  };
  const steps = full ? 72 : Math.max(8, Math.ceil(fov / rad(4)));
  for (let i = 0; i <= steps; i++) {
    const rel = full ? -Math.PI + (i / steps) * TAU : -half + (i / steps) * fov;
    rels.push(rel);
  }
  if (!full) {
    rels.push(-half, half);
  }
  const eps = 1e-4;
  for (const o of near) {
    if (o.type === 'circle') {
      const d = Math.hypot(o.x - ox, o.y - oy);
      if (d <= o.r) continue;
      const base = Math.atan2(o.y - oy, o.x - ox);
      const ang = Math.asin(o.r / d);
      add(base - ang - eps); add(base - ang + eps); add(base + ang - eps); add(base + ang + eps);
    } else {
      const xs = [o.x, o.x + o.w];
      const ys = [o.y, o.y + o.h];
      for (const cx of xs) {
        for (const cy of ys) {
          const a = Math.atan2(cy - oy, cx - ox);
          add(a - eps); add(a); add(a + eps);
        }
      }
    }
  }
  rels.sort((a, b) => a - b);
  const pts = [];
  if (!full) pts.push(ox, oy);
  for (let i = 0; i < rels.length; i++) {
    const a = facing + rels[i];
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    const hit = raycast(ox, oy, dx, dy, range, near, 'sight');
    const t = hit ? hit.t : range;
    pts.push(ox + dx * t, oy + dy * t);
  }
  return pts;
}

/** Player-vs-obstacle contacts (touching within 2 units) for collision debugging. */
export function computeContacts(snap, moveObs) {
  const out = [];
  const ents = [snap.self, ...snap.players];
  for (const p of ents) {
    const r = p.r || 14;
    for (const o of moveObs) {
      if (out.length >= 96) return out;
      let cx;
      let cy;
      if (o.type === 'circle') {
        const dx = p.x - o.x;
        const dy = p.y - o.y;
        const d = Math.hypot(dx, dy) || 1e-6;
        if (d - o.r > r + 2) continue;
        cx = o.x + (dx / d) * o.r;
        cy = o.y + (dy / d) * o.r;
        out.push({ pid: p.id, oid: o.id, x: cx, y: cy, nx: dx / d, ny: dy / d, pen: r + o.r - d });
      } else {
        cx = clamp(p.x, o.x, o.x + o.w);
        cy = clamp(p.y, o.y, o.y + o.h);
        const dx = p.x - cx;
        const dy = p.y - cy;
        const d = Math.hypot(dx, dy);
        if (d > r + 2) continue;
        out.push({ pid: p.id, oid: o.id, x: cx, y: cy, nx: d > 1e-6 ? dx / d : 0, ny: d > 1e-6 ? dy / d : -1, pen: r - d });
      }
    }
  }
  return out;
}

/**
 * Per-frame visibility analysis.
 * @returns {{los:Map, occluders:Set, polygon:number[]|null, contacts:Array, range:number}}
 */
export function computeVisibility(snap, cfg, opts = {}) {
  const lists = getObsLists(snap.obstacles);
  const upm = snap.meta.unitsPerMeter || 1;
  const los = new Map();
  const occluders = new Set();
  for (const p of snap.players) {
    const r = losFor(snap.self, p, lists.sight);
    los.set(p.id, r);
    if (r.occluder != null) occluders.add(r.occluder);
  }
  const v = cfg.visibility;
  const range = v.los.range * upm;
  let polygon = null;
  if (opts.polygon) {
    polygon = visibilityPolygon(snap.self.x, snap.self.y, lists.sight, range, snap.self.angle || 0, rad(v.los.fov));
  }
  const contacts = opts.contacts ? computeContacts(snap, lists.move) : [];
  return { los, occluders, polygon, contacts, range };
}
