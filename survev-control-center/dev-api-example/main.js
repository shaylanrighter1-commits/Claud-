// A tiny stand-in "game" (drawn with plain shapes) that exposes its state through the dev API.
// It reuses the project's synthetic World purely as a data source so you can see the whole flow work.
// In your own game, replace getMap()/getSnapshot() with reads from your real engine state.

import { World } from '../src/sim/world.js';
import { WEAPONS } from '../src/core/defaults.js';
import { SccDevApi } from './scc-dev-api.js';

// Must match Settings → Developer authorization → Session token in the extension (default shown).
const TOKEN = 'scc-dev-token';

const canvas = document.getElementById('game');
const ctx = canvas.getContext('2d');
const world = new World({ scenario: 'skirmish', seed: 11, bots: 8 });
const weapon = WEAPONS.rifle;
const cam = { x: world.self.x, y: world.self.y, scale: 1 };
const keys = new Set();
const mouse = { x: innerWidth / 2, y: innerHeight / 2, down: false };

addEventListener('keydown', (e) => keys.add(e.code));
addEventListener('keyup', (e) => keys.delete(e.code));
addEventListener('mousemove', (e) => ((mouse.x = e.clientX), (mouse.y = e.clientY)));
addEventListener('mousedown', () => (mouse.down = true));
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
  const w = canvas.width = innerWidth;
  const h = canvas.height = innerHeight;
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
  const sx = (x) => (x - cam.x) * cam.scale + w / 2;
  const sy = (y) => (y - cam.y) * cam.scale + h / 2;
  ctx.fillStyle = '#12151a';
  ctx.fillRect(0, 0, w, h);
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

  api.tick(); // publish this frame to the Control Center (no-op until authorized)
  requestAnimationFrame(() => frame(now));
}
requestAnimationFrame(() => frame(performance.now()));
