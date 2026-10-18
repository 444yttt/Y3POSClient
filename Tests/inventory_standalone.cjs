// Fictional detail screen. Every browser request is fulfilled locally or blocked.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const origin = 'https://adidas-y3.poscmcloud.jp:15505';
const source = fs.readFileSync(path.join(__dirname, '../Y3Client/LegacySiteSupport.swift'), 'utf8');
const script = name => source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`))[1];
const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/inventory-standalone-detail.html'), 'utf8');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || '/usr/bin/chromium', args: ['--no-sandbox'] });
  try {
    for (const width of [390, 320]) {
      const context = await browser.newContext({ viewport: { width, height: 844 }, isMobile: true, hasTouch: true });
      let blocked = 0;
      await context.route('**/*', async route => {
        if (route.request().url() === origin + '/scripts/verona/print/prtz015_2_2.asp') return route.fulfill({ contentType: 'text/html; charset=utf-8', body: fixture });
        blocked++; await route.abort();
      });
      // Match WK production injection: scripts are installed at document end, before
      // the site's load handler asynchronously builds its frozen inventory matrix.
      await context.addInitScript({ content: `document.addEventListener('DOMContentLoaded',()=>{${['viewportAndTouch', 'mobileRedesign', 'inventoryPresentation'].map(script).join('\n')}});` });
      const page = await context.newPage();
      await page.goto(origin + '/scripts/verona/print/prtz015_2_2.asp');
      await page.locator('[data-y3client-inventory]').waitFor();
      assert.equal(await page.locator('[data-y3client-inventory]').count(), 1);
      assert.equal(await page.locator('[data-y3client-inventory-title]').innerText(), 'MOCK-F901');
      const color = page.locator('[data-y3client-color-code="MOCK-COLOR"]');
      const row = color.locator('[data-y3client-inventory-size-row][data-y3client-size-code="313"]');
      assert((await row.innerText()).includes('JP 25.5'), 'Code 313 must use the confirmed JP footwear size');
      assert.deepEqual((await row.locator('td').allTextContents()).slice(1), ['1', '1']);
      const totals = await color.locator('[data-y3client-inventory-total] dd').allTextContents();
      assert.deepEqual(totals, ['006', '0', '-', '7'], 'Supplied totals stay textual and are not recomputed');
      const before = await page.evaluate(() => JSON.stringify(window.__y3InventoryPresentation.parseInventoryTable(document.getElementById('STOCK_H'))));
      for (const [unit, expected] of [['US', '7.5'], ['USW', '8.5'], ['UK', '7'], ['EU', '40 2/3'], ['CH', '250'], ['JP', '25.5']]) {
        await page.locator(`[data-y3client-size-unit="${unit}"]`).click();
        assert((await row.locator('td').first().innerText()).includes(expected));
        assert.deepEqual((await row.locator('td').allTextContents()).slice(1), ['1', '1']);
      }
      await color.locator('summary').click();
      const details = color.locator('[data-y3client-inventory-detail-row][data-y3client-size-code="313"]');
      assert.deepEqual((await details.locator('td').allTextContents()).slice(1), ['0', '-']);
      await page.locator('[data-y3client-inventory-stock-filter]').check();
      assert.equal(await color.locator('[data-y3client-inventory-size-row]').count(), 5, 'Only explicit zero is filtered; blank and negative survive');
      await page.locator('[data-y3client-inventory-table-button]').click();
      assert.equal(await page.locator('[data-y3client-inventory-raw]').isVisible(), true);
      assert.equal(await page.locator('[data-y3client-inventory]').isVisible(), false);
      await page.locator('[data-y3client-inventory-raw] a').click();
      assert.equal(await page.evaluate(() => window.fixtureProductClicks), 1);
      await page.locator('[data-y3client-inventory-raw] [data-y3client-inventory-back]').click();
      await page.locator('[data-y3client-inventory-view] > [data-y3client-inventory-back]').click();
      assert.equal(await page.evaluate(() => window.fixtureBackClicks), 1, 'Original return action is delegated exactly once');
      assert.equal(await page.evaluate(() => JSON.stringify(window.__y3InventoryPresentation.parseInventoryTable(document.getElementById('STOCK_H')))), before, 'UI and unit/filter changes preserve every original cell');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
      await page.evaluate(() => { document.getElementById('STOCK_H').rows[3].cells[3].textContent = '12'; });
      await page.waitForFunction(() => document.querySelector('[data-y3client-color-code="MOCK-COLOR"] [data-y3client-inventory-size-row] td:nth-child(2)')?.textContent === '12');
      await page.evaluate(() => { document.getElementById('STOCK_H').rows[3].cells[1].textContent = '未対応の列'; });
      await page.waitForFunction(() => !document.querySelector('[data-y3client-inventory]'));
      assert.equal(await page.locator('#STOCK_H').isVisible(), true, 'An unsupported update restores the original table');
      assert.equal(blocked, 0);
      await context.close();
    }
    console.log(JSON.stringify({ standaloneStockDetail: true, asyncGrid: true, allMetricsAndTotalsPreserved: true, sizeUnits: 6, sourceActions: true, phoneWidths: [390, 320], unsupportedFallback: true }));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
