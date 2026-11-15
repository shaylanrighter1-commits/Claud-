// In-page overlay for private development sessions.
// Dormant by default: nothing is injected into the page until the dev API handshake succeeds
// (or the user presses "Attach to tab", or the page is a local game build with #cvs and auto-open is on).
// Everything lives in a shadow root and is removed on teardown.

import { createStorage } from '../core/storage.js';
import { State } from '../core/state.js';
import { classifyLocation } from '../adapters/host-policy.js';
import { PassManager } from '../pass/pass-manager.js';
import { matchCombo, isTypingTarget } from '../core/keys.js';
import { DevAdapter } from '../adapters/dev-adapter.js';
import { App } from '../app/app.js';
import { Dashboard } from '../ui/dashboard.js';
import { PerfController } from '../perf/perf-controller.js';

async function loadCss() {
  try {
    return await (await fetch(chrome.runtime.getURL('src/ui/dashboard.css'))).text();
  } catch (e) {
    console.warn('[SCC] could not load stylesheet', e);
    return '';
  }
}

/** Remove dashboards left behind by a previous (reloaded/updated) copy of the extension. */
function removeStaleHosts() {
  for (const el of document.querySelectorAll('#scc-overlay-host')) el.remove();
}

/** When the extension is reloaded/updated, this copy's context dies; clean up instead of lingering. */
function watchContext(teardown) {
  const iv = setInterval(() => {
    let alive = false;
    try {
      alive = !!(chrome.runtime && chrome.runtime.id);
    } catch (_) {
      alive = false;
    }
    if (!alive) {
      clearInterval(iv);
      teardown();
    }
  }, 2000);
  return () => clearInterval(iv);
}

function makeHost(css) {
  removeStaleHosts();
  const host = document.createElement('div');
  host.id = 'scc-overlay-host';
  // The host never takes pointer events itself; only the panel / pill inside it do.
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483646;pointer-events:none;';
  const shadow = host.attachShadow({ mode: 'open' });
  const style = document.createElement('style');
  style.textContent = css + '\n:host{all:initial}.scc-canvas{position:fixed;inset:0;width:100%;height:100%;pointer-events:none;display:block}';
  shadow.append(style);
  document.documentElement.append(host);
  return { host, shadow };
}

export async function boot() {
  if (window.top !== window || window.__sccBooted) return;
  const kind = classifyLocation(location);
  if (kind === 'none') return; // defense in depth: manifest already limits matches
  window.__sccBooted = true;
  if (kind === 'live') return bootLive();

  let ui = null;
  let mounting = null;
  let dead = false;

  const storage = createStorage(() => teardown());
  const state = new State(storage);
  await state.load();
  const adapter = new DevAdapter({ state });

  async function mount() {
    if (ui || dead) return;
    if (mounting) return mounting;
    mounting = (async () => {
      const css = await loadCss();
      if (dead) return;
      const { host, shadow } = makeHost(css);
      const canvas = document.createElement('canvas');
      canvas.className = 'scc-canvas';
      shadow.append(canvas);

      const app = new App({ state, canvas, mode: 'overlay', source: adapter });
      const perf = new PerfController({ state, app, mode: 'overlay' });
      perf.start();
      const dash = new Dashboard({
        state,
        app,
        perf,
        mode: 'floating',
        parent: shadow,
        getDevStatus: async () => ({ ...adapter.status }),
        actions: { reconnect: () => adapter.reconnect() },
      });
      dash.mount();
      app.start();
      ui = { host, app, dash, perf };
    })();
    await mounting;
    mounting = null;
  }

  function unmount() {
    if (!ui) return;
    ui.app.destroy();
    ui.perf.destroy();
    ui.dash.destroy();
    ui.host.remove();
    ui = null;
  }

  function teardown() {
    if (dead) return;
    dead = true;
    unmount();
    adapter.stop(false);
    try {
      state.destroy();
    } catch (_) {
      /* extension context already gone */
    }
    try {
      chrome.runtime.onMessage.removeListener(onMessage);
    } catch (_) {
      /* ignore */
    }
    window.__sccBooted = false;
  }

  function onMessage(msg, _sender, send) {
    if (!msg || typeof msg.type !== 'string') return;
    switch (msg.type) {
      case 'scc:attach':
        if (adapter.status.phase === 'idle') adapter.start();
        state.set('loc.ui.hidden', false);
        state.set('loc.ui.minimized', false);
        mount().then(() => send({ ok: true, status: { ...adapter.status } }));
        return true;
      case 'scc:status':
        send({ ok: true, status: { ...adapter.status, mounted: !!ui } });
        return;
      case 'scc:toggleDashboard':
        if (!ui) mount().then(() => send({ ok: true }));
        else {
          state.toggle('loc.ui.hidden');
          send({ ok: true });
        }
        return true;
      case 'scc:detach':
        unmount();
        send({ ok: true });
    }
  }

  adapter.onChange = (st) => {
    if (st.phase === 'authorized' && state.data.loc.dev.autoAttach) mount();
  };
  adapter.start();
  chrome.runtime.onMessage.addListener(onMessage);
  // Local game builds (e.g. a self-hosted client on localhost) have the game canvas #cvs:
  // open the dashboard so the Performance Boost tab is available without the dev API.
  if (state.data.cfg.perf.autoAttach && document.getElementById('cvs')) mount();
  window.addEventListener('pagehide', teardown, { once: true });
  watchContext(teardown);
}

// ---------------------------------------------------------------- live site (survev.io)
// Only Performance Boost, Pass and Settings. No developer adapter, no overlay canvas, no aiming/entity/
// visibility code paths, and no input listeners beyond the single "show/hide dashboard" shortcut.
async function bootLive() {
  const storage = createStorage(() => teardown());
  const state = new State(storage);
  await state.load();
  const css = await loadCss();
  const { host, shadow } = makeHost(css);
  const perf = new PerfController({ state, app: null, mode: 'live' });
  const pass = new PassManager({ state });
  perf.start();
  pass.start();
  const dash = new Dashboard({
    state,
    perf,
    pass,
    mode: 'floating',
    parent: shadow,
    tabs: 'live',
    label: 'Survev.io',
    defaultSide: 'left', // survev's menu keeps the pass panel and settings buttons on the right
    getDevStatus: async () => ({ phase: 'live', host: location.host, reason: 'Aiming, Entities and Visibility are developer tools for the Demo Arena and private test sessions. They are not available on the live site.' }),
  });
  dash.mount();
  if (!['perf', 'pass', 'settings'].includes(state.data.loc.ui.tab)) state.set('loc.ui.tab', 'perf');

  const onKey = (e) => {
    if (isTypingTarget(e.target) || !matchCombo(e, state.data.cfg.shortcuts.dashboard)) return;
    e.preventDefault();
    e.stopPropagation();
    state.toggle('loc.ui.hidden');
  };
  window.addEventListener('keydown', onKey, true);

  function onMessage(msg, _sender, send) {
    if (!msg || typeof msg.type !== 'string') return;
    if (msg.type === 'scc:status') send({ ok: true, status: { phase: 'live', host: location.host, mounted: true, hidden: state.data.loc.ui.hidden, version: chrome.runtime.getManifest().version } });
    else if (msg.type === 'scc:attach') {
      state.set('loc.ui.hidden', false);
      state.set('loc.ui.minimized', false);
      send({ ok: true, status: { phase: 'live' } });
    } else if (msg.type === 'scc:toggleDashboard') {
      state.toggle('loc.ui.hidden');
      send({ ok: true });
    }
  }
  chrome.runtime.onMessage.addListener(onMessage);

  let dead = false;
  let stopWatch = () => {};
  function teardown() {
    if (dead) return;
    dead = true;
    stopWatch();
    window.removeEventListener('keydown', onKey, true);
    try {
      chrome.runtime.onMessage.removeListener(onMessage);
    } catch (_) {
      /* context gone */
    }
    perf.destroy();
    pass.stop();
    dash.destroy();
    host.remove();
    try {
      state.destroy();
    } catch (_) {
      /* ignore */
    }
    window.__sccBooted = false;
  }
  window.addEventListener('pagehide', teardown, { once: true });
  stopWatch = watchContext(teardown);
}
