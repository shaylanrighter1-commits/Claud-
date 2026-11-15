// Integration with the game's OWN settings controls.
//
// Findings from the supplied client bundle (BGmvCf-g.js):
//   * Every `.modal-settings-item > input:checkbox` is bound to `change` -> config.set(<input id>, checked).
//     The settings modal itself toggles them with `prop('checked', …) + trigger('change')`.
//   * onConfigModified(): `highResTex` -> location.reload()   (texture tier is chosen once at load).
//   * Texture tier: 'high' only if highResTex AND the screen is >= 1366x768 device px (either axis) AND not a phone
//     AND WebGL (not Canvas2D) AND MAX_TEXTURE_SIZE >= 4096; otherwise the game forces 'low'.
//   * screenShake / interpolation / localRotation are copied into the camera only when a match initializes,
//     so changing them affects the NEXT match. None of them changes how much is rendered.
//
// We change a setting exactly the way a user does: el.click() on the checkbox (fires the game's own handlers).
// We never touch the game's storage, JS objects, canvas resolution or network.

export const GAME_SETTINGS = [
  {
    id: 'highResTex',
    label: 'High-resolution textures',
    applies: 'reload',
    impact: 'gpu',
    note: 'Lower-resolution sprite atlases reduce GPU memory and bandwidth. Real effect depends on your GPU — benchmark it.',
  },
  {
    id: 'screenShake',
    label: 'Screen shake',
    applies: 'next-match',
    impact: 'cosmetic',
    note: 'Camera offset only. No measurable rendering cost expected; turning it off reduces visual noise.',
  },
  {
    id: 'interpolation',
    label: 'Client-side interpolation',
    applies: 'next-match',
    impact: 'smoothness',
    note: 'Smooths movement between server updates. Turning it OFF makes motion choppier — presets never disable it.',
  },
  {
    id: 'localRotation',
    label: 'Client-side player rotation',
    applies: 'next-match',
    impact: 'responsiveness',
    note: 'Rotates your player locally for instant aim feedback. No rendering cost — presets never change it.',
  },
];

export const APPLIES_TEXT = { reload: 'Reloads the page', 'next-match': 'Applies next match', live: 'Applies live' };

export class GameSettings {
  constructor(doc = document) {
    this.doc = doc;
  }

  el(id) {
    const e = this.doc.getElementById(id);
    return e && e.type === 'checkbox' ? e : null;
  }

  canvas() {
    const c = this.doc.getElementById('cvs');
    return c && c.tagName === 'CANVAS' ? c : null;
  }

  /** { id: { present, checked, disabled } } */
  read() {
    const out = {};
    for (const s of GAME_SETTINGS) {
      const e = this.el(s.id);
      out[s.id] = e ? { present: true, checked: !!e.checked, disabled: !!e.disabled } : { present: false, checked: null, disabled: false };
    }
    return out;
  }

  detected() {
    return GAME_SETTINGS.some((s) => this.el(s.id));
  }

  /**
   * Set one setting through its normal control. Returns 'unchanged' | 'changed' | 'missing' | 'disabled' | 'failed'.
   * Reload-type settings are only changed when allowReload is true.
   */
  set(id, value, { allowReload = false } = {}) {
    const meta = GAME_SETTINGS.find((s) => s.id === id);
    const e = this.el(id);
    if (!meta || !e) return 'missing';
    if (e.disabled) return 'disabled';
    if (!!e.checked === !!value) return 'unchanged';
    if (meta.applies === 'reload' && !allowReload) return 'needs-reload';
    e.click(); // identical to a user click: toggles the box and fires the game's change handler
    return !!e.checked === !!value ? 'changed' : 'failed';
  }

  /** Listen for changes the user makes in the game's own settings menu (event-driven, no polling). */
  watch(fn) {
    const handler = (ev) => {
      const t = ev.target;
      if (t && t.id && GAME_SETTINGS.some((s) => s.id === t.id)) fn(t.id, !!t.checked);
    };
    this.doc.addEventListener('change', handler, true);
    return () => this.doc.removeEventListener('change', handler, true);
  }

  /** Resolution / DPR of the game canvas (#cvs) or the viewport when absent. */
  resolution() {
    const c = this.canvas();
    const dpr = globalThis.devicePixelRatio || 1;
    if (c) {
      const r = c.getBoundingClientRect();
      return { source: '#cvs', backingW: c.width, backingH: c.height, cssW: Math.round(r.width), cssH: Math.round(r.height), dpr, scale: r.width ? c.width / r.width : null };
    }
    return { source: 'viewport', backingW: Math.round(innerWidth * dpr), backingH: Math.round(innerHeight * dpr), cssW: innerWidth, cssH: innerHeight, dpr, scale: dpr };
  }

  /** Mirrors the game's texture-tier rule so we can say whether highResTex can matter on this device. */
  textureTier(env) {
    const dpr = globalThis.devicePixelRatio || 1;
    const small = Math.min(screen.width, screen.height) * dpr;
    const large = Math.max(screen.width, screen.height) * dpr;
    const reasons = [];
    if (large < 1366 && small < 768) reasons.push(`screen is ${Math.round(large)}×${Math.round(small)} device px (< 1366×768)`);
    if (env && env.webgl === false) reasons.push('WebGL unavailable (game would use Canvas2D)');
    if (env && env.maxTexture && env.maxTexture < 4096) reasons.push(`GPU max texture size ${env.maxTexture} < 4096`);
    return { canUseHigh: reasons.length === 0, reasons };
  }
}
