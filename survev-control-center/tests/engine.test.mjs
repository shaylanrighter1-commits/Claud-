// Run with:  node tests/engine.test.mjs
// Pure-logic tests (no browser needed): geometry, visibility, aiming, schema, replay, host policy.

import assert from 'node:assert/strict';
import { raycast, rayRect, circleRectPush, angleDiff, mulberry32 } from '../src/core/math.js';
import { interceptTime, leadPoint, hitProbability, smoothAngle, AimEngine } from '../src/engine/aiming.js';
import { computeVisibility, losFor, visibilityPolygon, getObsLists } from '../src/engine/visibility.js';
import { sanitizeSnapshot } from '../src/core/schema.js';
import { World } from '../src/sim/world.js';
import { Recorder, ReplaySource } from '../src/sim/replay.js';
import { evaluateLocation, isPrivateHost, classifyLocation } from '../src/adapters/host-policy.js';
import { parseIntLoose } from '../src/pass/pass-manager.js';
import { DEFAULT_CFG, WEAPONS } from '../src/core/defaults.js';
import { mergeDefaults } from '../src/core/state.js';
import { AimDiagnostics } from '../src/engine/diagnostics.js';
import { summarize, welch, tTwoSidedP, compareRuns, snapRefresh, rateRendering } from '../src/perf/stats.js';
import { GameSettings } from '../src/perf/game-settings.js';
import { NetMonitor } from '../src/perf/net-monitor.js';
import { PRESETS } from '../src/perf/presets.js';
import { sanitizeNet } from '../src/core/schema.js';

let passed = 0;
const test = (name, fn) => {
  try {
    fn();
    passed++;
    console.log('  ✓', name);
  } catch (e) {
    console.error('  ✗', name, '\n   ', e.message);
    process.exitCode = 1;
  }
};
const near = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} !~ ${b}`);

console.log('math');
test('rayRect hit / miss', () => {
  assert.deepEqual(rayRect(0, 0, 1, 0, 10, -5, 5, 10), [10, 15]);
  assert.equal(rayRect(0, 0, 0, 1, 10, -5, 5, 10), null);
});
test('raycast ignores obstacles containing origin and respects flags', () => {
  const obs = [
    { id: 1, type: 'rect', x: -5, y: -5, w: 10, h: 10, sight: true, bullets: true, move: true },
    { id: 2, type: 'rect', x: 20, y: -5, w: 5, h: 10, sight: false, bullets: true, move: true },
  ];
  assert.equal(raycast(0, 0, 1, 0, 100, obs, 'sight'), null);
  const hit = raycast(0, 0, 1, 0, 100, obs, 'bullets');
  assert.equal(hit.obstacle.id, 2);
  near(hit.t, 20);
});
test('circleRectPush resolves penetration', () => {
  const r = circleRectPush(8, 5, 4, 10, 0, 10, 10);
  assert.ok(r && r.pen > 0 && r.nx < 0);
});
test('angleDiff wraps', () => near(angleDiff(3.0, -3.0), 2 * Math.PI - 6.0));
test('mulberry32 deterministic', () => assert.equal(mulberry32(5)(), mulberry32(5)()));

console.log('aiming');
test('interceptTime: stationary target = distance / speed', () => near(interceptTime(100, 0, 0, 0, 50), 2));
test('interceptTime: crossing target leads correctly', () => {
  const t = interceptTime(100, 0, 0, 30, 50);
  // bullet must travel to (100, 30t) in time t: 50t = hypot(100, 30t)
  near(50 * t, Math.hypot(100, 30 * t), 1e-6);
});
test('interceptTime: faster-than-bullet receding target has no solution', () => assert.equal(interceptTime(100, 0, 80, 0, 50), null));
test('leadPoint respects strength=0 and maxLead', () => {
  const s = { x: 0, y: 0 };
  const t = { x: 100, y: 0, vx: 0, vy: 30 };
  const none = leadPoint(s, t, 50, { strength: 0, maxLead: 5, latency: 0 });
  near(none.y, 0);
  const capped = leadPoint(s, t, 50, { strength: 1, maxLead: 0.5, latency: 0 });
  near(capped.y, 15);
  assert.ok(capped.clamped);
});
test('hitProbability', () => {
  near(hitProbability(0, 0.1, 0), 1);
  near(hitProbability(0.5, 0.1, 0), 0);
  near(hitProbability(0, 0.1, 0.1), 1);
  near(hitProbability(0.1, 0.1, 0.1), 0.5);
});
test('smoothAngle: 0 smoothing snaps, high smoothing is slower, turn rate caps', () => {
  near(smoothAngle(0, 1, 0.016, 0, 540), 1);
  const slow = smoothAngle(0, 1, 0.016, 100, 5000);
  const fast = smoothAngle(0, 1, 0.016, 20, 5000);
  assert.ok(slow < fast && slow > 0);
  const capped = smoothAngle(0, 3, 0.016, 10, 90);
  assert.ok(capped <= (Math.PI / 2) * 0.016 + 1e-9);
});

console.log('visibility');
const wallWorld = () => ({
  self: { id: 0, x: 0, y: 0, r: 14, angle: 0, team: 1 },
  players: [
    { id: 1, x: 200, y: 0, r: 14, team: 2, hp: 100, maxHp: 100, vx: 0, vy: 0, angle: 0 },
    { id: 2, x: 0, y: 200, r: 14, team: 2, hp: 100, maxHp: 100, vx: 0, vy: 0, angle: 0 },
  ],
  obstacles: [{ id: 9, type: 'rect', kind: 'wall', x: 100, y: -50, w: 20, h: 100, sight: true, bullets: true, move: true }],
});
test('losFor: wall blocks, open ground does not, thickness measured', () => {
  const w = wallWorld();
  const l = getObsLists(w.obstacles);
  const a = losFor(w.self, w.players[0], l.sight);
  assert.equal(a.visible, false);
  assert.equal(a.occluder, 9);
  near(a.thickness, 20, 1e-6);
  assert.equal(losFor(w.self, w.players[1], l.sight).visible, true);
});
test('losFor: glass (sight=false) is see-through but blocks bullets', () => {
  const w = wallWorld();
  w.obstacles[0].sight = false;
  const l = getObsLists(w.obstacles);
  assert.equal(losFor(w.self, w.players[0], l.sight).visible, true);
  assert.ok(raycast(0, 0, 200, 0, 1, l.bullets, 'bullets'));
});
test('visibilityPolygon stops at walls and is bounded by range', () => {
  const w = wallWorld();
  const l = getObsLists(w.obstacles);
  const pts = visibilityPolygon(0, 0, l.sight, 300, 0, Math.PI * 2);
  let maxX = -Infinity;
  for (let i = 0; i < pts.length; i += 2) {
    maxX = Math.max(maxX, pts[i]);
    assert.ok(Math.hypot(pts[i], pts[i + 1]) <= 300 + 1e-6);
  }
  assert.ok(pts.length > 100);
});

console.log('aim engine');
const snapOf = (w) => ({
  t: 1,
  camera: { x: 0, y: 0, scale: 1 },
  meta: { unitsPerMeter: 10 },
  self: { ...w.self, weapon: WEAPONS.rifle },
  players: w.players,
  obstacles: w.obstacles,
});
test('target selection honours FOV, enemies-only and visibility', () => {
  const w = wallWorld();
  w.obstacles = [];
  w.players[1].team = 1; // ally
  const snap = snapOf(w);
  const cfg = JSON.parse(JSON.stringify(DEFAULT_CFG));
  const eng = new AimEngine();
  const vis = computeVisibility(snap, cfg, {});
  let a = eng.update(snap, cfg, { x: 200, y: 0 }, true, 0.016, true, vis);
  assert.equal(a.target, 1);
  assert.ok(a.locked);
  const ally = a.cands.find((c) => c.id === 2);
  assert.equal(ally.reason, 'friendly');
  a = eng.update(snap, cfg, { x: -400, y: 0 }, true, 0.016, true, vis);
  assert.equal(a.target, null); // cursor far from everyone -> outside FOV
  // visibility check rejects occluded target
  const w2 = wallWorld();
  const s2 = snapOf(w2);
  const v2 = computeVisibility(s2, cfg, {});
  a = new AimEngine().update(s2, cfg, { x: 200, y: 0 }, true, 0.016, true, v2);
  assert.equal(a.cands.find((c) => c.id === 1).reason, 'sight');
  cfg.aiming.visibilityCheck = 'off';
  a = new AimEngine().update(s2, cfg, { x: 200, y: 0 }, true, 0.016, true, v2);
  assert.equal(a.target, 1);
});
test('locked aim converges on lead point', () => {
  const w = wallWorld();
  w.obstacles = [];
  w.players[0].vy = 60;
  const snap = snapOf(w);
  const cfg = JSON.parse(JSON.stringify(DEFAULT_CFG));
  cfg.aiming.smoothing = 30;
  cfg.aiming.maxTurnRate = 1440;
  const eng = new AimEngine();
  const vis = computeVisibility(snap, cfg, {});
  let ang = 0;
  let a;
  for (let i = 0; i < 120; i++) {
    snap.self.angle = ang;
    a = eng.update(snap, cfg, { x: 200, y: 0 }, true, 1 / 60, true, vis);
    ang = a.appliedAngle;
  }
  assert.ok(a.lead.lead > 0);
  assert.ok(Math.abs(a.errorDeg) < 0.5, 'error ' + a.errorDeg);
  assert.ok(ang > 0, 'should aim ahead of the moving target');
});

console.log('schema / replay / policy');
test('sanitizeSnapshot rejects garbage and caps values', () => {
  assert.equal(sanitizeSnapshot(null), null);
  assert.equal(sanitizeSnapshot({ self: { id: 1, x: NaN, y: 0 } }), null);
  const s = sanitizeSnapshot({
    self: { id: 1, x: 5, y: 6, hp: 9999 },
    players: [{ id: 2, x: 1, y: 2, name: 'x'.repeat(100) }, { id: 1, x: 0, y: 0 }, { id: 3, x: Infinity, y: 0 }],
    obstacles: [{ type: 'rect', x: 0, y: 0, w: -4, h: 5 }, { type: 'circle', x: 1, y: 1, r: 3 }],
    camera: { x: 1, y: 2, scale: 9999 },
  });
  assert.equal(s.players.length, 1);
  assert.equal(s.players[0].name.length, 32);
  assert.equal(s.obstacles.length, 1);
  assert.equal(s.self.hp, 100);
  assert.equal(s.camera.scale, 20);
});
test('World is deterministic and produces valid snapshots', () => {
  const a = new World({ scenario: 'skirmish', seed: 3 });
  const b = new World({ scenario: 'skirmish', seed: 3 });
  for (let i = 0; i < 120; i++) {
    a.advance(1 / 60, { moveX: 1, angle: 0, fire: i % 10 === 0, weapon: WEAPONS.rifle });
    b.advance(1 / 60, { moveX: 1, angle: 0, fire: i % 10 === 0, weapon: WEAPONS.rifle });
  }
  const sa = a.snapshot();
  assert.deepEqual(JSON.parse(JSON.stringify(sa.players)), JSON.parse(JSON.stringify(b.snapshot().players)));
  const clean = sanitizeSnapshot(sa);
  assert.ok(clean && clean.players.length > 0 && clean.obstacles.length > 20);
  for (const sc of ['range', 'strafe', 'cover']) assert.ok(new World({ scenario: sc }).snapshot().players.length >= 5, sc);
});
test('Recorder + ReplaySource round-trip with interpolation', () => {
  const w = new World({ scenario: 'range', seed: 2 });
  const rec = new Recorder({ hz: 30 });
  rec.start();
  let cam = { x: 0, y: 0, scale: 1 };
  for (let i = 0; i < 180; i++) {
    w.advance(1 / 60, { moveX: 0, angle: 0, fire: false, weapon: WEAPONS.rifle });
    const s = w.snapshot();
    s.camera = cam;
    rec.capture(s);
  }
  assert.ok(rec.frames.length > 80);
  assert.ok(Object.keys(rec.maps).length === 1 && rec.frames[0].obstacles === undefined);
  const copy = JSON.parse(JSON.stringify(rec.serialize()));
  const rec2 = new Recorder();
  rec2.load(copy);
  const rp = new ReplaySource(rec2.frames, rec2.maps);
  rp.loop = false;
  const f = rp.update(0.5);
  assert.ok(f.obstacles.length > 0 && f.players.length > 0);
  rp.seek(0.5);
  rp.update(0);
  assert.equal(rp.playing, true);
  rp.update(rp.duration);
  assert.equal(rp.playing, false); // non-looping replay stops at the end
  assert.throws(() => rec2.load({ format: 'nope' }));
});
test('host policy: only loopback/private hosts, never public sites', () => {
  for (const h of ['localhost', '127.0.0.1', 'foo.localhost', 'box.local', '192.168.1.5', '10.0.0.2', '172.20.1.1', '[::1]']) assert.ok(isPrivateHost(h), h);
  for (const h of ['survev.io', 'www.survev.io', 'example.com', '172.32.0.1', '8.8.8.8', '192.169.0.1']) assert.ok(!isPrivateHost(h), h);
  assert.equal(evaluateLocation({ protocol: 'https:', hostname: 'survev.io' }).ok, false);
  assert.equal(evaluateLocation({ protocol: 'http:', hostname: 'localhost' }).ok, true);
  assert.equal(evaluateLocation({ protocol: 'file:', hostname: '' }).ok, false);
});
test('classifyLocation: survev.io is live-only, dev adapter stays private-only', () => {
  assert.equal(classifyLocation({ protocol: 'https:', hostname: 'survev.io' }), 'live');
  assert.equal(evaluateLocation({ protocol: 'https:', hostname: 'survev.io' }).ok, false);
  assert.equal(classifyLocation({ protocol: 'http:', hostname: 'localhost' }), 'private');
  assert.equal(classifyLocation({ protocol: 'https:', hostname: 'example.com' }), 'none');
  assert.equal(classifyLocation({ protocol: 'https:', hostname: 'evil-survev.io' }), 'none');
});
test('parseIntLoose reads game text', () => {
  assert.equal(parseIntLoose('1,250 XP'), 1250);
  assert.equal(parseIntLoose(' 12 '), 12);
  assert.equal(parseIntLoose(''), null);
});
test('mergeDefaults drops junk and fixes types', () => {
  const m = mergeDefaults(DEFAULT_CFG, { aiming: { fovRadius: 'big', smoothing: 20, bogus: 1 }, bogus: {} });
  assert.equal(m.aiming.fovRadius, DEFAULT_CFG.aiming.fovRadius);
  assert.equal(m.aiming.smoothing, 20);
  assert.equal(m.bogus, undefined);
});
test('AimDiagnostics counts shots/hits and resolves lead error', () => {
  const d = new AimDiagnostics();
  const self = { id: 0 };
  const tgt = { id: 5, name: 'T', x: 100, y: 0, r: 14 };
  const aim = { locked: true, active: true, target: 5, targetEnt: tgt, errorDeg: 2, lead: { x: 100, y: 10, tof: 0.2 }, hitProb: 0.5, acquireDelay: 0.1 };
  d.ingest({ t: 1, self, players: [tgt], meta: { unitsPerMeter: 10 }, events: [{ type: 'shot', ownerId: 0 }] }, aim, true);
  d.ingest({ t: 1.3, self, players: [tgt], meta: { unitsPerMeter: 10 }, events: [{ type: 'hit', ownerId: 0 }] }, aim, true);
  const s = d.stats();
  assert.equal(s.shots, 1);
  assert.equal(s.hits, 1);
  near(s.accuracy, 1);
  near(s.leadErr, 1, 1e-6); // 10 units = 1 m
  assert.equal(s.locks, 1);
});

console.log('performance');
test('summarize: steady 60 Hz', () => {
  const s = summarize(new Float32Array(600).fill(1000 / 60), 60);
  near(s.avgFps, 60, 1e-3);
  near(s.low1Fps, 60, 1e-3);
  assert.equal(s.stutters, 0);
  near(s.onTimePct, 1);
  assert.ok(s.stdev < 1e-3);
});
test('summarize: 1% low and stutters reflect hitches', () => {
  const ft = new Float32Array(1000).fill(16.67);
  for (let i = 0; i < 10; i++) ft[i * 100] = 100; // ten 100 ms hitches
  const s = summarize(ft, 60);
  near(s.low1Fps, 10, 1e-6);
  assert.equal(s.stutters, 10);
  assert.ok(s.avgFps < 60 && s.avgFps > 50);
  assert.ok(s.jitter > 1);
});
test('snapRefresh snaps to common rates', () => {
  assert.equal(snapRefresh(59.4), 60);
  assert.equal(snapRefresh(143), 144);
  assert.equal(snapRefresh(30.6), 30);
  assert.equal(snapRefresh(87), 90);
});
test('t-distribution p-values are correct', () => {
  near(tTwoSidedP(0, 10), 1, 1e-9);
  near(tTwoSidedP(2.228, 10), 0.05, 1e-3); // classic table value
  near(tTwoSidedP(1.96, 1e6), 0.05, 1e-3);
});
test('welch: identical vs clearly different samples', () => {
  const a = [60, 59, 61, 60, 60, 59, 61, 60, 60, 61];
  assert.ok(welch(a, a.slice()).p > 0.9);
  const b = a.map((v) => v + 10);
  assert.ok(welch(a, b).p < 0.001);
});
test('compareRuns claims improvement only when significant and >= 3%', () => {
  const mk = (fps, noise) => ({ avgFps: fps, low1Fps: fps * 0.8, stdev: 2, jitter: 1, stuttersPerMin: 1, perSecond: Array.from({ length: 15 }, (_, i) => fps + ((i % 3) - 1) * noise) });
  assert.equal(compareRuns(mk(50, 1), mk(60, 1)).verdict, 'improved');
  assert.equal(compareRuns(mk(60, 1), mk(50, 1)).verdict, 'worse');
  assert.equal(compareRuns(mk(60, 1), mk(60.5, 1)).verdict, 'no-change'); // significant-ish but < 3%
  assert.equal(compareRuns(mk(50, 15), mk(53, 15)).verdict, 'no-change'); // noisy
  assert.equal(compareRuns({ ...mk(50, 1), perSecond: [50] }, mk(60, 1)).verdict, 'insufficient');
});
test('rateRendering is bounded and ordered', () => {
  const good = rateRendering(summarize(new Float32Array(300).fill(16.67), 60), 60);
  const bad = rateRendering(summarize(new Float32Array(300).fill(50), 60), 60);
  assert.ok(good.score > bad.score && good.score <= 100 && bad.score >= 0);
});
test('GameSettings uses the checkbox like a user and respects reload / missing controls', () => {
  // Fake DOM that mirrors the client: click() toggles and fires the game's change handler.
  const log = [];
  const box = (id, checked) => ({ id, type: 'checkbox', checked, disabled: false, click() { this.checked = !this.checked; log.push(`${id}=${this.checked}`); } });
  const els = { highResTex: box('highResTex', true), screenShake: box('screenShake', true), interpolation: box('interpolation', true) };
  const gs = new GameSettings({ getElementById: (id) => els[id] || null });
  const r = gs.read();
  assert.equal(r.localRotation.present, false);
  assert.equal(gs.set('screenShake', false), 'changed');
  assert.equal(gs.set('screenShake', false), 'unchanged');
  assert.equal(gs.set('highResTex', false), 'needs-reload');
  assert.equal(els.highResTex.checked, true, 'reload-type setting must not change without consent');
  assert.equal(gs.set('highResTex', false, { allowReload: true }), 'changed');
  assert.equal(gs.set('localRotation', true), 'missing');
  assert.deepEqual(log, ['screenShake=false', 'highResTex=false']);
});
test('presets never touch interpolation or localRotation', () => {
  for (const p of Object.values(PRESETS)) {
    assert.ok(!('interpolation' in p.game) && !('localRotation' in p.game), p.id);
  }
});
test('NetMonitor only probes same-origin endpoints and only when allowed', () => {
  const n = new NetMonitor({ origin: 'http://localhost:3000', allowProbe: true });
  assert.equal(n.resolveEndpoint('/api/health'), 'http://localhost:3000/api/health');
  assert.equal(n.resolveEndpoint('https://example.com/ping'), null);
  assert.equal(n.resolveEndpoint('//evil.test/x'), null);
  assert.equal(new NetMonitor({ origin: 'chrome-extension://abc', allowProbe: false }).resolveEndpoint('/x'), null);
  const st = n.stats();
  assert.equal(st.probe, null);
  assert.equal(st.game, null); // never invented
});
test('sanitizeNet keeps only game-reported, valid values', () => {
  assert.equal(sanitizeNet(null), null);
  assert.equal(sanitizeNet({ rttMs: -5, wsState: 'weird' }), null);
  assert.deepEqual(sanitizeNet({ rttMs: 42.5, wsState: 'open', disconnects: 1.2 }), { rttMs: 42.5, wsState: 'open', disconnects: 1, reconnects: null, serverTickMs: null });
});

console.log(`\n${passed} tests passed${process.exitCode ? ' (with failures)' : ''}`);
