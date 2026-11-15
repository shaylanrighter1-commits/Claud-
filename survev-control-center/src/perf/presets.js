// Graphics-quality presets.
//   game:    values for the game's own settings controls (only applied when the control exists on the page;
//            `interpolation` and `localRotation` are deliberately never touched — they cost nothing to render
//            and disabling them would make the game feel less smooth / responsive).
//   overlay: Control Center's own rendering cost (we control these, so their effect is verifiable).

export const PRESETS = {
  maxfps: {
    id: 'maxfps',
    label: 'MAX FPS',
    level: 0,
    blurb: 'Performance first. Low-res textures, no cosmetic effects, lightest overlay.',
    game: { highResTex: false, screenShake: false },
    overlay: { glow: 0, pulse: false, ghost: false, cone: false, rays: false, liteUi: true },
  },
  balanced: {
    id: 'balanced',
    label: 'BALANCED',
    level: 1,
    blurb: 'Keeps high-res textures, trims cosmetic effects, prioritises stable frame pacing.',
    game: { highResTex: true, screenShake: false },
    overlay: { glow: 4, pulse: false, ghost: true, cone: true, rays: false, liteUi: true },
  },
  quality: {
    id: 'quality',
    label: 'QUALITY',
    level: 2,
    blurb: 'Full visuals and effects. FPS is still monitored.',
    game: { highResTex: true, screenShake: true },
    overlay: { glow: 10, pulse: true, ghost: true, cone: true, rays: true, liteUi: false },
  },
};

export const PRESET_ORDER = ['maxfps', 'balanced', 'quality'];

/** Overlay knob -> config path. */
export const OVERLAY_PATHS = {
  glow: 'cfg.visibility.silhouettes.glow',
  pulse: 'cfg.aiming.fovPulse',
  ghost: 'cfg.aiming.prediction.showGhost',
  cone: 'cfg.visibility.los.showCone',
  rays: 'cfg.visibility.los.showRays',
  liteUi: 'cfg.perf.liteUi',
};

export const OVERLAY_LABELS = {
  glow: 'Silhouette glow',
  pulse: 'FOV pulse animation',
  ghost: 'Ghost projectile animation',
  cone: 'Visibility polygon',
  rays: 'LOS rays',
  liteUi: 'Lightweight dashboard (no blur/animations)',
};

export function presetLevel(id) {
  return PRESETS[id] ? PRESETS[id].level : 2;
}
