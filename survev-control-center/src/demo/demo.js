// Standalone Demo Arena: simulated players, obstacles, loot and bullets. No network, no game connection.

import { createStorage } from '../core/storage.js';
import { State } from '../core/state.js';
import { App } from '../app/app.js';
import { DemoSource } from '../sim/demo-source.js';
import { SCENARIOS } from '../sim/world.js';
import { Dashboard } from '../ui/dashboard.js';

async function main() {
  const state = new State(createStorage());
  await state.load();

  const canvas = document.getElementById('stage');
  const scenarioSel = document.getElementById('scenario');
  const botsInput = document.getElementById('bots');
  const hint = document.getElementById('hint');
  for (const [id, s] of Object.entries(SCENARIOS)) scenarioSel.append(new Option(s.label, id));

  let seed = 7;
  const opts = () => ({ scenario: scenarioSel.value, seed, bots: Math.max(2, Math.min(14, Number(botsInput.value) || 8)) });
  const source = new DemoSource(opts());
  const app = new App({ state, canvas, mode: 'demo', source });

  const restart = () => {
    source.reset(opts());
    app.resetDiagnostics();
    app.renderer.fx.length = 0;
    app.lastSnap = null;
    app.lastSeq = -1;
    hint.textContent = SCENARIOS[scenarioSel.value].hint;
  };
  scenarioSel.addEventListener('change', restart);
  botsInput.addEventListener('change', restart);
  document.getElementById('restart').addEventListener('click', restart);
  document.getElementById('reseed').addEventListener('click', () => {
    seed = (seed * 7919 + 13) % 100000;
    restart();
  });
  hint.textContent = SCENARIOS[scenarioSel.value].hint;

  const dash = new Dashboard({
    state,
    app,
    mode: 'floating',
    parent: document.body,
    getDevStatus: async () => ({
      phase: 'demo',
      host: 'Demo Arena (extension page)',
      reason: 'Synthetic players and obstacles only. The dev API adapter is inactive on this page.',
    }),
  });
  dash.mount();
  app.start();

  if (globalThis.chrome && chrome.runtime && chrome.runtime.onMessage) {
    chrome.runtime.onMessage.addListener((msg) => {
      if (msg && msg.type === 'scc:toggleDashboard') state.toggle('loc.ui.hidden');
    });
  }
  window.addEventListener('pagehide', () => {
    app.destroy();
    dash.destroy();
    state.destroy();
  });
  window.__scc = { app, state, source }; // handy for debugging in DevTools
}

main().catch((e) => {
  console.error('[SCC] demo failed', e);
  document.body.append(Object.assign(document.createElement('pre'), { textContent: 'Demo failed to start: ' + e.stack, style: 'color:#ff8a96;padding:20px' }));
});
