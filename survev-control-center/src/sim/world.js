// Deterministic synthetic 2D arena used by the Demo Arena (and the dev-api example page).
// Entirely original: procedurally generated buildings, cover, loot and AI-driven bots.

import { mulberry32, clamp, lerpAngle, angleDiff, TAU, rad, raycast, rayCircle, circleRectPush, circleCirclePush } from '../core/math.js';
import { WEAPONS } from '../core/defaults.js';

const NAMES = ['Orion', 'Vega', 'Nova', 'Rook', 'Zephyr', 'Ghost', 'Atlas', 'Echo', 'Lyra', 'Kilo', 'Sable', 'Onyx', 'Pike', 'Wren', 'Juno', 'Tarn'];

export const SCENARIOS = {
  skirmish: { label: 'Skirmish', hint: 'Three teams fighting around buildings and cover.' },
  range: { label: 'Target Range', hint: 'Open ground, dummies moving on sine paths.' },
  strafe: { label: 'Strafe Test', hint: 'Constant-velocity targets at rising speeds — ideal for prediction tests.' },
  cover: { label: 'Cover Lab', hint: 'Dense cover with patrolling targets — ideal for occlusion tests.' },
};

const KIND_FLAGS = {
  wall: { sight: true, bullets: true, move: true },
  crate: { sight: true, bullets: true, move: true },
  barrel: { sight: true, bullets: true, move: true },
  rock: { sight: true, bullets: true, move: true },
  tree: { sight: false, bullets: true, move: true },
  bush: { sight: true, bullets: false, move: false },
  glass: { sight: false, bullets: true, move: true },
};

export class World {
  constructor(opts = {}) {
    this.mapRev = 0;
    this.self = null;
    this.accum = 0;
    this.reset(opts);
  }

  reset({ scenario = 'skirmish', seed = 7, bots = 8 } = {}) {
    this.scenario = SCENARIOS[scenario] ? scenario : 'skirmish';
    this.seed = seed;
    this.botCount = bots;
    this.rng = mulberry32(seed);
    this.w = 2400;
    this.h = 1500;
    this.upm = 10;
    this.t = 0;
    this.nid = 1000;
    this.seq = 0;
    this.accum = 0;
    this.mapRev++;
    this.obstacles = [];
    this.players = [];
    this.loot = [];
    this.bullets = [];
    this.events = [];
    this.selfWeapon = { ...WEAPONS.rifle };
    this.selfCd = 0;
    this.lastCursor = null;
    this._buildMap();
    this._spawn();
    this._spawnLoot();
  }

  // ---------------------------------------------------------------- map
  _add(kind, def) {
    const f = KIND_FLAGS[kind];
    this.obstacles.push({ id: this.obstacles.length + 1, kind, ...f, ...def });
  }

  _rect(kind, x, y, w, h) {
    this._add(kind, { type: 'rect', x, y, w, h });
  }

  _circle(kind, x, y, r) {
    this._add(kind, { type: 'circle', x, y, r });
  }

  _wallRun(horizontal, x, y, len, t, gapAt, gapLen, gapKind) {
    const seg = (a, b, kind) => {
      if (b - a < 1) return;
      if (horizontal) this._rect(kind, x + a, y, b - a, t);
      else this._rect(kind, x, y + a, t, b - a);
    };
    if (gapAt < 0) return seg(0, len, 'wall');
    seg(0, gapAt, 'wall');
    if (gapKind) seg(gapAt, gapAt + gapLen, gapKind);
    seg(gapAt + gapLen, len, 'wall');
  }

  _building(x, y, w, h) {
    const t = 14;
    const R = this.rng;
    const door = 60;
    this._wallRun(true, x, y, w, t, w * 0.25 + R() * w * 0.4, 80, 'glass'); // top: window
    this._wallRun(true, x, y + h - t, w, t, w * 0.2 + R() * w * 0.5, door, null); // bottom: door
    this._wallRun(false, x, y, h, t, h * 0.25 + R() * h * 0.4, 70, 'glass'); // left: window
    this._wallRun(false, x + w - t, y, h, t, h * 0.2 + R() * h * 0.5, door, null); // right: door
    if (R() < 0.7) this._rect('crate', x + 40 + R() * (w - 110), y + 40 + R() * (h - 110), 34, 34);
  }

  _free(x, y, r, margin = 0) {
    for (const o of this.obstacles) {
      if (o.type === 'circle') {
        if (Math.hypot(x - o.x, y - o.y) < r + o.r + margin) return false;
      } else if (x > o.x - r - margin && x < o.x + o.w + r + margin && y > o.y - r - margin && y < o.y + o.h + r + margin) return false;
    }
    return true;
  }

  _randomFree(r = 20, margin = 10, tries = 200) {
    for (let i = 0; i < tries; i++) {
      const x = 80 + this.rng() * (this.w - 160);
      const y = 80 + this.rng() * (this.h - 160);
      if (this._free(x, y, r, margin)) return { x, y };
    }
    return { x: this.w / 2, y: this.h / 2 };
  }

  _buildMap() {
    const R = this.rng;
    const T = 60;
    this._rect('wall', -T, -T, this.w + 2 * T, T);
    this._rect('wall', -T, this.h, this.w + 2 * T, T);
    this._rect('wall', -T, 0, T, this.h);
    this._rect('wall', this.w, 0, T, this.h);
    const sc = this.scenario;
    const cfg =
      sc === 'skirmish' ? { buildings: 6, crates: 14, trees: 14, bushes: 10, barrels: 6 }
      : sc === 'cover' ? { buildings: 3, crates: 30, trees: 18, bushes: 12, barrels: 10 }
      : sc === 'range' ? { buildings: 0, crates: 5, trees: 4, bushes: 4, barrels: 0 }
      : { buildings: 0, crates: 0, trees: 0, bushes: 0, barrels: 0 };
    const placed = [];
    const overlaps = (x, y, w, h, m) => placed.some((p) => x < p.x + p.w + m && x + w + m > p.x && y < p.y + p.h + m && y + h + m > p.y);
    for (let i = 0, tries = 0; i < cfg.buildings && tries < 400; tries++) {
      const w = 220 + R() * 120;
      const h = 180 + R() * 100;
      const x = 120 + R() * (this.w - w - 240);
      const y = 120 + R() * (this.h - h - 240);
      const centerClear = Math.hypot(x + w / 2 - this.w / 2, y + h / 2 - this.h / 2) > 260;
      if (!centerClear || overlaps(x, y, w, h, 80)) continue;
      placed.push({ x, y, w, h });
      this._building(x, y, w, h);
      i++;
    }
    const spots = (n, r, fn) => {
      for (let i = 0, tries = 0; i < n && tries < 600; tries++) {
        const x = 80 + R() * (this.w - 160);
        const y = 80 + R() * (this.h - 160);
        if (Math.hypot(x - this.w / 2, y - this.h / 2) < 90) continue;
        if (!this._free(x, y, r, 30) || overlaps(x - r, y - r, r * 2, r * 2, 20)) continue;
        fn(x, y);
        i++;
      }
    };
    spots(cfg.crates, 26, (x, y) => this._rect('crate', x - 20 - R() * 10, y - 20, 40 + R() * 20, 40 + R() * 20));
    spots(cfg.trees, 22, (x, y) => this._circle('tree', x, y, 20 + R() * 8));
    spots(cfg.bushes, 34, (x, y) => this._circle('bush', x, y, 30 + R() * 14));
    spots(cfg.barrels, 16, (x, y) => this._circle('barrel', x, y, 13));
  }

  // ---------------------------------------------------------------- entities
  _mk(id, name, team, x, y, ai, extra = {}) {
    return {
      id, name, team, x, y, vx: 0, vy: 0, angle: 0, r: 14, hp: 100, maxHp: 100, weapon: 'rifle',
      ai, t: 0, think: 0, cd: 0, respawn: 0, wp: null, strafe: 1, target: null, ...extra,
    };
  }

  _spawn() {
    const R = this.rng;
    const c = { x: this.w / 2, y: this.h / 2 };
    const me = this._mk(0, 'YOU', 1, c.x, c.y, 'player');
    this.players.push(me);
    this.self = me;
    let n = 1;
    const sc = this.scenario;
    if (sc === 'skirmish') {
      for (let i = 0; i < this.botCount; i++) {
        const team = i < 2 ? 1 : 2 + ((i - 2) % 2);
        const p = this._randomFree(18, 10);
        const b = this._mk(n++, NAMES[i % NAMES.length], team, p.x, p.y, 'brawler');
        b.weapon = ['rifle', 'smg', 'pistol', 'rifle'][i % 4];
        this.players.push(b);
      }
    } else if (sc === 'range') {
      for (let i = 0; i < 6; i++) {
        const ang = -0.9 + (i / 5) * 1.8 - Math.PI / 2;
        const dist = 330 + (i % 3) * 140;
        const b = this._mk(n++, 'Dummy ' + (i + 1), 2, c.x + Math.cos(ang) * dist, c.y + Math.sin(ang) * dist, 'sine');
        Object.assign(b, { bx: b.x, by: b.y, ax: ang + Math.PI / 2, amp: 120 + R() * 140, period: 3 + R() * 4, ph: R() * TAU });
        this.players.push(b);
      }
    } else if (sc === 'strafe') {
      for (let i = 0; i < 6; i++) {
        const b = this._mk(n++, `Strafe ${60 + i * 40}`, 2, c.x - 260 + i * 6, c.y - 420 + i * 150, 'bounce');
        Object.assign(b, { bx: c.x, dir: i % 2 ? -1 : 1, speed: 60 + i * 40, range: 300 });
        b.x = c.x + (i % 2 ? 100 : -100);
        b.y = c.y - 450 + i * 180;
        this.players.push(b);
      }
      this.players.push(this._mk(n++, 'Ally', 1, c.x + 60, c.y + 60, 'idle'));
    } else {
      for (let i = 0; i < Math.min(this.botCount, 10); i++) {
        const p = this._randomFree(18, 14);
        const b = this._mk(n++, NAMES[i % NAMES.length], i % 4 === 0 ? 1 : 2, p.x, p.y, 'patrol');
        b.speed = 80 + R() * 50;
        this.players.push(b);
      }
    }
    me.hp = 100;
  }

  _spawnLoot() {
    const kinds = ['gun', 'ammo', 'heal', 'armor', 'scope'];
    const names = { gun: 'Weapon', ammo: 'Ammo', heal: 'Medkit', armor: 'Armor', scope: 'Scope' };
    const weights = [0.42, 0.28, 0.16, 0.10, 0.04];
    for (let i = 0; i < 22; i++) {
      const p = this._randomFree(14, 6);
      const k = kinds[Math.floor(this.rng() * kinds.length)];
      let roll = this.rng();
      let rarity = 0;
      for (let j = 0; j < weights.length; j++) {
        roll -= weights[j];
        if (roll <= 0) {
          rarity = j;
          break;
        }
      }
      this.loot.push({ id: 500 + i, x: Math.round(p.x), y: Math.round(p.y), kind: k, rarity, name: names[k] });
    }
  }

  // ---------------------------------------------------------------- simulation
  /** Advance by dt seconds using a fixed 60 Hz internal step. */
  advance(dt, input) {
    this.accum = Math.min(this.accum + dt, 0.25);
    const STEP = 1 / 60;
    while (this.accum >= STEP) {
      this.step(STEP, input);
      this.accum -= STEP;
    }
  }

  step(dt, input) {
    this.t += dt;
    const me = this.self;
    if (input) {
      if (input.weapon) this.selfWeapon = input.weapon;
      if (input.cursor) this.lastCursor = input.cursor;
      let mx = input.moveX || 0;
      let my = input.moveY || 0;
      const m = Math.hypot(mx, my);
      if (m > 0) {
        mx /= m;
        my /= m;
      }
      const tvx = mx * 175;
      const tvy = my * 175;
      const k = 1 - Math.exp(-dt * 14);
      me.vx += (tvx - me.vx) * k;
      me.vy += (tvy - me.vy) * k;
      if (Number.isFinite(input.angle)) me.angle = input.angle;
      this.selfCd -= dt;
      if (input.fire && this.selfCd <= 0) {
        this._fire(me, me.angle, this.selfWeapon, this.selfWeapon.spread, this.selfWeapon.damage, this.selfWeapon.bulletSpeed, this.selfWeapon.range);
        this.selfCd = 1 / this.selfWeapon.fireRate;
      }
    } else {
      me.vx *= 0.9;
      me.vy *= 0.9;
    }
    me.hp = Math.min(100, me.hp + 20 * dt);

    for (const p of this.players) {
      if (p === me) {
        this._move(p, dt);
        continue;
      }
      if (p.hp <= 0) {
        p.respawn -= dt;
        if (p.respawn <= 0) {
          const s = this._randomFree(18, 10);
          p.x = s.x;
          p.y = s.y;
          p.hp = p.maxHp;
          if (p.bx !== undefined) {
            p.bx = s.x;
            p.by = s.y;
          }
        }
        continue;
      }
      this._ai(p, dt);
    }
    this._bullets(dt);
  }

  _ai(p, dt) {
    p.t += dt;
    const me = this.self;
    switch (p.ai) {
      case 'sine': {
        const ph = (TAU * p.t) / p.period + p.ph;
        const nx = p.bx + Math.cos(p.ax) * p.amp * Math.sin(ph);
        const ny = p.by + Math.sin(p.ax) * p.amp * Math.sin(ph);
        p.vx = (nx - p.x) / dt;
        p.vy = (ny - p.y) / dt;
        p.x = nx;
        p.y = ny;
        p.angle = Math.atan2(me.y - p.y, me.x - p.x);
        return;
      }
      case 'bounce': {
        p.x += p.dir * p.speed * dt;
        if (Math.abs(p.x - p.bx) > p.range) {
          p.dir *= -1;
          p.x = clamp(p.x, p.bx - p.range, p.bx + p.range);
        }
        p.vx = p.dir * p.speed;
        p.vy = 0;
        p.angle = Math.atan2(me.y - p.y, me.x - p.x);
        return;
      }
      case 'patrol': {
        if (!p.wp || Math.hypot(p.wp.x - p.x, p.wp.y - p.y) < 20 || (p.think -= dt) <= 0) {
          p.wp = this._randomFree(18, 14);
          p.think = 4 + this.rng() * 4;
        }
        const a = Math.atan2(p.wp.y - p.y, p.wp.x - p.x);
        p.vx = Math.cos(a) * p.speed;
        p.vy = Math.sin(a) * p.speed;
        p.angle = lerpAngle(p.angle, a, Math.min(1, dt * 6));
        this._move(p, dt);
        return;
      }
      case 'brawler':
        return this._brawler(p, dt);
      default:
        p.vx = p.vy = 0;
    }
  }

  _brawler(p, dt) {
    const W = WEAPONS[p.weapon];
    p.cd -= dt;
    p.think -= dt;
    if (p.think <= 0) {
      p.think = 0.5 + this.rng() * 1.1;
      p.strafe = this.rng() < 0.5 ? -1 : 1;
      let best = null;
      let bd = 650;
      for (const q of this.players) {
        if (q === p || q.hp <= 0 || q.team === p.team) continue;
        const d = Math.hypot(q.x - p.x, q.y - p.y);
        if (d < bd && !raycast(p.x, p.y, q.x - p.x, q.y - p.y, 1, this.obstacles, 'bullets')) {
          best = q;
          bd = d;
        }
      }
      p.target = best;
      if (!best) p.wp = this._randomFree(18, 14);
    }
    const tg = p.target;
    if (tg && tg.hp > 0) {
      const dx = tg.x - p.x;
      const dy = tg.y - p.y;
      const d = Math.hypot(dx, dy) || 1;
      const a = Math.atan2(dy, dx);
      p.angle = lerpAngle(p.angle, a, Math.min(1, dt * 7));
      const want = 330;
      const fwd = d > want + 60 ? 1 : d < want - 80 ? -1 : 0;
      const sp = 125;
      p.vx = (Math.cos(a) * fwd + -Math.sin(a) * p.strafe * 0.8) * sp;
      p.vy = (Math.sin(a) * fwd + Math.cos(a) * p.strafe * 0.8) * sp;
      if (p.cd <= 0 && Math.abs(angleDiff(p.angle, a)) < 0.12 && d < W.range) {
        this._fire(p, p.angle, W, W.spread + 4, 6, W.bulletSpeed, W.range);
        p.cd = 1 / W.fireRate + 0.25;
      }
    } else if (p.wp) {
      const a = Math.atan2(p.wp.y - p.y, p.wp.x - p.x);
      p.angle = lerpAngle(p.angle, a, Math.min(1, dt * 5));
      p.vx = Math.cos(a) * 115;
      p.vy = Math.sin(a) * 115;
      if (Math.hypot(p.wp.x - p.x, p.wp.y - p.y) < 25) p.wp = null;
    } else {
      p.vx = p.vy = 0;
    }
    this._move(p, dt);
  }

  _move(p, dt) {
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    for (let it = 0; it < 3; it++) {
      for (const o of this.obstacles) {
        if (!o.move) continue;
        const res =
          o.type === 'circle'
            ? circleCirclePush(p.x, p.y, p.r, o.x, o.y, o.r)
            : p.x + p.r < o.x || p.x - p.r > o.x + o.w || p.y + p.r < o.y || p.y - p.r > o.y + o.h
              ? null
              : circleRectPush(p.x, p.y, p.r, o.x, o.y, o.w, o.h);
        if (res && res.pen > 0) {
          p.x += res.nx * res.pen;
          p.y += res.ny * res.pen;
        }
      }
    }
    p.x = clamp(p.x, p.r, this.w - p.r);
    p.y = clamp(p.y, p.r, this.h - p.r);
  }

  _fire(p, angle, weapon, spreadDeg, dmg, speed, range) {
    const a = angle + (this.rng() * 2 - 1) * rad(spreadDeg);
    const c = Math.cos(a);
    const s = Math.sin(a);
    const m = p.r + 3;
    const b = { id: this.nid++, x: p.x + c * m, y: p.y + s * m, vx: c * speed, vy: s * speed, owner: p.id, team: p.team, left: range, dmg };
    this.bullets.push(b);
    this.events.push({ type: 'shot', t: this.t, ownerId: p.id, bulletId: b.id, x: b.x, y: b.y, angle: a });
  }

  _bullets(dt) {
    const keep = [];
    for (const b of this.bullets) {
      const dx = b.vx * dt;
      const dy = b.vy * dt;
      const len = Math.hypot(dx, dy);
      let bestT = 1;
      let kind = null;
      let ref = null;
      const wall = raycast(b.x, b.y, dx, dy, 1, this.obstacles, 'bullets');
      if (wall) {
        bestT = wall.t;
        kind = 'obstacle';
        ref = wall.obstacle;
      }
      for (const q of this.players) {
        if (q.hp <= 0 || q.id === b.owner || q.team === b.team) continue;
        const r = rayCircle(b.x, b.y, dx, dy, q.x, q.y, q.r + 1.5);
        if (!r || r[1] < 0) continue;
        const t = Math.max(r[0], 0);
        if (t <= bestT) {
          bestT = t;
          kind = 'player';
          ref = q;
        }
      }
      if (kind) {
        const x = b.x + dx * bestT;
        const y = b.y + dy * bestT;
        if (kind === 'player') {
          ref.hp -= b.dmg;
          this.events.push({ type: 'hit', t: this.t, ownerId: b.owner, targetId: ref.id, bulletId: b.id, x, y, dmg: b.dmg, kind: 'player' });
          if (ref.hp <= 0) {
            if (ref === this.self) ref.hp = 1;
            else {
              ref.respawn = 2.5;
              this.events.push({ type: 'kill', t: this.t, ownerId: b.owner, targetId: ref.id, x, y });
            }
          }
        } else {
          this.events.push({ type: 'impact', t: this.t, ownerId: b.owner, bulletId: b.id, obstacleId: ref.id, x, y, kind: ref.kind });
        }
        continue;
      }
      b.x += dx;
      b.y += dy;
      b.left -= len;
      if (b.left <= 0) {
        this.events.push({ type: 'expire', t: this.t, ownerId: b.owner, bulletId: b.id, x: b.x, y: b.y });
        continue;
      }
      keep.push(b);
    }
    this.bullets = keep;
  }

  // ---------------------------------------------------------------- snapshot
  snapshot() {
    const r2 = (v) => Math.round(v * 100) / 100;
    const r3 = (v) => Math.round(v * 1000) / 1000;
    const pub = (p) => ({
      id: p.id, name: p.name, team: p.team, x: r2(p.x), y: r2(p.y), vx: r2(p.vx), vy: r2(p.vy), angle: r3(p.angle),
      r: p.r, hp: Math.round(p.hp), maxHp: p.maxHp,
    });
    const me = this.self;
    const w = this.selfWeapon;
    const self = {
      ...pub(me),
      weapon: { name: w.name, bulletSpeed: w.bulletSpeed, range: w.range, spread: w.spread, fireRate: w.fireRate },
      cursor: this.lastCursor ? { x: r2(this.lastCursor.x), y: r2(this.lastCursor.y) } : undefined,
    };
    const players = [];
    for (const p of this.players) {
      if (p === me || p.hp <= 0) continue;
      players.push({ ...pub(p), weapon: WEAPONS[p.weapon] ? WEAPONS[p.weapon].name : 'Fists' });
    }
    return {
      seq: ++this.seq,
      t: r3(this.t),
      mapRev: this.mapRev,
      world: { w: this.w, h: this.h },
      meta: { unitsPerMeter: this.upm, source: 'demo', scenario: this.scenario },
      self,
      players,
      obstacles: this.obstacles,
      loot: this.loot,
      bullets: this.bullets.map((b) => ({ id: b.id, x: r2(b.x), y: r2(b.y), vx: b.vx, vy: b.vy, owner: b.owner })),
      events: this.events.splice(0),
    };
  }
}
