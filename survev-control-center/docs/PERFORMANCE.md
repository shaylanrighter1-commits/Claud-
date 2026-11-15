# How the game's settings and pass UI work (client analysis)

Source: the supplied client bundle `BGmvCf-g.js` (survev.io client), plus the live page markup.

## Settings
- Every `.modal-settings-item > input:checkbox` is bound to `change` → `config.set(<id>, checked)`. The menu itself
  toggles them with `prop('checked', …)` + `trigger('change')`. The extension uses `element.click()` — the same path.
- `onConfigModified`: **`highResTex` → `location.reload()`**.
- Texture tier (`oi()`): `'high'` only if `highResTex` **and** not (`max(screen)·dpr < 1366` and `min(screen)·dpr < 768`)
  **and** not a phone **and** WebGL renderer **and** `MAX_TEXTURE_SIZE ≥ 4096`; otherwise `'low'` regardless of the setting.
- `screenShake`, `interpolation`, `localRotation` are copied into the camera in the game's init → they apply to the
  **next match**. None changes the amount rendered.
- The client has its own `debugHUD` (FPS, ping, server-update graphs) drawn inside the canvas; the extension does not
  read canvas pixels.

## Pass
- `#pass-progress-level`, `#pass-progress-xp-current`, `#pass-progress-xp-target` are written from server pass data;
  XP animates toward the new value. Logged out: placeholders (level 1, 0 XP) and `#pass-locked` shown.
- `#pass-quest-<idx>` contains `.pass-quest-desc`, `.pass-quest-counter-current/-target`, `.pass-quest-xp`, `.pass-quest-timer`.
- `#modal-item-confirm` is shown by `confirmNextItem()` for entries in the account's pending-confirm list (items already
  granted). Clicking a `.close` element hides it; `onHide(e)` calls `confirmAllItems()` if `e.target` has `data-confirm-all`,
  otherwise `confirmNextItem()`. Both mark items as acknowledged (`setItemStatus(Ackd)`).

## Measurement method
- Frame times = differences of `requestAnimationFrame` timestamps on the game tab (vsync-aligned frame starts).
  Gaps > 1 s (tab hidden) are discarded. 1% low = FPS of the mean of the slowest 1% of frames.
- Stutter = frame time > max(2.5 × median, median + 12 ms). Display refresh = fastest sustained 10th-percentile cadence.
- Benchmarks compare per-second FPS samples with Welch's t-test; a change is reported only if p < 0.05 and |Δ| ≥ 3%.
