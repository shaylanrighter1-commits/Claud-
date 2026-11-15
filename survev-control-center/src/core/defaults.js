// Central configuration schema, defaults, presets and themes.

export const PRODUCT = 'SURVEV.IO | CONTROL CENTER';
export const VERSION = '1.4.0';
export const SCHEMA_VERSION = 1;

/** Test weapons used by the demo arena and as fallbacks for dev snapshots. */
export const WEAPONS = {
  pistol: { id: 'pistol', name: 'M9 Pistol', bulletSpeed: 720, range: 650, spread: 2.4, fireRate: 4.5, damage: 12 },
  rifle: { id: 'rifle', name: 'AK Rifle', bulletSpeed: 1000, range: 900, spread: 1.7, fireRate: 8, damage: 10 },
  smg: { id: 'smg', name: 'Vector SMG', bulletSpeed: 860, range: 600, spread: 3.6, fireRate: 13, damage: 6 },
  sniper: { id: 'sniper', name: 'Sniper', bulletSpeed: 2200, range: 1700, spread: 0.25, fireRate: 1.2, damage: 55 },
};

export const RARITY = [
  { name: 'Common', color: '#cbd5e1' },
  { name: 'Uncommon', color: '#34d399' },
  { name: 'Rare', color: '#38bdf8' },
  { name: 'Epic', color: '#c084fc' },
  { name: 'Legendary', color: '#fbbf24' },
];

export const TEAM_PALETTE = ['#4cc9f0', '#ff4d5e', '#34d399', '#fbbf24', '#a78bfa', '#fb923c', '#f472b6', '#94a3b8'];

export const THEMES = {
  electric: { label: 'Electric Blue', accent: '#2f7bff' },
  cyan: { label: 'Cyan', accent: '#22d3ee' },
  violet: { label: 'Violet', accent: '#8b5cf6' },
  emerald: { label: 'Emerald', accent: '#10b981' },
  amber: { label: 'Amber', accent: '#f59e0b' },
  rose: { label: 'Rose', accent: '#f43f5e' },
};

/** Profile-able configuration (saved configurations store exactly this object). */
export const DEFAULT_CFG = {
  v: SCHEMA_VERSION,
  hud: { show: true },

  aiming: {
    enabled: true,
    showFov: true,
    fovRadius: 200,
    fovOpacity: 14,
    fovPulse: true,
    fovColor: '#2f7bff',
    smoothing: 55,
    maxTurnRate: 540,
    lockKey: 'ShiftLeft',
    lockMode: 'hold',
    autoFire: false,
    weapon: 'rifle',
    targetMode: 'crosshair',
    enemiesOnly: true,
    visibilityCheck: 'both',
    stickyMs: 350,
    showCandidates: true,
    prediction: {
      enabled: true,
      strength: 100,
      maxLeadMs: 900,
      latencyMs: 40,
      showMarker: true,
      showGhost: true,
      showPath: true,
    },
    showTrajectory: true,
    showSpread: true,
    showImpact: true,
  },

  entities: {
    enabled: true,
    maxDistance: 140,
    boxes: { show: true, style: 'corners', thickness: 2, scale: 115, dashedOccluded: true },
    labels: {
      names: true,
      health: true,
      hpText: true,
      healthStyle: 'bar',
      distance: true,
      unit: 'm',
      weapon: true,
      scale: 100,
    },
    teams: {
      enabled: true,
      mode: 'relation',
      opacity: 92,
      colors: { self: '#ffffff', ally: '#34d399', enemy: '#ff4d5e', neutral: '#fbbf24' },
    },
    loot: { show: true, minRarity: 0, labels: true, size: 9 },
    offscreen: { show: true, size: 14, margin: 36, labels: true, maxCount: 10 },
    lines: { show: false },
  },

  visibility: {
    enabled: true,
    los: { showCone: true, showRays: true, range: 70, fov: 360, fillOpacity: 12 },
    occlusion: { show: true, labels: true, highlight: true, blockerPoints: true },
    silhouettes: { show: true, colorMode: 'team', color: '#2f7bff', alpha: 45, outline: 2, glow: 10, outlineVisible: false },
    wallAlpha: 100,
    obstacleGhost: true,
    obstacleOutline: false,
    collisions: { hitboxes: false, players: false, contacts: false, impacts: true },
  },

  theme: { preset: 'electric', accent: '#2f7bff', radius: 14, panelOpacity: 94, compact: false, motion: true },

  shortcuts: { master: 'Alt+KeyM', dashboard: 'Alt+KeyD', pause: 'Alt+KeyP', record: 'Alt+KeyR' },

  perf: {
    monitor: true,
    window: 10,
    targetFps: 60,
    autoOptimize: false,
    preset: '',
    liteUi: false,
    autoAttach: true,
    benchSeconds: 15,
    net: { probe: false, endpoint: '/', intervalSec: 5 },
    // Your chosen values for the game's own settings (null = no preference). Re-applied when the game loads.
    applyOnLoad: true,
    gamePrefs: { highResTex: null, screenShake: null, interpolation: null, localRotation: null },
  },

  pass: { track: true, autoClaim: false, claimMode: 'next' },
};

/** Device-local state (never part of saved configurations). */
export const DEFAULT_LOCAL = {
  master: true,
  activeProfile: '',
  profiles: {},
  ui: { tab: 'aiming', minimized: false, hidden: false, x: -1, y: -1, advanced: false, startMinimized: true },
  dev: { token: 'scc-dev-token', autoAttach: true },
  perf: {
    original: null,
    bench: { before: null, after: null },
    autoLog: [],
    settingTests: {},
  },
  pass: { last: null, history: [], claims: [] },
};

/** Quick presets: patches applied on top of the defaults (theme + shortcuts are preserved). */
export const PRESETS = {
  balanced: { label: 'Balanced', patch: {} },
  minimal: {
    label: 'Minimal',
    patch: {
      aiming: { showCandidates: false, showSpread: false },
      entities: {
        labels: { weapon: false, hpText: false },
        offscreen: { labels: false },
        loot: { labels: false },
      },
      visibility: { los: { showRays: false }, occlusion: { labels: false } },
    },
  },
  diagnostics: {
    label: 'Full Diagnostics',
    patch: {
      entities: { lines: { show: true } },
      visibility: {
        los: { showRays: true, showCone: true },
        silhouettes: { outlineVisible: true },
        collisions: { hitboxes: true, players: true, contacts: true, impacts: true },
      },
    },
  },
  presentation: {
    label: 'Presentation',
    patch: {
      entities: { labels: { scale: 125 }, boxes: { thickness: 3 } },
      aiming: { fovOpacity: 22 },
      visibility: { silhouettes: { glow: 18, alpha: 60 } },
    },
  },
};
