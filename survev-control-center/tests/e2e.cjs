// End-to-end smoke test: loads the unpacked extension in Chromium, exercises the popup, demo arena
// and the dev-API overlay. Usage: node tests/e2e.cjs [screenshotDir]
const { chromium } = require('playwright');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
const http = require('node:http');

const root = path.join(__dirname, '..');
const shots = process.argv[2] || path.join(os.tmpdir(), 'scc-shots');
fs.mkdirSync(shots, { recursive: true });

const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(req.url.split('?')[0]));
  if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); return res.end('nf'); }
  res.writeHead(200, { 'content-type': mime[path.extname(p)] || 'text/plain' });
  fs.createReadStream(p).pipe(res);
});

let failures = 0;
const check = (name, ok, extra = '') => { console.log(ok ? '  ✓' : '  ✗', name, extra); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const ctx = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'scc-prof-')), {
    headless: false,
    args: ['--headless=new', `--disable-extensions-except=${root}`, `--load-extension=${root}`, '--no-sandbox'],
    viewport: { width: 1440, height: 860 },
    deviceScaleFactor: 1,
  });
  const errors = [];
  const hook = (page, label) => {
    page.on('pageerror', (e) => errors.push(`${label}: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(`${label}: ${m.text()}`); });
  };
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker', { timeout: 10000 });
  const extId = new URL(sw.url()).host;
  check('service worker started', !!extId, extId);

  // ---------------------------------------------------------------- demo arena
  const demo = await ctx.newPage();
  hook(demo, 'demo');
  await demo.goto(`chrome-extension://${extId}/src/demo/demo.html`);
  await demo.waitForSelector('.scc-float');
  await demo.evaluate(() => {
    window.__scc.state.set('loc.ui.advanced', true); // this suite exercises advanced controls
    window.__scc.state.set('loc.ui.minimized', false);
    window.__scc.state.set('loc.ui.tab', 'aiming');
  });
  await sleep(1500);
  await demo.mouse.move(900, 380);
  await sleep(400);
  await demo.screenshot({ path: path.join(shots, '01-demo-aiming.png') });
  check('dashboard mounted with 5 tabs', (await demo.locator('.scc-tab').count()) === 5);
  check('canvas has pixels', await demo.evaluate(() => { const c = document.getElementById('stage'); return c.width > 0 && c.getContext('2d').getImageData(c.width / 2, c.height / 2, 1, 1).data[3] > 0; }));

  // hold lock key and verify diagnostics move
  await demo.keyboard.down('ShiftLeft');
  await demo.mouse.down();
  await sleep(2500);
  const st = await demo.evaluate(() => window.__scc.app.diag.stats());
  await demo.screenshot({ path: path.join(shots, '02-demo-lock.png') });
  await demo.mouse.up();
  await demo.keyboard.up('ShiftLeft');
  check('shots fired while firing', st.shots > 3, JSON.stringify({ shots: st.shots, hits: st.hits, misses: st.misses }));

  for (const [i, id] of ['entities', 'visibility', 'perf', 'settings'].entries()) {
    await demo.click(`#scc-tab-${id}`);
    await sleep(500);
    await demo.screenshot({ path: path.join(shots, `0${3 + i}-demo-${id}.png`) });
  }
  // master toggle
  const before = await demo.evaluate(() => window.__scc.state.data.loc.master);
  await demo.click('.scc-iconbtn.power');
  await sleep(300);
  const after = await demo.evaluate(() => window.__scc.state.data.loc.master);
  check('master switch toggles', before === true && after === false);
  await demo.screenshot({ path: path.join(shots, '06-master-off.png') });
  await demo.click('.scc-iconbtn.power');

  // keyboard shortcut (Alt+M) toggles master; Alt+D hides/shows the dashboard
  await demo.mouse.move(500, 500);
  await demo.keyboard.press('Alt+KeyM');
  await sleep(250);
  check('Alt+M shortcut toggles master', (await demo.evaluate(() => window.__scc.state.data.loc.master)) === false);
  await demo.keyboard.press('Alt+KeyM');
  await demo.keyboard.press('Alt+KeyD');
  await sleep(250);
  check('Alt+D minimizes dashboard', !(await demo.locator('.scc-panel').isVisible()) && (await demo.locator('.scc-pill').isVisible()));
  await demo.keyboard.press('Alt+KeyD');
  await sleep(250);

  // minimize / restore + drag
  await demo.click('#scc-tab-aiming');
  const box0 = await demo.locator('.scc-float').boundingBox();
  await demo.mouse.move(box0.x + 150, box0.y + 24);
  await demo.mouse.down();
  await demo.mouse.move(box0.x - 250, box0.y + 120, { steps: 8 });
  await demo.mouse.up();
  await sleep(300);
  const box1 = await demo.locator('.scc-float').boundingBox();
  check('panel is draggable', Math.abs(box1.x - box0.x) > 150, `${Math.round(box0.x)} -> ${Math.round(box1.x)}`);
  const savedX = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].ui.x);
  check('dragged position persisted', Math.abs(savedX - box1.x) < 3, String(savedX));
  await demo.click('.scc-head-actions .scc-iconbtn:last-child');
  await sleep(300);
  check('minimizes to pill', await demo.locator('.scc-pill').isVisible());
  await demo.screenshot({ path: path.join(shots, '07-minimized.png') });
  await demo.click('.scc-pill');
  await sleep(300);
  check('restores from pill', await demo.locator('.scc-panel').isVisible());

  // settings persistence to chrome.storage.local
  await demo.evaluate(() => window.__scc.state.set('cfg.aiming.fovRadius', 321));
  await sleep(500);
  const stored = await sw.evaluate(async () => (await chrome.storage.local.get('scc.config'))['scc.config'].aiming.fovRadius);
  check('settings persisted in chrome.storage.local', stored === 321, String(stored));

  // record + replay
  await demo.click('.scc-tbtn[aria-label="Record"]');
  await sleep(2200);
  await demo.click('.scc-tbtn[aria-label="Record"]');
  const frames = await demo.evaluate(() => window.__scc.app.recorder.frames.length);
  check('recorded frames', frames > 40, String(frames));
  await demo.click('.scc-tbtn[aria-label="Replay"]');
  await sleep(800);
  check('replay mode active', await demo.evaluate(() => !!window.__scc.app.replay));
  await demo.screenshot({ path: path.join(shots, '08-replay.png') });
  await demo.click('.scc-tbtn[aria-label="Replay"]');

  // saved configuration
  await demo.click('#scc-tab-settings');
  await demo.fill('.scc-plist ~ * input, .scc-inline .scc-input', 'QA setup').catch(() => {});
  await demo.evaluate(() => {
    const inp = document.querySelector('.scc-inline > .scc-input[type=text]');
    inp.value = 'QA setup';
  });
  await demo.click('.scc-inline:has(> .scc-input[type=text]) > .scc-btn.primary');
  await sleep(400);
  check('profile saved', await demo.evaluate(() => !!window.__scc.state.data.loc.profiles['QA setup']));

  // reset to defaults (two-step confirm) keeps saved profiles
  await demo.click('#scc-tab-settings');
  await demo.evaluate(() => { document.querySelector('.scc-body').scrollTop = 99999; });
  await demo.click('.scc-page.on .scc-btn.danger');
  await demo.click('.scc-page.on .scc-btn.danger');
  await sleep(400);
  check('reset restores defaults', (await demo.evaluate(() => window.__scc.state.data.cfg.aiming.fovRadius)) === 200);
  check('reset keeps saved profiles', await demo.evaluate(() => !!window.__scc.state.data.loc.profiles['QA setup']));

  // ---------------------------------------------------------------- performance boost (demo)
  await demo.click('#scc-tab-perf');
  await sleep(2500);
  const fpsText = await demo.locator('.pf-fps').textContent();
  check('live FPS measured from real frames', /^\d+$/.test(fpsText) && Number(fpsText) > 5, fpsText);
  await demo.screenshot({ path: path.join(shots, '12-demo-perf.png') });
  const benchRes = await demo.evaluate(async () => {
    const p = window.__scc.perf;
    await p.runBenchmark('before', 5);
    await p.runBenchmark('after', 5);
    return p.comparison();
  });
  check('before/after benchmark produces a comparison', !!benchRes && benchRes.rows.length === 5, benchRes && benchRes.verdict);
  check('A/A comparison does not claim improvement', benchRes && benchRes.verdict !== 'improved', benchRes && `${benchRes.verdict} p=${benchRes.p.toFixed(2)}`);
  await demo.click('.pf-pbtn[data-id="maxfps"]');
  await sleep(300);
  check('MAX FPS preset turns on lightweight dashboard', await demo.evaluate(() => window.__scc.state.data.cfg.perf.liteUi && document.querySelector('.scc-root.floating').classList.contains('lite')));
  check('preset result lists game settings as unavailable in demo', /Not on this page/.test(await demo.locator('.pf-result').textContent()));
  await demo.evaluate(() => window.__scc.perf.restoreOriginal());
  await sleep(200);
  check('restore original undoes preset', await demo.evaluate(() => window.__scc.state.data.cfg.perf.liteUi === false && window.__scc.state.data.loc.perf.original === null));

  // ---------------------------------------------------------------- popup
  const pop = await ctx.newPage();
  hook(pop, 'popup');
  await pop.setViewportSize({ width: 400, height: 590 });
  await pop.goto(`chrome-extension://${extId}/src/popup/popup.html`);
  await pop.waitForSelector('.scc-panel');
  await sleep(600);
  await pop.screenshot({ path: path.join(shots, '09-popup.png') });
  check('popup shows synced FOV setting (after reset)', await pop.evaluate(() => { const v = [...document.querySelectorAll('.scc-val')].map((e) => e.textContent); return v.includes('200 px'); }));
  await pop.click('#scc-tab-settings');
  await sleep(400);
  await pop.screenshot({ path: path.join(shots, '10-popup-settings.png') });

  // cross-context sync: change in popup, observe in demo
  await pop.evaluate(async () => { await chrome.storage.local.get(null); });
  await pop.click('.scc-tabs #scc-tab-aiming');
  await pop.evaluate(() => { document.querySelector('.scc-card .scc-switch').click(); });
  await sleep(700);
  const synced = await demo.evaluate(() => window.__scc.state.data.cfg.aiming.enabled);
  check('popup change syncs to demo page', synced === false);

  // ---------------------------------------------------------------- dev API overlay on localhost
  const dev = await ctx.newPage();
  hook(dev, 'dev');
  await dev.goto(`http://localhost:${port}/dev-api-example/index.html`);
  await sleep(4500);
  const hostExists = await dev.evaluate(() => !!document.getElementById('scc-overlay-host'));
  check('overlay auto-attached after handshake', hostExists);
  await dev.mouse.move(900, 400);
  await sleep(600);
  await dev.screenshot({ path: path.join(shots, '11-dev-overlay.png') });

  // ---------------------------------------------------------------- game settings integration (example mirrors the client)
  await dev.evaluate(() => localStorage.removeItem('example_config'));
  await dev.reload();
  await sleep(2500);
  await dev.click('#scc-tab-perf');
  await sleep(800);
  check('game settings controls detected', (await dev.locator('.scc-page.on .pf-gs-row').count()) === 4);
  await dev.screenshot({ path: path.join(shots, '13-dev-perf.png') });
  await dev.click('.pf-pbtn[data-id="maxfps"]'); // MAX FPS
  await sleep(300);
  const afterApply = await dev.evaluate(() => ({ shake: document.getElementById('screenShake').checked, hi: document.getElementById('highResTex').checked }));
  check('MAX FPS switched screen shake off via the game control', afterApply.shake === false);
  check('high-res textures NOT changed without reload consent', afterApply.hi === true);
  await Promise.all([dev.waitForEvent('load'), dev.getByText('Apply & reload now').click()]);
  await sleep(2500);
  check('after consented reload, high-res textures are off (game persisted it)', await dev.evaluate(() => document.getElementById('highResTex').checked === false));
  await dev.click('#scc-tab-perf');
  await sleep(500);
  await dev.evaluate(() => { const b = [...document.getElementById('scc-overlay-host').shadowRoot.querySelectorAll('.scc-btn')].find((x) => /Restore original settings/.test(x.textContent)); b.click(); });
  await sleep(300);
  check('restore original re-enables screen shake', await dev.evaluate(() => document.getElementById('screenShake').checked === true));

  // network probe against an authorized same-origin endpoint
  await sw.evaluate(async () => {
    const c = (await chrome.storage.local.get('scc.config'))['scc.config'];
    c.perf.net = { probe: true, endpoint: '/dev-api-example/index.html', intervalSec: 2 };
    await chrome.storage.local.set({ 'scc.config': c });
  });
  await sleep(5500);
  const probeTxt = await dev.evaluate(() => [...document.getElementById('scc-overlay-host').shadowRoot.querySelectorAll('.scc-stat')].map((e) => e.textContent).join('|'));
  check('latency probe reports real RTT samples', /\d+msavg · jitter/.test(probeTxt), probeTxt.split('|').filter((t) => /Probe|avg/.test(t)).join(' '));
  check('game ping not invented when page does not expose it', /—not exposed by page/.test(probeTxt));

  await dev.close(); // one game tab at a time for the auto-optimizer test

  // auto optimizer under a sustained (synthetic, test-only) heavy load
  await sw.evaluate(async () => {
    const c = (await chrome.storage.local.get('scc.config'))['scc.config'];
    c.perf.net.probe = false;
    c.perf.autoOptimize = true;
    c.perf.targetFps = 60;
    c.perf.preset = '';
    await chrome.storage.local.set({ 'scc.config': c });
    const l = (await chrome.storage.local.get('scc.local'))['scc.local'];
    l.perf.autoLog = [];
    await chrome.storage.local.set({ 'scc.local': l });
  });
  const heavy = await ctx.newPage();
  hook(heavy, 'heavy');
  await heavy.goto(`http://localhost:${port}/dev-api-example/index.html?load=35`);
  await heavy.bringToFront();
  const hiBefore = await heavy.evaluate(() => document.getElementById('highResTex').checked);
  await sleep(16000);
  let log = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].perf.autoLog);
  check('auto optimizer stepped down after sustained low FPS', log.length >= 1 && log[0].to === 'balanced', log[0] && log[0].reason);
  await sleep(14000);
  log = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].perf.autoLog);
  check('auto optimizer measured the effect honestly', log[0] && log[0].after && /No measurable|%/.test(log[0].effect), log[0] && log[0].effect);
  await heavy.click('#scc-tab-perf');
  await heavy.evaluate(() => { const r = document.getElementById('scc-overlay-host').shadowRoot; r.querySelector('.scc-body').scrollTop = 1400; });
  await sleep(600);
  await heavy.screenshot({ path: path.join(shots, '14-auto-optimizer.png') });
  check('auto optimizer did not touch reload-type settings', (await heavy.evaluate(() => document.getElementById('highResTex').checked)) === hiBefore);
  check('auto log explains reason + changes', !!(log[0] && log[0].reason && Array.isArray(log[0].changes)), log[0] && log[0].changes.join(' · '));
  await sw.evaluate(async () => {
    const c = (await chrome.storage.local.get('scc.config'))['scc.config'];
    c.perf.autoOptimize = false;
    await chrome.storage.local.set({ 'scc.config': c });
  });
  await heavy.close();

  // wrong token must be rejected
  const bad = await ctx.newPage();
  hook(bad, 'bad');
  await bad.addInitScript(() => { window.__badToken = true; });
  await bad.route('**/dev-api-example/main.js', async (route) => {
    const resp = await route.fetch();
    const body = (await resp.text()).replace("const TOKEN = 'scc-dev-token'", "const TOKEN = 'wrong-token'");
    await route.fulfill({ response: resp, body });
  });
  await bad.goto(`http://localhost:${port}/dev-api-example/index.html`);
  await sleep(3500);
  const badState = await bad.evaluate(() => {
    const host = document.getElementById('scc-overlay-host');
    const cv = host && host.shadowRoot.querySelector('.scc-canvas');
    return { host: !!host, canvasShown: !!cv && cv.style.display !== 'none' };
  });
  check('wrong token: adapter rejected, overlay draws nothing', !badState.canvasShown, JSON.stringify(badState));
  await bad.click('#scc-tab-settings');
  await sleep(1300);
  check('wrong token: Settings shows Rejected', /Rejected/.test(await bad.locator('.scc-dev-label').textContent()));

  // public host must never attach (content script isn't even injected; verify via 127.0.0.2? loopback allowed) -> use unrelated origin
  const pub = await ctx.newPage();
  await pub.route('https://example.com/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html><body>public</body></html>' }));
  await pub.goto('https://example.com/');
  await sleep(1200);
  check('no overlay on a public site', !(await pub.evaluate(() => !!document.getElementById('scc-overlay-host'))));

  const real = errors.filter((e) => !/favicon|ERR_FAILED|Failed to load resource/i.test(e));
  check('no console/page errors', real.length === 0, real.slice(0, 5).join(' | '));
  await ctx.close();
  server.close();
  console.log(failures ? `\n${failures} check(s) FAILED` : '\nAll checks passed');
  console.log('screenshots:', shots);
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
