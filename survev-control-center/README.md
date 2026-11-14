# SURVEV.IO | CONTROL CENTER

A Chrome (Manifest V3) **developer visualization & diagnostics suite** for a 2D top-down shooter you are building.
Matte-black UI, electric-blue accents, a toolbar popup and a draggable, minimizable in-game dashboard — all
settings synchronized through `chrome.storage.local`.

> **Scope.** This tool runs in three places only: its own **Demo Arena** (synthetic players), **replays** you
> recorded, and **private development sessions** on `localhost` / private-network hosts that explicitly
> authorize it. It does **not** connect to, read from, or modify public multiplayer games (Survev.io included —
> that host is blocked in code). It is read-only: it never injects input into a page.

## Install on macOS (Google Chrome)

1. **Unzip.** Double-click `survev-control-center-1.0.0.zip` in Finder. You get a folder named
   `survev-control-center` containing `manifest.json`. Move it somewhere permanent (e.g. `~/Documents/`) —
   Chrome loads the extension straight from that folder, so don't delete it afterwards.
2. In Chrome, type **`chrome://extensions`** in the address bar and press Return.
3. Switch on **Developer mode** (toggle in the top-right corner).
4. Click **Load unpacked** (top-left), choose the **`survev-control-center`** folder (the one that contains
   `manifest.json`), and press **Select**.
5. Click the puzzle-piece icon in the Chrome toolbar and **pin** “SURVEV.IO | CONTROL CENTER”.
6. Click the new toolbar icon → **Open Demo Arena**. Done — everything works immediately, no server needed.

Updating later: replace the folder contents, then press the circular **reload** arrow on the extension’s card in
`chrome://extensions`. Requires Chrome 111 or newer.

## Try it in 60 seconds

In the **Demo Arena** (opened from the popup):

| Do this | You should see |
|---|---|
| Move the mouse | FOV circle follows the cursor; candidate lines and scores to nearby players |
| Hold **Left Shift** | Aim-lock test engages: `LOCKED` bracket, lead marker, trajectory, smoothed aim angle |
| Hold Shift + click / **Space** | Test shots; **Accuracy diagnostics** (Aiming tab) fills in live |
| Pick **Strafe Test** (top bar) | Constant-speed targets — perfect for tuning prediction and smoothing |
| **Visibility** tab → turn on *Collision debugging* | Hitboxes, contact normals, bullet impacts |
| Walk behind a wall | Hidden players get silhouettes; the table lists wall thickness per player |
| ● button (bottom of panel) | Record → ▶ replay → save / load as JSON |

### The four tabs
- **Aiming** — FOV circle, smoothing + turn-rate, target priority (crosshair / distance / health / threat),
  visibility check (sight / shot / both), projectile **lead prediction** with ghost projectile, trajectory +
  spread cone, hit probability, accuracy and lead-error diagnostics, aim-error sparkline.
- **Entities** — bounding boxes (corners / full / filled), names, health bars, distance, weapon, team colours
  (by relation or per team), loot markers with rarity filter, off-screen indicators, connector lines.
- **Visibility** — line-of-sight polygon and rays, wall-occlusion diagnostics (blocker point, thickness,
  per-player visibility %), silhouettes with transparency / outline / glow, obstacle transparency, collision
  debugging.
- **Settings** — master ON/OFF, keyboard shortcuts, theme (accent, radius, opacity, density, motion),
  saved configurations (save / load / import / export), reset to defaults, developer-session status + token.

### Shortcuts
Inside the Demo Arena and on connected dev pages: **⌥M** master · **⌥D** show/hide dashboard · **⌥P** pause ·
**⌥R** record (all re-bindable in Settings). Browser-level: **⌥⇧S** master, **⌥⇧D** dashboard — change at
`chrome://extensions/shortcuts`. Double-click the panel header (or press **–**) to minimize to a pill; drag to move.

## Use it with your own game (private dev sessions)

1. Copy `dev-api-example/scc-dev-api.js` into your game’s **development build** and call `api.tick()` from your
   render loop (see `dev-api-example/main.js`). Full protocol: [`docs/DEV-API.md`](docs/DEV-API.md).
2. Serve the build from `localhost` (or `127.0.0.1`, `*.localhost`, `*.local`).
3. Make sure the token in your page matches **Settings → Developer authorization → Session token**
   (default for the example: `scc-dev-token` — change it for real use).
4. Open the page. The overlay attaches by itself once the handshake succeeds; or press **Attach to tab** in the popup.

Try the whole flow with the bundled example page:

```bash
cd ~/Documents/survev-control-center
python3 -m http.server 8080 --bind 127.0.0.1
# then open  http://localhost:8080/dev-api-example/
```
(No Python? `ruby -run -e httpd . -p 8080` works on macOS too.)

### What your game has to provide
Player/camera/obstacle/weapon data listed in [`docs/DEV-API.md`](docs/DEV-API.md#what-you-need-to-expose-from-your-game).
The extension does not read any game's internals; it only consumes what your build chooses to publish. Note that
rotated obstacles and per-pixel map geometry are not supported yet (axis-aligned rectangles and circles only).

## Project layout

```
manifest.json            MV3 manifest (popup, service worker, localhost-only content script)
src/background/          service worker: browser shortcuts + OFF badge
src/popup/               toolbar popup (embedded dashboard + quick actions)
src/demo/                Demo Arena page
src/content/             in-page overlay for authorized dev sessions (closed shadow DOM)
src/app/app.js           frame loop, input, record/replay, analysis wiring
src/engine/              aiming (target selection, lead, smoothing), visibility/collision, diagnostics
src/sim/                 deterministic synthetic world, demo source, recorder / replay player
src/render/              canvas renderer + layers (world, entities, visibility, aiming)
src/adapters/            dev API adapter + host policy
src/core/                state (chrome.storage sync), schema sanitizer, math, keys, defaults
src/ui/                  dashboard, controls, tab definitions, CSS
dev-api-example/         page-side library + runnable example "game"
tests/                   engine.test.mjs (node) · e2e.cjs (Playwright + real Chromium)
```

## Development

```bash
npm test                  # 22 pure-logic tests, no browser needed
node tests/e2e.cjs        # loads the unpacked extension in Chromium (needs Playwright), takes screenshots
bash scripts/package.sh   # → dist/survev-control-center-<version>.zip
```

## Privacy
No analytics, no network requests, no remote code. Settings live in `chrome.storage.local` on your machine.
The session token is stored there too and is excluded from saved-configuration exports.
