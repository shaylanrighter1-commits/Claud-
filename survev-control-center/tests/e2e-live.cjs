// Live-site test (separate from the Demo Arena).
//   node tests/e2e-live.cjs [screenshotDir]          -> https://survev.io/ is served from tests/fixtures/survev-fixture.html
//   node tests/e2e-live.cjs [screenshotDir] --real   -> loads the REAL https://survev.io/ (needs network access)
// The fixture reproduces the markup/behaviour the extension relies on (see the comment at the top of the fixture).
const { chromium } = require('playwright');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');

const root = path.join(__dirname, '..');
const args = process.argv.slice(2);
const REAL = args.includes('--real');
const shots = args.find((a) => !a.startsWith('--')) || path.join(os.tmpdir(), 'scc-live-shots');
fs.mkdirSync(shots, { recursive: true });
const fixture = fs.readFileSync(path.join(__dirname, 'fixtures', 'survev-fixture.html'), 'utf8');

let failures = 0;
const check = (name, ok, extra = '') => {
  console.log(ok ? '  ✓' : '  ✗', name, extra);
  if (!ok) failures++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const ctx = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), 'scc-live-')), {
    headless: false,
    args: ['--headless=new', `--disable-extensions-except=${root}`, `--load-extension=${root}`, '--no-sandbox'],
    viewport: { width: 1440, height: 860 },
  });
  if (!REAL) {
    await ctx.route('https://survev.io/**', (route) => {
      const u = new URL(route.request().url());
      if (u.pathname === '/' || u.pathname === '/index.html') return route.fulfill({ contentType: 'text/html', body: fixture });
      return route.fulfill({ status: 404, body: '' });
    });
  }
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker', { timeout: 10000 });
  const extId = new URL(sw.url()).host;
  const errors = [];
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(e.stack || e.message));
  console.log(REAL ? 'Target: REAL https://survev.io/' : 'Target: https://survev.io/ served from the local fixture');

  await page.goto('https://survev.io/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForSelector('#scc-overlay-host', { state: 'attached', timeout: 20000 });
  await sleep(2500);
  const shadow = (fn) => page.evaluate(fn);
  check('dashboard loads on https://survev.io/', await page.locator('.scc-panel').isVisible());
  const tabs = await shadow(() => [...document.getElementById('scc-overlay-host').shadowRoot.querySelectorAll('.scc-tab')].map((t) => t.id.replace('scc-tab-', '')));
  check('only Performance, Pass and Settings tabs on the live site', JSON.stringify(tabs) === '["perf","pass","settings"]', tabs.join(','));
  check('no developer overlay canvas on the live site', await shadow(() => !document.getElementById('scc-overlay-host').shadowRoot.querySelector('.scc-canvas')));
  check('game canvas #cvs untouched and present', await page.evaluate(() => !!document.getElementById('cvs')));
  if (!REAL) check('no developer-API handshake sent to the live site', (await page.evaluate(() => window.__devHello)) === 0);
  await page.screenshot({ path: path.join(shots, 'live-01-perf.png') });

  // ---------------------------------------------------------------- compact / simple UI
  const ui = await page.evaluate(() => {
    const r = document.getElementById('scc-overlay-host').shadowRoot;
    const page = r.querySelector('.scc-page.on');
    const vis = [...page.querySelectorAll('.scc-card')].filter((c) => getComputedStyle(c).display !== 'none').map((c) => c.querySelector('.scc-card-tt b').textContent);
    return { width: Math.round(r.querySelector('.scc-float').getBoundingClientRect().width), visible: vis, simple: r.querySelector('.scc-root').classList.contains('simple') };
  });
  check('simple mode by default (advanced settings hidden)', ui.simple && ui.visible.length === 3, ui.visible.join(' · '));
  check('compact panel', ui.width <= 350, `${ui.width}px wide`);
  await page.click('.scc-head-actions .scc-iconbtn:last-child');
  await sleep(300);
  const pill = await page.locator('.scc-pill').boundingBox();
  check('minimizes to a small round icon', !!pill && pill.width <= 50 && pill.height <= 50, pill && `${Math.round(pill.width)}×${Math.round(pill.height)}px`);
  await page.screenshot({ path: path.join(shots, 'live-00-minimized.png') });
  await page.click('.scc-pill');
  await sleep(300);
  check('expands again from the icon', await page.locator('.scc-panel').isVisible());

  // re-injection into an already-open tab (what happens on install/update) must not create a second dashboard
  const injected = await sw.evaluate(async () => {
    const tabs = await chrome.tabs.query({ url: 'https://survev.io/*' });
    await chrome.scripting.executeScript({ target: { tabId: tabs[0].id }, files: ['src/content/loader.js'] });
    return tabs.length;
  });
  await sleep(1500);
  check('extension can inject into open survev.io tabs, without duplicates', injected >= 1 && (await page.evaluate(() => document.querySelectorAll('#scc-overlay-host').length)) === 1);

  // ---------------------------------------------------------------- performance
  await page.click('#scc-tab-perf');
  await sleep(1500);
  const fps = await page.locator('.pf-fps').textContent();
  check('real frame-rate measured on the site', /^\d+$/.test(fps) && Number(fps) > 5, `${fps} FPS`);
  check('measurement source labelled as survev.io', /survev\.io tab/.test(await page.locator('.pf-source').textContent()));
  const gsRows = await page.locator('.scc-page.on .pf-gs-row').allTextContents();
  check('all four game settings shown as switches', gsRows.length === 4, gsRows.map((t) => t.split('Game')[0].split('Applies')[0].trim()).join(' · '));
  const presetText = await page.locator('.pf-presets').textContent();
  check('presets do not offer dev-overlay effects on the live site', !/Dev overlay/.test(presetText));

  if (!REAL) {
    const g0 = await page.evaluate(() => ({ shake: document.getElementById('screenShake').checked, hi: document.getElementById('highResTex').checked, interp: document.getElementById('interpolation').checked }));
    await page.click('.pf-pbtn[data-id="maxfps"]'); // MAX FPS
    await sleep(300);
    const g1 = await page.evaluate(() => ({ shake: document.getElementById('screenShake').checked, hi: document.getElementById('highResTex').checked, interp: document.getElementById('interpolation').checked }));
    check('MAX FPS: screen shake off via the game checkbox', g0.shake === true && g1.shake === false);
    check('MAX FPS: high-res textures wait for reload consent', g1.hi === true);
    check('MAX FPS: interpolation untouched', g1.interp === g0.interp);
    await Promise.all([page.waitForEvent('load'), page.getByText('Apply & reload now').click()]);
    await page.waitForSelector('#scc-overlay-host', { state: 'attached' });
    await sleep(2000);
    check('after consented reload: high-res textures off (persisted by the page)', await page.evaluate(() => document.getElementById('highResTex').checked === false));

    // before/after benchmark through the UI (an advanced feature)
    await sw.evaluate(async () => {
      const c = (await chrome.storage.local.get('scc.config'))['scc.config'];
      c.perf.benchSeconds = 10;
      const l = (await chrome.storage.local.get('scc.local'))['scc.local'];
      l.ui.advanced = true;
      await chrome.storage.local.set({ 'scc.config': c, 'scc.local': l });
    });
    await page.click('#scc-tab-perf');
    await sleep(500);
    await page.getByText('Measure BEFORE').click();
    await sleep(11500);
    await page.getByText('Measure AFTER').click();
    await sleep(11500);
    const bench = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].perf.bench);
    check('before/after benchmark recorded real windows', !!(bench.before && bench.after && bench.before.frames > 100), bench.before && `${bench.before.avgFps.toFixed(1)} → ${bench.after.avgFps.toFixed(1)} FPS`);
    const verdict = await page.locator('.pf-verdict').textContent();
    check('benchmark verdict shown without unsupported claims', /No significant difference|Improvement measured|got worse|Not enough data/.test(verdict), verdict);
    await page.evaluate(() => { document.getElementById('scc-overlay-host').shadowRoot.querySelector('.scc-body').scrollTop = 1500; });
    await sleep(400);
    await page.screenshot({ path: path.join(shots, 'live-02-benchmark.png') });

    // restore everything (high-res needs the game's reload again)
    await page.evaluate(() => { const b = [...document.getElementById('scc-overlay-host').shadowRoot.querySelectorAll('.scc-btn')].find((x) => /Restore original settings/.test(x.textContent)); b.click(); });
    await sleep(300);
    check('restore original: screen shake back on', await page.evaluate(() => document.getElementById('screenShake').checked === true));
    await Promise.all([page.waitForEvent('load'), page.getByText('Apply & reload now').click()]);
    await page.waitForSelector('#scc-overlay-host', { state: 'attached' });
    await sleep(2000);
    check('restore original: high-res textures back on after reload', await page.evaluate(() => document.getElementById('highResTex').checked === true));
    await sw.evaluate(async () => {
      const l = (await chrome.storage.local.get('scc.local'))['scc.local'];
      l.ui.advanced = false;
      await chrome.storage.local.set({ 'scc.local': l });
    });
  }

  if (!REAL) {
    const shake0 = await page.evaluate(() => document.getElementById('screenShake').checked);
    await page.click('#scc-tab-perf');
    await page.locator('.scc-page.on .pf-gs-row', { hasText: 'Screen shake' }).locator('.scc-switch').click();
    await sleep(200);
    const shake1 = await page.evaluate(() => document.getElementById('screenShake').checked);
    check('game-setting switch toggles the game’s own checkbox', shake1 === !shake0);
    await page.locator('.scc-page.on .pf-gs-row', { hasText: 'Screen shake' }).locator('.scc-switch').click();
    await sleep(200);
  }

  // ---------------------------------------------------------------- input isolation
  if (!REAL) {
    await page.click('#scc-tab-perf');
    const before = await page.evaluate(() => ({ ...window.__game }));
    await page.click('#scc-tab-settings');
    await page.click('#scc-tab-perf');
    await sleep(100);
    const mid = await page.evaluate(() => ({ ...window.__game }));
    check('clicks on the dashboard do not reach the game', mid.mousedown === before.mousedown, `${before.mousedown} → ${mid.mousedown}`);
    await page.keyboard.press('KeyW');
    await sleep(100);
    const after = await page.evaluate(() => ({ ...window.__game }));
    check('movement keys reach the game right after using the dashboard', after.keydown > mid.keydown && after.keys.includes('KeyW'));
    await page.keyboard.press('Alt+KeyD');
    await sleep(250);
    check('Alt+D hides the dashboard', !(await page.locator('.scc-panel').isVisible()));
    const box = { x: 1200, y: 300 };
    await page.mouse.click(box.x, box.y);
    const hidden = await page.evaluate(() => window.__game.mousedown);
    check('when hidden, clicks in that area go to the game', hidden > after.mousedown);
    await page.keyboard.press('Alt+KeyD');
    await sleep(250);
    check('Alt+D shows it again', await page.locator('.scc-panel').isVisible());
  }

  // ---------------------------------------------------------------- pass
  await page.click('#scc-tab-pass');
  await sleep(800);
  const lvl = await page.locator('.ps-level').textContent();
  check('pass level read from #pass-progress-level', /^\d+$/.test(lvl), `level ${lvl}`);
  const quests = await page.locator('.ps-quest').count();
  check('daily quests read from #pass-quest-0/1', quests === 2, `${quests} quests`);
  if (!REAL) {
    await page.evaluate(() => window.__fixture.addXp(130));
    await sleep(3500);
    const hist = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].pass.history);
    const lv = hist.find((e) => e.kind === 'level');
    check('level-up + XP gain recorded after the animation settled', !!lv && lv.level === 2 && lv.gained === 130, lv && `L${lv.prevLevel}→L${lv.level} +${lv.gained}`);
    await page.evaluate(() => window.__fixture.completeQuest());
    await sleep(2200);
    const hist2 = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].pass.history);
    check('quest completion recorded', hist2.some((e) => e.kind === 'quest'));

    // auto claim OFF: the unlock window must wait for the player
    await page.evaluate(() => window.__fixture.grant(['Desert Camo', 'Fist Bump']));
    await sleep(2000);
    check('auto claim off: game window left for the player', await page.evaluate(() => document.getElementById('modal-item-confirm').style.display === 'block' && window.__fixture.acked.length === 1));
    await page.screenshot({ path: path.join(shots, 'live-03-pass-window.png') });
    // turn auto claim on through the UI
    await page.evaluate(() => {
      const r = document.getElementById('scc-overlay-host').shadowRoot;
      const card = [...r.querySelectorAll('.scc-card')].find((c) => /Auto claim/i.test(c.querySelector('.scc-card-tt b').textContent));
      card.querySelector('.scc-card-h > .scc-switch').click();
    });
    await sleep(3500);
    const fx = await page.evaluate(() => ({ acked: window.__fixture.acked.slice(), open: document.getElementById('modal-item-confirm').style.display }));
    check('auto claim confirms each already-granted item via the game button', fx.acked.join(',') === 'Desert Camo,Fist Bump' && fx.open === 'none', JSON.stringify(fx));
    let claims = await sw.evaluate(async () => (await chrome.storage.local.get('scc.local'))['scc.local'].pass.claims);
    check('claim history recorded', claims.length === 2 && claims[0].item === 'Desert Camo' && claims[0].source === 'auto', claims.map((c) => c.item).join(', '));
    // confirm-all mode
    await sw.evaluate(async () => {
      const c = (await chrome.storage.local.get('scc.config'))['scc.config'];
      c.pass.claimMode = 'all';
      await chrome.storage.local.set({ 'scc.config': c });
    });
    await sleep(300);
    await page.evaluate(() => window.__fixture.grant(['A', 'B', 'C']));
    await sleep(2000);
    const fx2 = await page.evaluate(() => ({ calls: window.__fixture.ackAllCalls, pending: window.__fixture.pending.length }));
    check('confirm-all mode uses the game’s [data-confirm-all] button', fx2.calls === 1 && fx2.pending === 0, JSON.stringify(fx2));
  }
  await page.evaluate(() => { document.getElementById('scc-overlay-host').shadowRoot.querySelector('.scc-body').scrollTop = 0; });
  await sleep(300);
  await page.screenshot({ path: path.join(shots, 'live-04-pass.png') });
  await page.locator('.scc-panel').screenshot({ path: path.join(shots, 'live-05-pass-panel.png') });

  // ---------------------------------------------------------------- popup
  const pop = await ctx.newPage();
  await pop.setViewportSize({ width: 400, height: 590 });
  await pop.goto(`chrome-extension://${extId}/src/popup/popup.html`);
  await pop.waitForSelector('.scc-panel');
  await sleep(500);
  check('popup is simple by default (Boost, Pass, Settings)', (await pop.locator('.scc-tab').count()) === 3);
  check('popup shows status line with version', /v1\.3\.0/.test(await pop.locator('#status').textContent()));
  await pop.screenshot({ path: path.join(shots, 'live-06-popup.png') });

  // The real site may log its own errors (e.g. blocked API/ad requests in a sandbox); only ours count here.
  const ours = errors.filter((e) => /chrome-extension:\/\//.test(e));
  if (errors.length !== ours.length) console.log(`  · ${errors.length - ours.length} page error(s) from the site's own code ignored (also occur without the extension)`);
  check('no errors from the extension', ours.length === 0, ours.slice(0, 3).join(' | '));
  await ctx.close();
  console.log(failures ? `\n${failures} check(s) FAILED` : '\nAll live-site checks passed');
  console.log('screenshots:', shots);
  process.exit(failures ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
