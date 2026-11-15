// Service worker: browser-level shortcuts + toolbar badge. Holds no state of its own;
// everything lives in chrome.storage.local ('scc.local' / 'scc.config').

const LOCAL_KEY = 'scc.local';

async function readLocal() {
  const r = await chrome.storage.local.get(LOCAL_KEY);
  return r[LOCAL_KEY] && typeof r[LOCAL_KEY] === 'object' ? r[LOCAL_KEY] : {};
}

async function updateBadge() {
  try {
    const loc = await readLocal();
    const off = loc.master === false;
    await chrome.action.setBadgeText({ text: off ? 'OFF' : '' });
    await chrome.action.setBadgeBackgroundColor({ color: '#ff4d5e' });
  } catch (e) {
    console.warn('[SCC] badge update failed', e);
  }
}

/**
 * Content scripts are only injected into pages loaded AFTER install/update. Inject into survev.io tabs that are
 * already open so the dashboard appears without a manual reload.
 */
async function injectIntoOpenTabs() {
  try {
    const tabs = await chrome.tabs.query({ url: 'https://survev.io/*' });
    for (const t of tabs) {
      if (t.id == null || t.discarded) continue;
      await chrome.scripting.executeScript({ target: { tabId: t.id }, files: ['src/content/loader.js'] }).catch(() => {});
    }
  } catch (e) {
    console.warn('[SCC] could not inject into open tabs', e);
  }
}

chrome.runtime.onInstalled.addListener((details) => {
  updateBadge();
  if (details.reason === 'install' || details.reason === 'update') injectIntoOpenTabs();
});
chrome.runtime.onStartup.addListener(updateBadge);
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes[LOCAL_KEY]) updateBadge();
});

chrome.commands.onCommand.addListener(async (command) => {
  try {
    if (command === 'toggle-master') {
      const loc = await readLocal();
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
