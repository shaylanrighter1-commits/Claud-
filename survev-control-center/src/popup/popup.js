// Toolbar popup: tells you exactly what is running on the current tab, one main action, and the settings.
// Developer tools (Demo Arena, attach to a private dev page) only appear when "Show advanced settings" is on.

import { createStorage } from '../core/storage.js';
import { State } from '../core/state.js';
import { VERSION } from '../core/defaults.js';
import { Dashboard } from '../ui/dashboard.js';
import { buttonControl } from '../ui/controls.js';
import { h } from '../core/util.js';

const SURVEV = /^https:\/\/survev\.io\//;

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function tabStatus(tab) {
  if (!tab || tab.id == null) return null;
  try {
    const res = await chrome.tabs.sendMessage(tab.id, { type: 'scc:status' });
    return res && res.ok ? res.status : null;
  } catch (_) {
    return null; // no content script on this tab
  }
}

async function main() {
  const state = new State(createStorage());
  await state.load();
  const tab = await activeTab();
  const onSurvev = !!(tab && SURVEV.test(tab.url || ''));
  const st = await tabStatus(tab);
  const advanced = state.data.loc.ui.advanced;

  // ---- status line
  const statusEl = document.getElementById('status');
  const line = (tone, text) => statusEl.append(h('span', { class: `scc-dot ${tone}` }), h('span', { text }));
  if (onSurvev && st) line('green', `Running on this survev.io tab · v${VERSION}`);
  else if (onSurvev) line('amber', 'Not running on this tab yet — it was open before the extension loaded.');
  else if (st) line('green', `Running on this page (${st.phase === 'live' ? 'survev.io' : 'dev page'}) · v${VERSION}`);
  else line('muted', `Open survev.io to use Boost and Pass · v${VERSION}`);

  // ---- actions
  const actions = document.getElementById('actions');
  if (onSurvev && st) {
    actions.append(buttonControl({
      text: st.hidden ? 'Show dashboard' : 'Show / expand dashboard', icon: 'bolt', variant: 'primary',
      onClick: async () => {
        await chrome.tabs.sendMessage(tab.id, { type: 'scc:attach' }).catch(() => {});
        window.close();
      },
    }));
  } else if (onSurvev) {
    actions.append(buttonControl({
      text: 'Reload this tab to start', icon: 'refresh', variant: 'primary',
      onClick: async () => {
        await chrome.tabs.reload(tab.id);
        window.close();
      },
    }));
  } else {
    actions.append(buttonControl({
      text: 'Open Survev.io', icon: 'bolt', variant: 'primary',
      onClick: async () => {
        await chrome.tabs.create({ url: 'https://survev.io/' });
        window.close();
      },
    }));
  }
  if (advanced) {
    actions.append(
      buttonControl({
        text: 'Demo Arena', icon: 'flask', variant: 'ghost',
        onClick: async () => {
          await chrome.tabs.create({ url: chrome.runtime.getURL('src/demo/demo.html') });
          window.close();
        },
      }),
      buttonControl({
        text: 'Attach to dev page', icon: 'link', variant: 'ghost',
        onClick: async () => {
          try {
            const res = await chrome.tabs.sendMessage(tab.id, { type: 'scc:attach' });
            if (res && res.ok) window.close();
          } catch (_) {
            dash.toast('Works on survev.io and localhost dev pages');
          }
        },
      })
    );
  }
  actions.dataset.count = String(actions.children.length);

  const dash = new Dashboard({
    state,
    app: null,
    mode: 'embedded',
    parent: document.getElementById('dash'),
    getDevStatus: async () => st || { phase: 'none', reason: 'Open survev.io or a localhost dev page. The dashboard appears on the page itself.' },
    tabs: advanced ? 'popup' : ['perf', 'pass', 'settings'],
  });
  dash.mount();
  // The tab set depends on "Show advanced settings"; rebuild the popup when it changes.
  const off = state.watch('loc.ui.advanced', () => setTimeout(() => location.reload(), 150));
  window.addEventListener('pagehide', () => {
    off();
    dash.destroy();
    state.destroy();
  });
}

main().catch((e) => {
  console.error('[SCC] popup failed', e);
  document.getElementById('dash').textContent = 'Failed to start: ' + e.message;
});
