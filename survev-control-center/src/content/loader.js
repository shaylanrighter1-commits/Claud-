// Content scripts cannot be ES modules directly; this tiny loader imports the real entry point.
// It only runs on localhost / loopback / *.local pages (see manifest matches) and stays dormant
// until the page completes the developer-API handshake or the user clicks "Attach to tab".
(async () => {
  try {
    const mod = await import(chrome.runtime.getURL('src/content/main.js'));
    await mod.boot();
  } catch (e) {
    console.warn('[SURVEV.IO | CONTROL CENTER] failed to start', e);
  }
})();
