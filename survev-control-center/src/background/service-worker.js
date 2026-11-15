// Service worker: first-run initialisation, per-tab status badge, browser shortcuts.
// Event-driven only (no timers, no polling). All state lives in chrome.storage.local.

import { DEFAULT_CFG, DEFAULT_LOCAL } from '../core/defaults.js';
import { mergeDefaults } from '../core/state.js';

const CFG_KEY = 'scc.config';
const LOCAL_KEY = 'scc.local';

/** Create (install) or upgrade (update) stored settings, keeping every value the user already chose. */
async function initStorage(reason) {
  const raw = await chrome.storage.local.get([CFG_KEY, LOCAL_KEY]);
  const cfg = mergeDefaults(DEFAULT_CFG, raw[CFG_KEY]);
  const loc = mergeDefaults(DEFAULT_LOCAL, raw[LOCAL_KEY]);
  if (reason === 'install') {
    loc.ui.tab = 'perf';
    loc.ui.minimized = true;
    loc.ui.startMinimized = true;
  }
  await chrome.storage.local.set({ [CFG_KEY]: cfg, [LOCAL_KEY]: loc });
}

async function updateGlobalBadge() {
  try {
    const loc = (await chrome.storage.local.get(LOCAL_KEY))[LOCAL_KEY] || {};
    await chrome.action.setBadgeBackgroundColor({ color: '#ff4d5e' });
    await chrome.action.setBadgeText({ text: loc.master === false ? 'OFF' : '' });
  } catch (e) {
    console.warn('[SCC] badge update failed', e);
  }
}

/**
 * Content scripts are only injected into pages loaded AFTER install/update. Inject into survev.io tabs that are
 * already open — but only where the current version isn't running yet (no duplicate initialisation).
 */
async function injectIntoOpenTabs() {
  try {
    const tabs = await chrome.tabs.query({ url: 'https://survev.io/*' });
    for (const t of tabs) {
      if (t.id == null || t.discarded) continue;
      const alive = await chrome.tabs.sendMessage(t.id, { type: 'scc:status' }).then((r) => !!(r && r.ok), () => false);
      if (!alive) await chrome.scripting.executeScript({ target: { tabId: t.id }, files: ['src/content/loader.js'] }).catch(() => {});
    }
  } catch (e) {
    console.warn('[SCC] could not inject into open tabs', e);
  }
}

chrome.runtime.onInstalled.addListener(async (details) => {
  if (details.reason === 'install' || details.reason === 'update') {
    await initStorage(details.reason).catch((e) => console.warn('[SCC] init failed', e));
    await injectIntoOpenTabs();
  }
  updateGlobalBadge();
});
chrome.runtime.onStartup.addListener(updateGlobalBadge);
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes[LOCAL_KEY]) updateGlobalBadge();
});

// Per-tab status: the content script reports once per page load (and when Master changes).
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || msg.type !== 'scc:active' || !sender.tab || sender.tab.id == null) return;
  const tabId = sender.tab.id;
  chrome.action.setBadgeText({ tabId, text: msg.on ? 'ON' : 'OFF' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: msg.on ? '#10b981' : '#ff4d5e' }).catch(() => {});
  chrome.action.setTitle({ tabId, title: `SURVEV.IO | CONTROL CENTER — ${msg.on ? 'active on this tab (⌥D opens the dashboard)' : 'Master is OFF'}` }).catch(() => {});
});

chrome.commands.onCommand.addListener(async (command) => {
  try {
    if (command === 'toggle-master') {
      const loc = (await chrome.storage.local.get(LOCAL_KEY))[LOCAL_KEY] || {};
      loc.master = loc.master === false; // undefined/true -> false, false -> true
      await chrome.storage.local.set({ [LOCAL_KEY]: loc });
    } else if (command === 'toggle-dashboard') {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tab && tab.id != null) await chrome.tabs.sendMessage(tab.id, { type: 'scc:toggleDashboard' }).catch(() => {});
    }
  } catch (e) {
    console.warn('[SCC] command failed', command, e);
  }
});
