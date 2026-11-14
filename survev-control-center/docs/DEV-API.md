# Developer API (protocol `scc-dev` v1)

How **your own game's development build** feeds the Control Center overlay. Read-only: the extension never
sends input to your game and never makes network requests.

## Safety model (enforced by the extension)

| Rule | Where it is enforced |
|---|---|
| Runs only on `localhost`, `127.0.0.1`, `*.localhost`, `*.local` | `manifest.json` match patterns **and** `src/adapters/host-policy.js` |
| Public hosts (incl. `survev.io`) are refused | `host-policy.js` (private-network allowlist + explicit block list) |
| Page must declare `env: "development"` or `"private-test"` | `src/adapters/dev-adapter.js` |
| Page must present the session token configured in **Settings → Developer authorization** | `dev-adapter.js` (constant-time compare) |
| Same-window, same-origin messages only; nonce per handshake | `dev-adapter.js` |
| Every frame is sanitized (finite numbers, capped arrays, truncated strings) | `src/core/schema.js` |
| Dormant until authorized (nothing injected into unrelated localhost apps) | `src/content/main.js` |

Your **server** should hand the page the token only for authenticated developer sessions (e.g. injected into
the dev build's HTML, or returned by an authenticated endpoint). The extension has no way to verify *how* the
page got the token — treat it as a shared secret between your dev server and the person running the extension.

## Handshake

```
extension → page   { source:'scc-extension', v:1, type:'hello', nonce }
page → extension   { source:'scc-dev-api',  v:1, type:'authorize', nonce, env, token, sessionId, app }
extension → page   { source:'scc-extension', v:1, type:'ack', sessionId }       // authorized
page → extension   { source:'scc-dev-api',  v:1, type:'map', map:{ world, meta, obstacles } }   // static geometry, once
page → extension   { source:'scc-dev-api',  v:1, type:'snapshot', frame }        // every rendered frame
page → extension   { source:'scc-dev-api',  v:1, type:'bye' }                    // optional
extension → page   { source:'scc-extension', v:1, type:'revoke' }                // on detach
```

All messages use `window.postMessage(msg, location.origin)`.
`dev-api-example/scc-dev-api.js` implements the page side — copy it into your build.

## Snapshot (`frame`)

World units are yours (set `meta.unitsPerMeter`); angles are radians; `y` grows downward.

```js
{
  world:  { w, h },
  meta:   { unitsPerMeter: 10 },
  camera: { x, y, scale,                       // world point at the centre of the game view, and px-per-unit
            view: { left, top, width, height } },  // the game canvas rect in client pixels (omit = full window)
  self:   { id, name, team, x, y, vx, vy, angle, r, hp, maxHp,
            weapon: { name, bulletSpeed, range, spread, fireRate },   // spread = half-angle in degrees
            cursor: { x, y } },                                        // optional: world position of the mouse
  players:[ { id, name, team, x, y, vx, vy, angle, r, hp, maxHp, weapon: 'AK' } ],   // everyone except self
  loot:   [ { id, x, y, kind: 'gun|ammo|heal|armor|scope', rarity: 0-4, name } ],
  bullets:[ { id, x, y, vx, vy, owner } ],
  events: [ { type:'shot|hit|impact|expire|kill', ownerId, targetId, bulletId, x, y, dmg } ]   // events since last frame
}
```

`map.obstacles` (or `frame.obstacles`):

```js
{ id, type:'rect', x, y, w, h,  kind:'wall', sight:true, bullets:true, move:true }   // x,y = top-left
{ id, type:'circle', x, y, r,   kind:'tree', sight:false, bullets:true, move:true }
```

The three flags are what make the diagnostics meaningful: *sight* (blocks line of sight), *bullets* (stops
projectiles), *move* (blocks movement). Glass = `sight:false, bullets:true, move:true`; bush = `sight:true, bullets:false, move:false`.

## What you need to expose from your game

| Needed | Used for |
|---|---|
| Local player id, position, velocity, facing angle, team, hp | LOS origin, distance labels, team colours |
| Other players' id, name, team, position, velocity, angle, hp, weapon | boxes, health, prediction, off-screen arrows |
| Camera centre + zoom (+ canvas rect) | world → screen mapping for the overlay |
| Static obstacles with sight / bullet / movement flags | occlusion, LOS polygon, collision debug |
| Weapon bullet speed, range, spread | projectile prediction, trajectory, hit chance |
| Bullet/shot/hit events (optional) | accuracy diagnostics, impact markers |
| Loot positions + rarity (optional) | loot markers |

Axis-aligned rectangles and circles only (no rotated rectangles yet).

## Testing without your game

```bash
cd survev-control-center
python3 -m http.server 8080 --bind 127.0.0.1
# open http://localhost:8080/dev-api-example/  → the overlay attaches by itself
```
The example page deliberately sends a snapshot every frame and uses the default token `scc-dev-token`.
