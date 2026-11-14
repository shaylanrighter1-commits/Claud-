// Aim accuracy diagnostics: shots/hits, angular error history, prediction (lead) error, lock acquisition.

const SERIES = 240;

export class AimDiagnostics {
  constructor() {
    this.series = new Float32Array(SERIES);
    this.reset();
  }

  reset() {
    this.shots = 0;
    this.hits = 0;
    this.misses = 0;
    this.locks = 0;
    this.series.fill(NaN);
    this.head = 0;
    this.errSum = 0;
    this.errN = 0;
    this.acquireSum = 0;
    this.acquireN = 0;
    this.leadSum = 0;
    this.leadN = 0;
    this.pending = [];
    this.lastAcquire = null;
    this.lastActive = false;
    this.current = { errDeg: null, hitProb: null, target: null, targetDist: null, tofMs: null, locked: false };
  }

  /** Consume one frame. `fresh` = snapshot carries events that have not been seen yet. */
  ingest(snap, aim, fresh) {
    const self = snap.self;
    const upm = snap.meta.unitsPerMeter || 1;
    if (fresh) {
      for (const e of snap.events) {
        if (e.ownerId !== self.id) continue;
        if (e.type === 'shot') {
          this.shots++;
          if (aim && aim.locked && aim.lead) {
            this.pending.push({ targetId: aim.target, x: aim.lead.x, y: aim.lead.y, due: snap.t + aim.lead.tof });
            if (this.pending.length > 64) this.pending.shift();
          }
        } else if (e.type === 'hit') this.hits++;
        else if (e.type === 'impact' || e.type === 'expire') this.misses++;
      }
    }
    // Resolve prediction checks whose projectile flight time has elapsed.
    if (this.pending.length) {
      const keep = [];
      for (const p of this.pending) {
        if (snap.t < p.due) {
          keep.push(p);
          continue;
        }
        const tgt = snap.players.find((q) => q.id === p.targetId);
        if (tgt) {
          this.leadSum += Math.hypot(tgt.x - p.x, tgt.y - p.y) / upm;
          this.leadN++;
        }
      }
      this.pending = keep;
    }
    // Aim error sample.
    const locked = !!(aim && aim.locked && aim.errorDeg != null);
    const err = locked ? Math.abs(aim.errorDeg) : NaN;
    this.series[this.head] = err;
    this.head = (this.head + 1) % SERIES;
    if (locked) {
      this.errSum += err;
      this.errN++;
    }
    if (aim) {
      if (aim.acquireDelay != null && aim.acquireDelay !== this.lastAcquire) {
        this.lastAcquire = aim.acquireDelay;
        this.acquireSum += aim.acquireDelay;
        this.acquireN++;
        this.locks++;
      }
      if (!aim.active) this.lastAcquire = null;
    }
    const t = aim && aim.targetEnt;
    this.current = {
      errDeg: aim && aim.errorDeg != null ? aim.errorDeg : null,
      hitProb: aim ? aim.hitProb : null,
      target: t ? t.name : null,
      targetDist: t ? Math.hypot(t.x - self.x, t.y - self.y) / upm : null,
      tofMs: aim && aim.lead ? aim.lead.tof * 1000 : null,
      locked,
    };
  }

  /** Chronological copy of the error series (NaN = no lock). */
  getSeries() {
    const out = new Float32Array(SERIES);
    for (let i = 0; i < SERIES; i++) out[i] = this.series[(this.head + i) % SERIES];
    return out;
  }

  stats() {
    const done = this.hits + this.misses;
    return {
      shots: this.shots,
      hits: this.hits,
      misses: this.misses,
      accuracy: done ? this.hits / done : null,
      meanErr: this.errN ? this.errSum / this.errN : null,
      leadErr: this.leadN ? this.leadSum / this.leadN : null,
      acquire: this.acquireN ? (this.acquireSum / this.acquireN) * 1000 : null,
      locks: this.locks,
      ...this.current,
    };
  }
}
