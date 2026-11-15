// Snapshot schema + sanitizer.
// Every external frame (dev API message, imported replay) passes through sanitizeSnapshot() before use:
// numbers are finite-checked, strings truncated, arrays capped. Unknown fields are dropped.
//
// Snapshot shape (all coordinates are world units, angles are radians):
// {
//   t, seq, mapRev,
//   world:  { w, h },
//   meta:   { unitsPerMeter, source, scenario },
//   camera: { x, y, scale, view?: { left, top, width, height } },   // view = game canvas rect in client px
//   self:   { id, name, team, x, y, vx, vy, angle, r, hp, maxHp, weapon:{name,bulletSpeed,range,spread,fireRate}, cursor?:{x,y} },
//   players:[ { id, name, team, x, y, vx, vy, angle, r, hp, maxHp, weapon } ],      // everyone except self
//   obstacles:[ { id, type:'rect'|'circle', kind, x, y, w, h, r, sight, bullets, move } ],
//   loot:   [ { id, x, y, kind, rarity, name } ],
//   bullets:[ { id, x, y, vx, vy, owner } ],
//   events: [ { type:'shot'|'hit'|'impact'|'expire'|'kill', ... } ]
// }

import { WEAPONS } from './defaults.js';

export const LIMITS = { players: 256, obstacles: 3000, loot: 1500, bullets: 1500, events: 128 };

const num = (v, d = 0) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
const str = (v, d = '') => (typeof v === 'string' ? v.slice(0, 32) : typeof v === 'number' ? String(v) : d);
const ident = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' ? v.slice(0, 40) : null);

function weaponOf(w, full) {
  if (typeof w === 'string') {
    if (!full) return { name: str(w) };
    const known = Object.values(WEAPONS).find((k) => k.id === w || k.name === w);
    return { ...(known || WEAPONS.rifle), name: str(w) };
  }
  if (w && typeof w === 'object') {
    const base = WEAPONS.rifle;
    return {
      name: str(w.name, base.name),
      bulletSpeed: Math.max(1, num(w.bulletSpeed, base.bulletSpeed)),
      range: Math.max(1, num(w.range, base.range)),
      spread: Math.max(0, num(w.spread, base.spread)),
      fireRate: Math.max(0.1, num(w.fireRate, base.fireRate)),
    };
  }
  return full ? { ...WEAPONS.rifle } : { name: '' };
}

function playerOf(p, full) {
  const id = ident(p && p.id);
  if (id == null || !Number.isFinite(p.x) || !Number.isFinite(p.y)) return null;
  const maxHp = Math.max(1, num(p.maxHp, 100));
  const out = {
    id,
    name: str(p.name, String(id)),
    team: p.team == null ? null : ident(p.team),
    x: p.x,
    y: p.y,
    vx: num(p.vx),
    vy: num(p.vy),
    angle: num(p.angle),
    r: Math.min(500, Math.max(1, num(p.r, 14))),
    hp: Math.min(maxHp, Math.max(0, num(p.hp, maxHp))),
    maxHp,
    weapon: weaponOf(p.weapon, full),
  };
  if (full && p.cursor && Number.isFinite(p.cursor.x) && Number.isFinite(p.cursor.y)) out.cursor = { x: p.cursor.x, y: p.cursor.y };
  if (!full) out.weapon = out.weapon.name;
  return out;
}

export function sanitizeObstacles(list) {
  const out = [];
  if (!Array.isArray(list)) return out;
  for (let i = 0; i < list.length && out.length < LIMITS.obstacles; i++) {
    const o = list[i];
    if (!o || !Number.isFinite(o.x) || !Number.isFinite(o.y)) continue;
    const base = {
      id: ident(o.id) ?? i,
      kind: str(o.kind, 'wall'),
      x: o.x,
      y: o.y,
      sight: o.sight !== false,
      bullets: o.bullets !== false,
      move: o.move !== false,
    };
    if (o.type === 'circle' && num(o.r) > 0) out.push({ ...base, type: 'circle', r: o.r });
    else if (num(o.w) > 0 && num(o.h) > 0) out.push({ ...base, type: 'rect', w: o.w, h: o.h });
  }
  return out;
}

function sanitizeLoot(list) {
  const out = [];
  if (!Array.isArray(list)) return out;
  for (let i = 0; i < list.length && out.length < LIMITS.loot; i++) {
    const l = list[i];
    if (!l || !Number.isFinite(l.x) || !Number.isFinite(l.y)) continue;
    out.push({
      id: ident(l.id) ?? i,
      x: l.x,
      y: l.y,
      kind: str(l.kind, 'item'),
      name: str(l.name, ''),
      rarity: Math.min(4, Math.max(0, Math.round(num(l.rarity)))),
    });
  }
  return out;
}

function sanitizeBullets(list) {
  const out = [];
  if (!Array.isArray(list)) return out;
  for (let i = 0; i < list.length && out.length < LIMITS.bullets; i++) {
    const b = list[i];
    if (!b || !Number.isFinite(b.x) || !Number.isFinite(b.y)) continue;
    out.push({ id: ident(b.id) ?? i, x: b.x, y: b.y, vx: num(b.vx), vy: num(b.vy), owner: ident(b.owner) });
  }
  return out;
}

function sanitizeEvents(list) {
  const out = [];
  if (!Array.isArray(list)) return out;
  const types = new Set(['shot', 'hit', 'impact', 'expire', 'kill']);
  for (let i = 0; i < list.length && out.length < LIMITS.events; i++) {
    const e = list[i];
    if (!e || !types.has(e.type)) continue;
    out.push({
      type: e.type,
      t: num(e.t),
      x: num(e.x),
      y: num(e.y),
      angle: num(e.angle),
      dmg: num(e.dmg),
      ownerId: ident(e.ownerId),
      targetId: ident(e.targetId),
      bulletId: ident(e.bulletId),
      obstacleId: ident(e.obstacleId),
      kind: str(e.kind),
    });
  }
  return out;
}

const WS_STATES = new Set(['connecting', 'open', 'closing', 'closed', 'none']);

/** Optional network values the game itself publishes (never measured or invented by the extension). */
export function sanitizeNet(n) {
  if (!n || typeof n !== 'object') return null;
  const int = (v) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? Math.round(v) : null);
  const out = {
    rttMs: typeof n.rttMs === 'number' && Number.isFinite(n.rttMs) && n.rttMs >= 0 && n.rttMs < 60000 ? n.rttMs : null,
    wsState: WS_STATES.has(n.wsState) ? n.wsState : null,
    disconnects: int(n.disconnects),
    reconnects: int(n.reconnects),
    serverTickMs: typeof n.serverTickMs === 'number' && Number.isFinite(n.serverTickMs) && n.serverTickMs > 0 ? n.serverTickMs : null,
  };
  return Object.values(out).some((v) => v != null) ? out : null;
}

export function sanitizeSnapshot(raw, opts = {}) {
  if (!raw || typeof raw !== 'object') return null;
  const self = playerOf(raw.self, true);
  if (!self) return null;
  const players = [];
  if (Array.isArray(raw.players)) {
    for (let i = 0; i < raw.players.length && players.length < LIMITS.players; i++) {
      const p = playerOf(raw.players[i], false);
      if (p && p.id !== self.id) players.push(p);
    }
  }
  const cam = raw.camera || {};
  const camera = { x: num(cam.x, self.x), y: num(cam.y, self.y), scale: Math.min(20, Math.max(0.05, num(cam.scale, 1))) };
  const v = cam.view;
  if (v && Number.isFinite(v.width) && Number.isFinite(v.height) && v.width > 0 && v.height > 0) {
    camera.view = { left: num(v.left), top: num(v.top), width: v.width, height: v.height };
  }
  const meta = raw.meta || {};
  return {
    t: num(raw.t),
    seq: 0,
    mapRev: num(raw.mapRev, 0),
    world: { w: Math.max(1, num(raw.world && raw.world.w, 1000)), h: Math.max(1, num(raw.world && raw.world.h, 1000)) },
    meta: {
      unitsPerMeter: Math.min(1000, Math.max(0.01, num(meta.unitsPerMeter, 1))),
      source: str(meta.source, opts.source || 'dev'),
      scenario: str(meta.scenario, ''),
    },
    camera,
    self,
    players,
    obstacles: opts.skipObstacles ? [] : sanitizeObstacles(raw.obstacles),
    loot: sanitizeLoot(raw.loot),
    bullets: sanitizeBullets(raw.bullets),
    events: sanitizeEvents(raw.events),
    net: sanitizeNet(raw.net),
  };
}
