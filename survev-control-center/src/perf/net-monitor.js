// Network diagnostics. Observational only:
//   * browser connectivity events (online/offline) and the Network Information API (browser estimate);
//   * game-reported values (ping, WebSocket state, disconnects) when the dev API publishes them;
//   * an OPTIONAL HTTP round-trip probe to a same-origin endpoint you authorize (off by default).
// Never touches, wraps, delays or forges the game's own traffic.

const MAX_SAMPLES = 60;

export class NetMonitor {
  constructor({ origin, allowProbe }) {
    this.origin = origin;
    this.allowProbe = allowProbe;
    this.samples = [];
    this.failures = 0;
    this.attempts = 0;
    this.interruptions = [];
    this.online = navigator.onLine;
    this.game = null;
    this.gameDisconnects = 0;
    this.lastWs = null;
    this.timer = 0;
    this.probing = false;
    this.cfg = null;
    this._online = () => this._setOnline(true);
    this._offline = () => this._setOnline(false);
    this._conn = () => (this.connChanged = Date.now());
    this._vis = () => {
      if (!document.hidden && this.probing) this._schedule(250);
    };
  }

  start() {
    window.addEventListener('online', this._online);
    window.addEventListener('offline', this._offline);
    document.addEventListener('visibilitychange', this._vis);
    const c = navigator.connection;
    if (c && c.addEventListener) c.addEventListener('change', this._conn);
  }

  stop() {
    window.removeEventListener('online', this._online);
    window.removeEventListener('offline', this._offline);
    document.removeEventListener('visibilitychange', this._vis);
    const c = navigator.connection;
    if (c && c.removeEventListener) c.removeEventListener('change', this._conn);
    this.setProbe(null);
  }

  _setOnline(on) {
    if (on === this.online) return;
    this.online = on;
    if (!on) this.interruptions.push({ kind: 'offline', at: Date.now(), end: null });
    else {
      const last = this.interruptions[this.interruptions.length - 1];
      if (last && last.end == null) last.end = Date.now();
    }
    if (this.interruptions.length > 50) this.interruptions.shift();
  }

  /** Validate an endpoint: must resolve to the page's own origin. */
  resolveEndpoint(path) {
    if (!this.allowProbe || !path) return null;
    try {
      const u = new URL(path, this.origin);
      return u.origin === this.origin ? u.href : null;
    } catch (_) {
      return null;
    }
  }

  /** cfg = { probe, endpoint, intervalSec } or null to stop. */
  setProbe(cfg) {
    clearTimeout(this.timer);
    this.timer = 0;
    const url = cfg && cfg.probe ? this.resolveEndpoint(cfg.endpoint) : null;
    this.probing = !!url;
    this.cfg = url ? { url, interval: Math.max(2, Math.min(60, cfg.intervalSec)) * 1000 } : null;
    if (this.probing) this._schedule(200);
    return url;
  }

  _schedule(ms) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this._probe(), ms);
  }

  async _probe() {
    if (!this.probing) return;
    if (document.hidden) return; // resumes on visibilitychange
    const ctl = new AbortController();
    const to = setTimeout(() => ctl.abort(), 3000);
    const t0 = performance.now();
    this.attempts++;
    try {
      const r = await fetch(this.cfg.url, { method: 'HEAD', cache: 'no-store', credentials: 'same-origin', signal: ctl.signal });
      const rtt = performance.now() - t0;
      if (r.status >= 500) throw new Error('HTTP ' + r.status);
      this.samples.push({ at: Date.now(), rtt });
      if (this.samples.length > MAX_SAMPLES) this.samples.shift();
      this.failStreak = 0;
    } catch (_) {
      this.failures++;
      this.failStreak = (this.failStreak || 0) + 1;
      if (this.failStreak === 2) this.interruptions.push({ kind: 'endpoint unreachable', at: Date.now(), end: null });
    } finally {
      clearTimeout(to);
    }
    if (this.probing) this._schedule(this.cfg.interval);
  }

  /** Values published by the game through the dev API (snapshot.net). */
  ingestGame(net) {
    if (!net) return;
    if (this.lastWs === 'open' && net.wsState && net.wsState !== 'open') {
      this.gameDisconnects++;
      this.interruptions.push({ kind: 'game WebSocket closed', at: Date.now(), end: null });
    }
    this.lastWs = net.wsState || this.lastWs;
    this.game = { ...net, at: Date.now() };
  }

  stats() {
    const rtts = this.samples.map((s) => s.rtt);
    const n = rtts.length;
    const avg = n ? rtts.reduce((a, b) => a + b, 0) / n : null;
    let jitter = null;
    if (n > 1) {
      let j = 0;
      for (let i = 1; i < n; i++) j += Math.abs(rtts[i] - rtts[i - 1]);
      jitter = j / (n - 1);
    }
    const c = navigator.connection;
    const conn = c ? { type: c.effectiveType || null, rtt: Number.isFinite(c.rtt) ? c.rtt : null, downlink: Number.isFinite(c.downlink) ? c.downlink : null, saveData: !!c.saveData } : null;
    const loss = this.attempts ? this.failures / this.attempts : null;
    const gameFresh = this.game && Date.now() - this.game.at < 5000 ? this.game : null;
    const gameDisc = gameFresh && Number.isFinite(gameFresh.disconnects) ? gameFresh.disconnects : this.gameDisconnects;
    const recent = this.interruptions.filter((i) => Date.now() - i.at < 10 * 60000).length;

    const warnings = [];
    if (!this.online) warnings.push('Browser reports the device is offline.');
    if (gameFresh && gameFresh.rttMs > 150) warnings.push(`High game ping (${Math.round(gameFresh.rttMs)} ms): expect delayed hits and rubber-banding; this is not an FPS problem.`);
    if (avg != null && avg > 150) warnings.push(`Endpoint round-trip averages ${Math.round(avg)} ms.`);
    if (jitter != null && jitter > 40) warnings.push(`Unstable latency (jitter ${Math.round(jitter)} ms) can feel like stutter even at high FPS.`);
    if (loss != null && this.attempts >= 5 && loss > 0.05) warnings.push(`${Math.round(loss * 100)}% of latency probes failed.`);
    if (conn && conn.saveData) warnings.push('Data Saver is on in the browser.');
    if (conn && /^(slow-2g|2g|3g)$/.test(conn.type || '')) warnings.push(`Browser estimates a slow connection (${conn.type}).`);
    if (gameDisc > 0) warnings.push(`Game connection dropped ${gameDisc}× this session.`);

    let stability = 'No data';
    const haveData = n >= 3 || gameFresh || this.interruptions.length || !this.online;
    if (haveData) {
      if (!this.online || recent >= 3 || (loss != null && loss > 0.1)) stability = 'Unstable';
      else if (recent > 0 || (jitter != null && jitter > 25) || (loss != null && loss > 0.02)) stability = 'Fair';
      else stability = 'Stable';
    }
    return {
      online: this.online,
      conn,
      probe: this.probing ? { url: this.cfg.url, n, last: n ? rtts[n - 1] : null, avg, min: n ? Math.min(...rtts) : null, max: n ? Math.max(...rtts) : null, jitter, loss, attempts: this.attempts } : null,
      game: gameFresh,
      gameDisconnects: gameDisc,
      interruptions: this.interruptions.length,
      recentInterruptions: recent,
      stability,
      warnings,
    };
  }
}
