// Fictional pages only. Model document-end injection once, then legacy HTML replacement.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const app = name => fs.readFileSync(path.join(__dirname, '../Y3Client', name), 'utf8');
const raw = (text, name) => text.match(new RegExp(`(?:static|private static) let ${name} = #"""([\\s\\S]*?)"""#`))[1];
const legacy = app('LegacySiteSupport.swift');
const scripts = ['viewportAndTouch', 'mobileRedesign', 'inventoryPresentation'].map(name => raw(legacy, name)).concat(raw(app('ReportPresentation.swift'), 'script'));
const template = raw(app('PageSupportPresentation.swift'), 'template');
assert.equal(template.split('/*__Y3_RENDER_SOURCES__*/').length, 2);
const bootstrap = template.replace('/*__Y3_RENDER_SOURCES__*/', () => scripts.map(source => `try {\n${source}\n} catch (_) {}`).join('\n'));
const origin = 'https://adidas-y3.poscmcloud.jp:15505';
const url = origin + '/scripts/verona/print/prtz030_2.asp';
const table = '<table id="source"><tr><th>品番</th><th>数量</th></tr><tr><td>FICTIONAL-A</td><td>7</td></tr><tr><td>FICTIONAL-B</td><td>3</td></tr></table>';
const replacement = '<!doctype html><html><head></head><body><h2>架空明細</h2><div id="late"></div></body></html>';
const shell = '<!doctype html><html><head></head><body><h2>架空の遅延レポート</h2><div id="late"></div></body></html>';
const readiness = () => ({
  phone: document.documentElement.hasAttribute('data-y3client-phone'),
  layout: document.documentElement.hasAttribute('data-y3client-layout'),
  touchStyle: !!document.getElementById('y3client-touch-style'),
  layoutStyle: !!document.getElementById('y3client-layout-base'),
  adapted: document.getElementById('source')?.getAttribute('data-y3client-result-list') === 'cards',
});
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || '/usr/bin/chromium', args: ['--no-sandbox'] });
  const baseline = [];
  try {
    for (const enabled of [false, true]) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const messages = [];
      await context.exposeBinding('recordStructure', (_, body) => { messages.push(body); });
      await context.route('**/*', route => route.request().url() === url ? route.fulfill({ contentType: 'text/html; charset=utf-8', body: shell }) : route.abort());
      await context.addInitScript(`window.webkit={messageHandlers:{y3PageStructureChanged:{postMessage:body=>window.recordStructure(body)}}};`);
      if (enabled) await context.addInitScript(bootstrap);
      await context.addInitScript(`document.addEventListener('DOMContentLoaded', () => { ${scripts.join('\n')} }, {once:true});`);
      const page = await context.newPage();
      await page.goto(url);
      await page.waitForTimeout(350);
      assert.deepEqual(await page.evaluate(readiness), { phone: true, layout: true, touchStyle: true, layoutStyle: true, adapted: false });
      await page.evaluate(markup => document.getElementById('late').innerHTML = markup, table);
      await page.waitForTimeout(450);
      const late = await page.evaluate(readiness);
      assert.equal(late.adapted, enabled, 'Late source table is adapted only with persistent support');
      await page.evaluate(markup => { document.open(); document.write(markup); document.close(); }, replacement);
      await page.waitForTimeout(150);
      await page.evaluate(markup => {
        document.getElementById('late').innerHTML = markup;
        window.originalSource = document.getElementById('source');
        window.originalSourceCells = Array.from(originalSource.rows).map(row => Array.from(row.cells).map(cell => cell.textContent));
        window.originalClick = 0;
        originalSource.addEventListener('click', () => originalClick++);
      }, table);
      await page.waitForTimeout(650);
      const replaced = await page.evaluate(readiness);
      if (enabled) {
        assert.deepEqual(replaced, { phone: true, layout: true, touchStyle: true, layoutStyle: true, adapted: true });
        assert.equal(await page.evaluate(() => originalSource === document.getElementById('source')), true, 'Keep original source nodes');
        assert.deepEqual(await page.evaluate(() => Array.from(originalSource.rows).map(row => Array.from(row.cells).map(cell => cell.textContent))), [['品番','数量'],['FICTIONAL-A','7'],['FICTIONAL-B','3']]);
        await page.evaluate(() => originalSource.click());
        assert.equal(await page.evaluate(() => originalClick), 1, 'Keep original handlers');
        await page.waitForTimeout(400);
        const settled = messages.length;
        await page.evaluate(() => {
          window.fixtureTimer = setInterval(() => document.documentElement.setAttribute('rows', '100,*'), 25);
          const generated = document.createElement('div'); generated.setAttribute('data-y3client-report-combined', '');
          document.body.appendChild(generated);
          window.fixtureGenerated = setInterval(() => { generated.textContent = String(Date.now()); }, 40);
        });
        await page.waitForTimeout(250);
        await page.evaluate(() => {
          const table = document.createElement('table'); table.id = 'second-source';
          table.innerHTML = '<tr><th>店舗</th><th>数量</th></tr><tr><td>FICTIONAL-C</td><td>1</td></tr>';
          document.body.appendChild(table);
        });
        await page.waitForTimeout(350);
        assert.equal(await page.locator('#second-source').getAttribute('data-y3client-result-list'), 'cards', 'Generated activity cannot starve a later source table');
        await page.evaluate(() => { clearInterval(fixtureTimer); clearInterval(fixtureGenerated); });
        await page.waitForTimeout(250);
        assert.equal(messages.length, settled + 1, 'Only the later source table restarts discovery, not generated activity or source attribute timers');
        assert(messages.length >= 3 && messages.length <= 6, `Bounded structural messages: ${messages.length}`);
        assert(messages.every(body => body === true), 'Bridge sends boolean readiness only');
      } else {
        assert.equal(replaced.phone, false, 'Baseline faithfully loses document-end support after document.open');
        assert.equal(replaced.adapted, false);
        baseline.push({ lateTableUnadapted: !late.adapted, rewrittenDocumentLostSupport: !replaced.phone });
      }
      await context.close();
    }
    console.log(JSON.stringify({ status: 'passed', baseline, restoredAfterDocumentOpen: true, lateSourceTableAdapted: true, sourceNodesAndHandlersPreserved: true, boolOnlyBoundedNotifications: true }));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
