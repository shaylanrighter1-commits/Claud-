// Toolbar popup: compact, embedded version of the dashboard + quick actions.

import { createStorage } from '../core/storage.js';
import { State } from '../core/state.js';
import { Dashboard } from '../ui/dashboard.js';
import { buttonControl } from '../ui/controls.js';

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function getDevStatus() {
  try {
    const tab = await activeTab();
    if (!tab || tab.id == null) throw new Error('no tab');
    const res = await chrome.tabs.sendMessage(tab.id, { type: 'scc:status' });
    if (res && res.ok) return res.status;
  } catch (_) {
    /* no content script on this tab */
  }
  return { phase: 'none', reason: 'Open a localhost / private dev page, then press “Attach to tab”.' };
}

async function main() {
  const state = new State(createStorage());
  await state.load();
  const dash = new Dashboard({
    state,
    app: null,
    mode: 'embedded',
    parent: document.getElementById('dash'),
    getDevStatus,
  });
  dash.mount();

  const actions = document.getElementById('actions');
  actions.append(
    buttonControl({
      text: 'Open Demo Arena',
      icon: 'flask',
      variant: 'primary',
      onClick: async () => {
        await chrome.tabs.create({ url: chrome.runtime.getURL('src/demo/demo.html') });
        window.close();
      },
    }),
    buttonControl({
      text: 'Attach to tab',
      icon: 'link',
      variant: 'ghost',
      onClick: async () => {
        try {
          const tab = await activeTab();
          const res = await chrome.tabs.sendMessage(tab.id, { type: 'scc:attach' });
          if (res && res.ok) {
            dash.toast('Dashboard opened on the page');
            window.close();
          }
        } catch (_) {
          dash.toast('Works on localhost / private dev pages only');
        }
      },
    })
  );
  window.addEventListener('pagehide', () => {
    dash.destroy();
    state.destroy();
  });
}

main().catch((e) => {
  console.error('[SCC] popup failed', e);
  document.getElementById('dash').textContent = 'Failed to start: ' + e.message;
});
