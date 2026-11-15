// One-shot environment checks that commonly explain bad FPS in browser games.
// Creates a tiny WebGL context once, reads capabilities, and releases it immediately.

export async function probeEnvironment() {
  const env = {
    webgl: false,
    renderer: '',
    vendor: '',
    maxTexture: null,
    software: false,
    cores: navigator.hardwareConcurrency || null,
    memoryGb: navigator.deviceMemory || null,
    battery: null,
    screen: { w: screen.width, h: screen.height, dpr: devicePixelRatio || 1 },
    checkedAt: Date.now(),
  };
  try {
    const c = document.createElement('canvas');
    c.width = c.height = 1;
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    if (gl) {
      env.webgl = true;
      env.maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);
      const dbg = gl.getExtension('WEBGL_debug_renderer_info');
      env.renderer = String(dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) || '');
      env.vendor = String(dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR) || '');
      env.software = /swiftshader|llvmpipe|software|basic render|microsoft basic/i.test(env.renderer);
      const lose = gl.getExtension('WEBGL_lose_context');
      if (lose) lose.loseContext();
    }
  } catch (_) {
    /* WebGL blocked */
  }
  try {
    if (navigator.getBattery) {
      const b = await navigator.getBattery();
      env.battery = { charging: b.charging, level: b.level };
    }
  } catch (_) {
    /* not available */
  }
  return env;
}

/** Human-readable findings from env + live frame data. */
export function environmentFindings(env, refreshHz) {
  const out = [];
  if (!env) return out;
  if (!env.webgl) out.push({ level: 'bad', text: 'WebGL is unavailable. The game falls back to slow Canvas2D rendering. Enable hardware acceleration in chrome://settings/system and restart Chrome.' });
  else if (env.software) out.push({ level: 'bad', text: `Software rendering detected (${env.renderer}). Turn on "Use graphics acceleration when available" in chrome://settings/system, then relaunch Chrome. This is usually the single biggest FPS fix.` });
  else out.push({ level: 'ok', text: `GPU acceleration active (${env.renderer || 'renderer hidden'}).` });
  if (env.battery && !env.battery.charging && refreshHz && refreshHz <= 31) {
    out.push({ level: 'warn', text: 'Frames are capped near 30 Hz while on battery. Chrome Energy Saver limits frame rate — disable it in chrome://settings/performance or plug in.' });
  } else if (refreshHz && refreshHz <= 31) {
    out.push({ level: 'warn', text: 'The browser is delivering ~30 frames/s even when idle. Check Chrome Energy Saver (chrome://settings/performance) and macOS Low Power Mode.' });
  }
  if (env.cores && env.cores <= 2) out.push({ level: 'warn', text: `Only ${env.cores} CPU threads available — close other tabs and apps while playing.` });
  return out;
}
