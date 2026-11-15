# SURVEV.IO | CONTROL CENTER  ·  v1.3.0

A Chrome (Manifest V3) extension with a matte-black / electric-blue floating dashboard.

| Where | Tabs available | What it does |
|---|---|---|
| **https://survev.io** (the real site) | **Boost** · **Pass** · Settings | Real frame-rate measurement, graphics presets through the game's own settings, before/after benchmarks; Survevr Pass level/XP/quest tracking and optional auto-confirm of unlocked items |
| Demo Arena (optional test tool) | Aiming · Entities · Visibility · Boost · Settings | Synthetic arena for testing the developer visualizations |
| Your own private dev build on `localhost` | Aiming · Entities · Visibility · Boost · Settings | Developer overlay fed by your build's authorized dev API ([docs/DEV-API.md](docs/DEV-API.md)) |

**On survev.io the Aiming, Entities and Visibility modules do not exist.** The developer adapter and overlay
canvas are never loaded there (enforced in `src/adapters/host-policy.js` and `src/content/main.js`), so nothing
reveals hidden players, aims, or reads match data. The extension never modifies network traffic.

## Replace your existing copy (macOS) — recommended

1. In Chrome open **`chrome://extensions`** and click **Remove** on the old *SURVEV.IO | CONTROL CENTER* card.
2. In Finder, delete the old `survev-control-center` folder.
3. Double-click `survev-control-center-1.3.0.zip` and move the new `survev-control-center` folder somewhere permanent (e.g. Documents).
4. Back in `chrome://extensions`: **Developer mode** on (top-right) → **Load unpacked** → select the new folder (the one with `manifest.json`).
5. Check the card says **1.3.0**. Pin it (puzzle-piece icon → pin).
6. Go to **https://survev.io**. The dashboard appears at the top-left. Tabs that were already open get it automatically;
   if one doesn't, press ⌘R once.

Removing the old copy resets its settings. To keep settings instead: replace the *contents* of the existing folder with
the new files, then press the circular **reload** arrow on the card in `chrome://extensions`.

### If you don't see the dashboard on survev.io
- Click the extension's toolbar icon: the top line says exactly what is happening on the current tab
  (*Running on this survev.io tab · v1.3.0* / *Not running on this tab yet* with a **Reload this tab** button).
- `chrome://extensions` → the card → **Details** → **Site access** must allow survev.io ("On all sites" or "On specific sites").
- You hid it with **⌥D** — press ⌥D again, or click the toolbar icon → **Show dashboard**.
- The card must show version **1.3.0** (1.0.0 only had the Demo Arena).

## Using it on survev.io

- **Simple by default**: Boost shows Live FPS, Graphics preset and Game settings; Pass shows progress, quests and
  Auto claim. Everything else (analytics, benchmark, auto optimize, network, histories, shortcuts, theme…) appears
  after **Settings → Show advanced settings** (or the *Show advanced settings* button at the bottom of each tab).
- **Move**: drag the header. **Minimize**: the **–** button (or double-click the header) → a small round icon; click it to expand, drag it to move.
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

## What was tested on the real survev.io (v1.3.0)

Chromium with the packaged extension loaded, opening the real https://survev.io (logged out):

| Feature | Result on the real site |
|---|---|
| Dashboard loads over the real game page, game canvas `#cvs` untouched | ✓ works |
| Only Boost / Pass / Settings; no dev overlay canvas; no dev-API traffic | ✓ works |
| Simple mode by default (3 cards on Boost), compact 344 px panel | ✓ works |
| Minimize to a 46 px round icon and expand again | ✓ works |
| Injection into an already-open survev.io tab, no duplicate dashboard | ✓ works |
| Real FPS / frame-time / stutter measurement of the survev.io tab | ✓ works (58–60 FPS in the test browser) |
| Environment check (software vs hardware GPU rendering) | ✓ works (correctly flagged the test machine's software renderer) |
| All four game graphics settings found and shown as switches | ✓ works |
| Pass level, XP and both quest slots read from the page; logged-out state recognised | ✓ works (logged out: level 1, 0/50 XP placeholders) |
| Popup status line + simple popup | ✓ works |
| No errors from the extension | ✓ (the site logs one error of its own when `api.survev.io` is unreachable — same without the extension) |

Could **not** be exercised on the real site from the test machine (no account, no live match):
real XP values, a real *"You got a new item!"* window (Auto Claim), XP/quest history from real progress, and
applying presets/settings during a real match. Those paths were tested against `tests/fixtures/survev-fixture.html`,
which reproduces the site's markup and the client behaviour documented in `docs/PERFORMANCE.md`
(presets via the game's checkboxes, reload consent, restore, before/after benchmark, input isolation, XP/level/quest
history, auto-claim one-by-one and confirm-all) — all pass. Your first logged-in session is the real-world check.

Other suites: `npm test` (35 unit tests) and `node tests/e2e.cjs` (Demo Arena, popup, private dev page) — pass.

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
