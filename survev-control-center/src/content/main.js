// In-page overlay for private development sessions.
// Dormant by default: nothing is injected into the page until the dev API handshake succeeds
// (or the user presses "Attach to tab"). Everything lives in a closed shadow root and is removed on teardown.

import { createStorage } from '../core/storage.js';
import { State } from '../core/state.js';
import { evaluateLocation } from '../adapters/host-policy.js';
import { DevAdapter } from '../adapters/dev-adapter.js';
import { App } from '../app/app.js';
import { Dashboard } from '../ui/dashboard.js';

export async function boot() {
  if (window.top !== window || window.__sccBooted) return;
  const policy = evaluateLocation(location);
  if (!policy.ok) return; // defense in depth: manifest already limits matches
  window.__sccBooted = true;

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
      let css = '';
      try {
        css = await (await fetch(chrome.runtime.getURL('src/ui/dashboard.css'))).text();
      } catch (e) {
        console.warn('[SCC] could not load stylesheet', e);
      }
      if (dead) return;
      const host = document.createElement('div');
      host.id = 'scc-overlay-host';
      host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483646;pointer-events:none;';
      const shadow = host.attachShadow({ mode: 'closed' });
      const style = document.createElement('style');
      style.textContent = css + '\n:host{all:initial}.scc-canvas{position:fixed;inset:0;width:100%;height:100%;pointer-events:none;display:block}';
      const canvas = document.createElement('canvas');
      canvas.className = 'scc-canvas';
      shadow.append(style, canvas);
      document.documentElement.append(host);

      const app = new App({ state, canvas, mode: 'overlay', source: adapter });
      const dash = new Dashboard({
        state,
        app,
        mode: 'floating',
        parent: shadow,
        getDevStatus: async () => ({ ...adapter.status }),
        actions: { reconnect: () => adapter.reconnect() },
      });
      dash.mount();
      app.start();
      ui = { host, app, dash };
    })();
    await mounting;
    mounting = null;
  }

  function unmount() {
    if (!ui) return;
    ui.app.destroy();
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
  window.addEventListener('pagehide', teardown, { once: true });
}
