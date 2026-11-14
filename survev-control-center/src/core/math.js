// Geometry helpers. Pure functions, no DOM or extension APIs.
// Obstacle shape: { id, type:'rect'|'circle', x, y, w, h, r, sight, bullets, move }
//   rect: x,y = top-left corner, w,h = size.   circle: x,y = centre, r = radius.

export const TAU = Math.PI * 2;
export const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
export const lerp = (a, b, t) => a + (b - a) * t;
export const dist = (ax, ay, bx, by) => Math.hypot(bx - ax, by - ay);
export const deg = (r) => (r * 180) / Math.PI;
export const rad = (d) => (d * Math.PI) / 180;

/** Signed shortest rotation from angle a to angle b, in (-PI, PI]. */
export function angleDiff(a, b) {
  let d = (b - a) % TAU;
  if (d > Math.PI) d -= TAU;
  else if (d <= -Math.PI) d += TAU;
  return d;
}
export const lerpAngle = (a, b, t) => a + angleDiff(a, b) * t;

/** Deterministic PRNG (so demo scenarios and replays are reproducible). */
export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Ray vs axis-aligned rectangle (slab method). Returns [tEnter, tExit] or null. */
export function rayRect(ox, oy, dx, dy, rx, ry, rw, rh) {
  let tmin = -Infinity;
  let tmax = Infinity;
  if (dx !== 0) {
    let t1 = (rx - ox) / dx;
    let t2 = (rx + rw - ox) / dx;
    if (t1 > t2) [t1, t2] = [t2, t1];
    if (t1 > tmin) tmin = t1;
    if (t2 < tmax) tmax = t2;
  } else if (ox < rx || ox > rx + rw) return null;
  if (dy !== 0) {
    let t1 = (ry - oy) / dy;
    let t2 = (ry + rh - oy) / dy;
    if (t1 > t2) [t1, t2] = [t2, t1];
    if (t1 > tmin) tmin = t1;
    if (t2 < tmax) tmax = t2;
  } else if (oy < ry || oy > ry + rh) return null;
  if (tmax < tmin || tmax < 0) return null;
  return [tmin, tmax];
}

/** Ray vs circle. Returns [tEnter, tExit] or null. */
export function rayCircle(ox, oy, dx, dy, cx, cy, r) {
  const fx = ox - cx;
  const fy = oy - cy;
  const a = dx * dx + dy * dy;
  if (a === 0) return null;
  const b = 2 * (fx * dx + fy * dy);
  const c = fx * fx + fy * fy - r * r;
  const disc = b * b - 4 * a * c;
  if (disc < 0) return null;
  const s = Math.sqrt(disc);
  return [(-b - s) / (2 * a), (-b + s) / (2 * a)];
}

export function rayObstacle(o, ox, oy, dx, dy) {
  return o.type === 'circle'
    ? rayCircle(ox, oy, dx, dy, o.x, o.y, o.r)
    : rayRect(ox, oy, dx, dy, o.x, o.y, o.w, o.h);
}

/**
 * First obstacle (with `flag` truthy: 'sight' | 'bullets' | 'move') hit by the ray within [0, maxT].
 * Obstacles that already contain the ray origin are ignored (standing inside a bush must not blind you).
 * Returns { t, obstacle } or null.
 */
export function raycast(ox, oy, dx, dy, maxT, obstacles, flag) {
  let best = maxT;
  let hit = null;
  for (let i = 0; i < obstacles.length; i++) {
    const o = obstacles[i];
    if (!o[flag]) continue;
    const r = rayObstacle(o, ox, oy, dx, dy);
    if (!r) continue;
    const t = r[0];
    if (t < 0) continue;
    if (t < best) {
      best = t;
      hit = o;
    }
  }
  return hit ? { t: best, obstacle: hit } : null;
}

/** Length of segment [0,maxT] (in ray units) that lies inside obstacle o. */
export function insideLength(o, ox, oy, dx, dy, maxT) {
  const r = rayObstacle(o, ox, oy, dx, dy);
  if (!r) return 0;
  const a = Math.max(r[0], 0);
  const b = Math.min(r[1], maxT);
  return b > a ? (b - a) * Math.hypot(dx, dy) : 0;
}

/** Push a circle out of a rectangle. Returns { nx, ny, pen, px, py } (pen > 0 = overlap) or null. */
export function circleRectPush(cx, cy, cr, rx, ry, rw, rh) {
  const nxp = clamp(cx, rx, rx + rw);
  const nyp = clamp(cy, ry, ry + rh);
  let dx = cx - nxp;
  let dy = cy - nyp;
  const d2 = dx * dx + dy * dy;
  if (d2 > cr * cr) return null;
  if (d2 > 1e-9) {
    const d = Math.sqrt(d2);
    return { nx: dx / d, ny: dy / d, pen: cr - d, px: nxp, py: nyp };
  }
  // Centre inside the rectangle: exit through the nearest edge.
  const l = cx - rx;
  const r = rx + rw - cx;
  const t = cy - ry;
  const b = ry + rh - cy;
  const m = Math.min(l, r, t, b);
  if (m === l) return { nx: -1, ny: 0, pen: cr + l, px: rx, py: cy };
  if (m === r) return { nx: 1, ny: 0, pen: cr + r, px: rx + rw, py: cy };
  if (m === t) return { nx: 0, ny: -1, pen: cr + t, px: cx, py: ry };
  return { nx: 0, ny: 1, pen: cr + b, px: cx, py: ry + rh };
}

export function circleCirclePush(cx, cy, cr, ox, oy, or) {
  const dx = cx - ox;
  const dy = cy - oy;
  const d = Math.hypot(dx, dy);
  const min = cr + or;
  if (d >= min) return null;
  if (d < 1e-6) return { nx: 1, ny: 0, pen: min, px: ox + or, py: oy };
  return { nx: dx / d, ny: dy / d, pen: min - d, px: ox + (dx / d) * or, py: oy + (dy / d) * or };
}
