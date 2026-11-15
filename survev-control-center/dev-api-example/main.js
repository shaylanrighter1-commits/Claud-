// A tiny stand-in "game" (drawn with plain shapes) that exposes its state through the dev API.
// It reuses the project's synthetic World purely as a data source so you can see the whole flow work.
// In your own game, replace getMap()/getSnapshot() with reads from your real engine state.

import { World } from '../src/sim/world.js';
import { WEAPONS } from '../src/core/defaults.js';
import { SccDevApi } from './scc-dev-api.js';

// Must match Settings → Developer authorization → Session token in the extension (default shown).
const TOKEN = 'scc-dev-token';

const canvas = document.getElementById('cvs');
const ctx = canvas.getContext('2d');
const world = new World({ scenario: 'skirmish', seed: 11, bots: 8 });
const weapon = WEAPONS.rifle;
const cam = { x: world.self.x, y: world.self.y, scale: 1 };
const keys = new Set();
const mouse = { x: innerWidth / 2, y: innerHeight / 2, down: false };

// ---- settings: same wiring as the real client --------------------------------------------------------
// `.modal-settings-item > input:checkbox` change -> config.set(id, checked); highResTex -> location.reload().
// Read at load (texture tier) / "match start" (screenShake), exactly like the client.
const CONFIG_KEY = 'example_config';
const config = { highResTex: true, screenShake: true, interpolation: true, localRotation: true, ...JSON.parse(localStorage.getItem(CONFIG_KEY) || '{}') };
for (const id of Object.keys(config)) document.getElementById(id).checked = !!config[id];
document.querySelectorAll('.modal-settings-item > input[type=checkbox]').forEach((el) =>
  el.addEventListener('change', () => {
    config[el.id] = el.checked;
    localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
    if (el.id === 'highResTex') location.reload();
  })
);
document.querySelectorAll('.modal-settings-text').forEach((t) => t.addEventListener('click', () => t.previousElementSibling.click()));
const shakeEnabled = config.screenShake; // applied at "match start" (page load) like the client

// Texture tier: high-res = large detailed tile (real extra fill/sampling work), low-res = small tile.
function makeTile(size) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  g.fillStyle = '#12151a';
  g.fillRect(0, 0, size, size);
  const n = size === 1024 ? 2400 : 160;
  for (let i = 0; i < n; i++) {
    const r = ((i * 9301 + 49297) % 233280) / 233280;
    const r2 = ((i * 4253 + 1931) % 104729) / 104729;
    g.fillStyle = `rgba(${40 + r * 30},${55 + r2 * 30},${50 + r * 20},0.35)`;
    g.beginPath();
    g.arc(r * size, r2 * size, 2 + r2 * (size / 128), 0, Math.PI * 2);
    g.fill();
  }
  return c;
}
const tile = makeTile(config.highResTex ? 1024 : 256);
const tileScale = config.highResTex ? 0.5 : 2; // same on-screen size, different source resolution
let pattern = null;

// TEST ONLY: busy-waits N ms per frame to simulate a heavy frame, so the auto-optimizer / benchmark can be exercised.
const synth = document.getElementById('synthLoad');
const synthOut = document.getElementById('synthOut');
synth.value = new URLSearchParams(location.search).get('load') || 0;
const updSynth = () => (synthOut.textContent = `${synth.value} ms`);
synth.addEventListener('input', updSynth);
updSynth();
let shake = 0;

addEventListener('keydown', (e) => keys.add(e.code));
addEventListener('keyup', (e) => keys.delete(e.code));
addEventListener('mousemove', (e) => ((mouse.x = e.clientX), (mouse.y = e.clientY)));
addEventListener('mousedown', (e) => {
  if (!e.target.closest('#settings')) mouse.down = true;
});
addEventListener('mouseup', () => (mouse.down = false));

const api = new SccDevApi({
  token: TOKEN,
  env: 'development',
  sessionId: 'example-' + Math.random().toString(36).slice(2, 8),
  appName: 'dev-api-example',
  getMap: () => ({
    world: { w: world.w, h: world.h },
    meta: { unitsPerMeter: world.upm, source: 'example' },
    obstacles: world.obstacles,
  }),
  getSnapshot: () => {
    const s = world.snapshot();
    return {
      mapRev: 1,
      world: s.world,
      meta: s.meta,
      camera: { x: cam.x, y: cam.y, scale: cam.scale, view: { left: 0, top: 0, width: innerWidth, height: innerHeight } },
      self: s.self,
      players: s.players,
      loot: s.loot,
      bullets: s.bullets,
      events: s.events,
    };
  },
});
api.start();

function frame(last) {
  const now = performance.now();
  const dt = Math.min(0.05, (now - last) / 1000);
  const w = innerWidth;
  const h = innerHeight;
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w; // only resize when needed (resizing every frame reallocates the backing store)
    canvas.height = h;
  }
  const me = world.self;
  const angle = Math.atan2((mouse.y - h / 2) / cam.scale + cam.y - me.y, (mouse.x - w / 2) / cam.scale + cam.x - me.x);
  world.advance(dt, {
    moveX: (keys.has('KeyD') ? 1 : 0) - (keys.has('KeyA') ? 1 : 0),
    moveY: (keys.has('KeyS') ? 1 : 0) - (keys.has('KeyW') ? 1 : 0),
    angle,
    fire: mouse.down,
    weapon,
  });
  cam.x += (me.x - cam.x) * (1 - Math.exp(-dt * 10));
  cam.y += (me.y - cam.y) * (1 - Math.exp(-dt * 10));

  // --- the example game's own (deliberately plain) rendering ---
  if (shakeEnabled) for (const ev of world.events) if (ev.type === 'hit' && ev.targetId === me.id) shake = 6;
  shake *= 0.85;
  const ox = shake ? (Math.random() - 0.5) * shake : 0;
  const oy = shake ? (Math.random() - 0.5) * shake : 0;
  const sx = (x) => (x - cam.x) * cam.scale + w / 2 + ox;
  const sy = (y) => (y - cam.y) * cam.scale + h / 2 + oy;
  if (!pattern) pattern = ctx.createPattern(tile, 'repeat');
  ctx.save();
  ctx.translate(sx(0), sy(0));
  ctx.scale(tileScale * cam.scale, tileScale * cam.scale);
  ctx.fillStyle = pattern;
  ctx.fillRect(-sx(0) / (tileScale * cam.scale), -sy(0) / (tileScale * cam.scale), w / (tileScale * cam.scale), h / (tileScale * cam.scale));
  ctx.restore();
  ctx.fillStyle = '#2b303a';
  for (const o of world.obstacles) {
    if (o.kind === 'bush') ctx.fillStyle = '#1d4a35';
    else if (o.kind === 'glass') ctx.fillStyle = '#35597d';
    else ctx.fillStyle = '#2b303a';
    if (o.type === 'circle') {
      ctx.beginPath();
      ctx.arc(sx(o.x), sy(o.y), o.r * cam.scale, 0, Math.PI * 2);
      ctx.fill();
    } else ctx.fillRect(sx(o.x), sy(o.y), o.w * cam.scale, o.h * cam.scale);
  }
  for (const p of world.players) {
    if (p.hp <= 0) continue;
    ctx.beginPath();
    ctx.arc(sx(p.x), sy(p.y), p.r * cam.scale, 0, Math.PI * 2);
    ctx.fillStyle = p === me ? '#dfe6f7' : '#59606e';
    ctx.fill();
  }
  ctx.fillStyle = '#ffd37a';
  for (const b of world.bullets) ctx.fillRect(sx(b.x) - 1.5, sy(b.y) - 1.5, 3, 3);

  const load = Number(synth.value);
  if (load > 0) {
    const t = performance.now();
    while (performance.now() - t < load) {
      /* TEST ONLY synthetic heavy frame */
    }
  }
  api.tick(); // publish this frame to the Control Center (no-op until authorized)
  if (!api.authorized) world.events.length = 0; // nobody consumed them this frame
  requestAnimationFrame(() => frame(now));
}
requestAnimationFrame(() => frame(performance.now()));
