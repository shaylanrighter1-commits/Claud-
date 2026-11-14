// Renders assets/icons/logo.svg to PNG icons (16/48/128). Dev-time only; requires Playwright.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const dir = path.join(__dirname, '..', 'assets', 'icons');
(async () => {
  const svg = fs.readFileSync(path.join(dir, 'logo.svg'), 'utf8');
  const browser = await chromium.launch();
  for (const size of [16, 48, 128]) {
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(`<style>html,body{margin:0;background:transparent}svg{width:${size}px;height:${size}px;display:block}</style>${svg}`);
    await page.screenshot({ path: path.join(dir, `icon${size}.png`), omitBackground: true });
    await page.close();
  }
  await browser.close();
  console.log('icons written');
})();
