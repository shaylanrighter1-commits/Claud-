# SURVEV.IO | CONTROL CENTER  ·  v1.2.0

A Chrome (Manifest V3) extension with a matte-black / electric-blue floating dashboard.

| Where | Tabs available | What it does |
|---|---|---|
| **https://survev.io** (the real site) | **Boost** · **Pass** · Settings | Real frame-rate measurement, graphics presets through the game's own settings, before/after benchmarks; Survevr Pass level/XP/quest tracking and optional auto-confirm of unlocked items |
| Demo Arena (optional test tool) | Aiming · Entities · Visibility · Boost · Settings | Synthetic arena for testing the developer visualizations |
| Your own private dev build on `localhost` | Aiming · Entities · Visibility · Boost · Settings | Developer overlay fed by your build's authorized dev API ([docs/DEV-API.md](docs/DEV-API.md)) |

**On survev.io the Aiming, Entities and Visibility modules do not exist.** The developer adapter and overlay
canvas are never loaded there (enforced in `src/adapters/host-policy.js` and `src/content/main.js`), so nothing
reveals hidden players, aims, or reads match data. The extension never modifies network traffic.

## Install on macOS (first time)

1. Download `survev-control-center-1.2.0.zip` and double-click it in Finder. You get a folder named
   `survev-control-center` (it contains `manifest.json`). Move it somewhere permanent, e.g. `Documents`.
2. In Chrome open **`chrome://extensions`**.
3. Turn on **Developer mode** (top-right).
4. Click **Load unpacked** and choose the `survev-control-center` folder.
5. Pin it: puzzle-piece icon → pin **SURVEV.IO | CONTROL CENTER**.
6. Open **https://survev.io** — the dashboard appears on the left of the page. (Or click the toolbar icon → **Open Survev.io**.)

## Update from an earlier version (1.0.0 / 1.1.0)

1. Unzip the new ZIP.
2. Replace the **contents** of your existing `survev-control-center` folder with the new files
   (keep the same folder location), **or** remove the old card in `chrome://extensions` and *Load unpacked* the new folder.
3. In `chrome://extensions`, press the circular **reload** arrow on the extension's card.
4. Reload any open survev.io tab (⌘R).

Settings are kept when you replace files in the same folder and reload. Removing the extension deletes its settings.

## Using it on survev.io

- **Move**: drag the header. **Minimize**: the **–** button (or double-click the header) → small pill; click the pill to expand.
- **Hide / show**: **⌥D** (Option-D). Browser-wide: **⌥⇧D**. Master switch: **⌥⇧S**.
- **Gameplay input is never captured**: clicks, wheel and typing inside the panel don't reach the game, and after
  you click a panel button the focus goes straight back so WASD keeps working. When minimized only the small pill
  is clickable; when hidden nothing is.

### Boost (Performance)
- **Live FPS, average, 1% low, frame-time graph, stutters, long frames, display refresh, resolution & DPR.**
  Measured from the browser's real frame cadence on the survev.io tab (`requestAnimationFrame` timestamps + the
  Long Animation Frames API). Nothing is estimated from game data; the Demo Arena is labelled as *not* survev.io.
- **Presets** (MAX FPS / BALANCED / QUALITY) change only the game's own settings checkboxes, by clicking them like
  you would, plus the dashboard's own weight.
- **Auto optimize** (off by default; target 30/60/120/144): steps down one preset only after 7 of 10 seconds are
  below 90% of the target, waits 30 s between changes, measures whether it helped, never steps back up by itself,
  never reloads the page, and stops when changes don't help. Every action is logged with its reason and effect.
- **Before / after benchmark**: equal 10/15/30 s windows; reports a change only if it is statistically significant
  (Welch's t-test, p < 0.05) **and** ≥ 3%. Otherwise it says "No significant difference".
- **Network**: online/offline events and the browser's connection estimate. Game ping and WebSocket state are shown
  as "not exposed" on survev.io — the extension does not invent or intercept them.

### What is verified vs. what needs testing on your Mac

| Change | Status | Why |
|---|---|---|
| Lightweight dashboard (no blur/shadows/animations over the game) | **Verified** | Our own UI; removing backdrop blur over a moving canvas removes per-frame GPU work |
| Overlay canvas hidden when idle | **Verified** | Our own rendering (dev pages / demo only — no overlay on survev.io) |
| High-resolution textures **off** | **Requires testing** | Real GPU/memory effect, size depends on your GPU. The game applies it only by **reloading the page** (you'll be asked first; do it between matches). It has **no effect** on screens under 1366×768 device px, Canvas2D rendering or GPUs with max texture size < 4096 — the Boost tab tells you which applies |
| Screen shake **off** | Comfort only | Camera offset; no rendering cost expected. Applies from the next match |
| Interpolation, Local rotation | **Never changed by presets** | No rendering cost; turning interpolation off makes movement choppier |
| Environment fixes (hardware acceleration, Energy Saver 30 FPS cap) | Detected and explained | Usually the biggest real-world wins; you change them in Chrome settings |

Use **Measure BEFORE → change → Measure AFTER** (in a similar game situation) to see what actually helps on your machine.
The Game settings card then shows the measured result next to that setting.

### Pass
- Reads **level**, **XP / target**, **daily quests** (progress, XP reward, refresh timer) from the game's own pass panel
  (`#pass-progress-*`, `#pass-quest-0/1`). Log in on survev.io for real values; logged out, the game shows placeholders and
  the tab says so.
- Records level-ups, XP gained (after the game's XP animation settles) and quest completions — on this device only.
- **Auto Claim** (off by default): when the game shows its *"You got a new item!"* window (`#modal-item-confirm`), the
  extension presses the game's own **Confirm** button (or **Confirm all**, `[data-confirm-all="true"]`, if you choose).
  That window only appears for items the server has already added to your account; confirming just acknowledges them,
  exactly like clicking it yourself. Every confirmation is listed in **Claim history**.
- Never edits XP, never calls game APIs, never unlocks anything.

## Testing done for this release

| Suite | Target | Result |
|---|---|---|
| `npm test` (35 unit tests) | stats & t-test, settings integration, pass parsing, host policy, engine | pass |
| `node tests/e2e-live.cjs --real` | **the real https://survev.io** in Chromium with the extension loaded | pass — dashboard loads, only Boost/Pass/Settings, no dev canvas, real FPS measured, all four game settings + all pass elements detected, logged-out state recognised |
| `node tests/e2e-live.cjs` | survev.io URL served from `tests/fixtures/survev-fixture.html` (reproduces the site's markup and the client's settings/pass/unlock-window behaviour) | pass — presets via game checkboxes, reload consent, restore, before/after benchmark, input isolation, XP/level/quest history, auto-claim one-by-one and confirm-all |
| `node tests/e2e.cjs` | Demo Arena, popup, private dev page | pass |

Not testable from the cloud test machine: a logged-in account (real XP values, a real unlock window) and a real match.
Those code paths were exercised against the fixture, which mirrors the client code described in `docs/PERFORMANCE.md`.

## Developer features (unchanged)
Demo Arena, replays and the private dev API are documented in [docs/DEV-API.md](docs/DEV-API.md). Open the Demo Arena
from the toolbar popup. Its Boost numbers measure the simulator page, not survev.io.

## Development
```bash
npm test
node tests/e2e-live.cjs            # fixture
node tests/e2e-live.cjs out --real # real survev.io (needs network access to survev.io)
node tests/e2e.cjs                 # demo + dev page
bash scripts/package.sh            # -> dist/survev-control-center-<version>.zip
```

## Privacy
No analytics, no remote code, no requests of its own on survev.io. Settings, benchmarks and pass history live in
`chrome.storage.local` on your Mac.
