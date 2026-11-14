// Replay recording / playback. Works with any snapshot source (demo, dev API).
// Static obstacle sets are stored once per `mapRev` instead of once per frame.

import { lerp, lerpAngle } from '../core/math.js';
import { sanitizeSnapshot, sanitizeObstacles } from '../core/schema.js';

export const REPLAY_FORMAT = 'scc-replay';

export class Recorder {
  constructor({ maxFrames = 3600, hz = 30 } = {}) {
    this.maxFrames = maxFrames;
    this.interval = 1 / hz;
    this.clear();
  }

  clear() {
    this.frames = [];
    this.maps = {};
    this.recording = false;
    this.next = 0;
    this.source = '';
  }

  start() {
    this.clear();
    this.recording = true;
  }

  stop() {
    this.recording = false;
  }

  capture(snap) {
    if (!this.recording || snap.t < this.next - 1e-3) return;
    this.next = snap.t + this.interval;
    if (!this.maps[snap.mapRev]) this.maps[snap.mapRev] = snap.obstacles;
    this.source = snap.meta.source;
    const { obstacles, ...rest } = snap;
    this.frames.push(structuredClone(rest));
    if (this.frames.length >= this.maxFrames) this.stop();
  }

  get duration() {
    return this.frames.length > 1 ? this.frames[this.frames.length - 1].t - this.frames[0].t : 0;
  }

  serialize() {
    return {
      format: REPLAY_FORMAT,
      version: 1,
      createdAt: new Date().toISOString(),
      meta: { source: this.source, frames: this.frames.length, duration: this.duration },
      maps: this.maps,
      frames: this.frames,
    };
  }

  /** Load a parsed replay file. Throws a readable Error on invalid input. */
  load(data) {
    if (!data || data.format !== REPLAY_FORMAT || !Array.isArray(data.frames)) throw new Error('Not a Control Center replay file');
    if (data.frames.length < 2) throw new Error('Replay has fewer than 2 frames');
    if (data.frames.length > 20000) throw new Error('Replay is too long (limit 20000 frames)');
    const maps = {};
    for (const k of Object.keys(data.maps || {})) maps[k] = sanitizeObstacles(data.maps[k]);
    const frames = [];
    for (const f of data.frames) {
      const s = sanitizeSnapshot(f, { skipObstacles: true, source: 'replay' });
      if (s) frames.push(s);
    }
    if (frames.length < 2) throw new Error('Replay contains no valid frames');
    this.clear();
    this.maps = maps;
    this.frames = frames;
  }
}

const lerpEnt = (a, b, f) => ({
  ...a,
  x: lerp(a.x, b.x, f),
  y: lerp(a.y, b.y, f),
  vx: lerp(a.vx, b.vx, f),
  vy: lerp(a.vy, b.vy, f),
  angle: lerpAngle(a.angle, b.angle, f),
  hp: lerp(a.hp, b.hp, f),
});

export class ReplaySource {
  constructor(frames, maps) {
    this.kind = 'replay';
    this.interactive = false;
    this.label = 'Replay';
    this.frames = frames;
    this.maps = maps;
    this.t0 = frames[0].t;
    this.duration = frames[frames.length - 1].t - this.t0;
    this.pos = 0;
    this.playing = true;
    this.loop = true;
    this.speed = 1;
    this.seq = 0;
    this.lastIdx = -1;
  }

  get fraction() {
    return this.duration > 0 ? this.pos / this.duration : 0;
  }

  seek(fraction) {
    this.pos = Math.min(Math.max(fraction, 0), 1) * this.duration;
    this.lastIdx = this._index(this.pos) - 1;
  }

  _index(pos) {
    const target = this.t0 + pos;
    let lo = 0;
    let hi = this.frames.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.frames[mid].t <= target) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  update(dt) {
    if (this.playing) {
      this.pos += dt * this.speed;
      if (this.pos >= this.duration) {
        if (this.loop) {
          this.pos = 0;
          this.lastIdx = -1;
        } else {
          this.pos = this.duration;
          this.playing = false;
        }
      }
    }
    const i = this._index(this.pos);
    const a = this.frames[i];
    const b = this.frames[Math.min(i + 1, this.frames.length - 1)];
    const span = b.t - a.t;
    const f = span > 1e-6 ? Math.min(1, Math.max(0, (this.t0 + this.pos - a.t) / span)) : 0;
    const bmap = new Map();
    for (const p of b.players) bmap.set(p.id, p);
    const events = [];
    if (this.playing) {
      for (let k = this.lastIdx + 1; k <= i; k++) if (k >= 0) events.push(...this.frames[k].events);
    }
    this.lastIdx = i;
    return {
      ...a,
      seq: ++this.seq,
      t: lerp(a.t, b.t, f),
      obstacles: this.maps[a.mapRev] || [],
      camera: { ...a.camera, x: lerp(a.camera.x, b.camera.x, f), y: lerp(a.camera.y, b.camera.y, f), scale: lerp(a.camera.scale, b.camera.scale, f) },
      self: { ...lerpEnt(a.self, b.self, f), weapon: a.self.weapon, cursor: a.self.cursor },
      players: a.players.map((p) => {
        const q = bmap.get(p.id);
        return q ? lerpEnt(p, q, f) : p;
      }),
      events,
    };
  }
}
