// Fictional receipt data served only on loopback; no real service requests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const origin = 'http://127.0.0.1:17866';
const source = fs.readFileSync(path.join(__dirname, '../Y3Client/LegacySiteSupport.swift'), 'utf8');
const reportSource = fs.readFileSync(path.join(__dirname, '../Y3Client/ReportPresentation.swift'), 'utf8');
const script = (source, name) => {
  const match = source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`));
  assert(match, `Missing ${name}`);
  return match[1].replaceAll('https://adidas-y3.poscmcloud.jp:15505', origin);
};
const adapt = ['viewportAndTouch', 'mobileRedesign', 'inventoryPresentation'].map(name => script(source, name)).concat(script(reportSource, 'script')).join('\n');
const discovery = script(source, 'discoverFrames');
const base = '/scripts/verona/print/prtz096';
(async () => {
  const server = spawn('python3', [path.join(__dirname, 'WebKitHarness/serve_fixtures.py'), '--port', '17866'], { stdio: 'ignore' });
  let browser;
  try {
    for (let index = 0; index < 100; index++) {
      try { if ((await fetch(origin + '/health')).ok) break; } catch (_) {}
      await new Promise(resolve => setTimeout(resolve, 30));
    }
    browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, args: ['--no-sandbox'] });
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/*', async route => {
      if (!route.request().url().startsWith(origin + '/')) return route.abort();
      const response = await route.fetch();
      let body = await response.text();
      const injection = `<script>${body.includes('</body>') ? adapt : `document.addEventListener('DOMContentLoaded',()=>{${adapt}\n},{once:true});`}</script>`;
      body = body.includes('</body>') ? body.replace('</body>', () => injection + '</body>') : body.replace('</head>', () => injection + '</head>');
      await route.fulfill({ response, body });
    });
    for (const query of ['late=&mode=&reverse=', 'late=header&mode=&reverse=1', 'late=data&mode=&reverse=', 'late=&mode=retain-header&reverse=']) {
      await page.goto(origin + base + '_2.asp?' + query);
      // BrowserModel discovers and reconciles panes repeatedly while responses arrive.
      await page.waitForFunction(() => { window.__y3ClientReportMerge?.reconcile(); return !!Array.from(frames).find(frame => frame.document.documentElement.hasAttribute('data-y3client-report-primary')); });
      const panes = await page.evaluate(discovery);
      assert.equal(panes.filter(pane => pane.kind === 'result').length, 1, query);
      assert.equal(panes.find(pane => pane.kind === 'result').title, '検索結果', query);
      assert.deepEqual(errors, [], query);
      const data = page.frames().find(frame => frame.name() === 'receipt-data');
      const header = page.frames().find(frame => frame.name() === 'receipt-header');
      assert.equal(await data.locator('[data-y3client-report-combined]').count(), 1, query);
      assert.equal(await data.evaluate(() => fixtureDataOriginals.form === document.getElementById('receipt-data-form') && fixtureDataOriginals.table === document.getElementById('receipt-table') && fixtureDataOriginals.button === document.querySelector('input[name=detail]') && fixtureOriginalDetailHandler === fixtureDataOriginals.button.onclick), true);
      await data.locator('input[name=detail]').first().click();
      assert.equal(await data.evaluate(() => fixtureDetailClicks), 1);
      assert.equal(await page.evaluate(() => fixtureDetailWindow), 'receipt-data');
      assert.equal(await data.locator('[data-y3client-report-fields] div').count(), 4, 'Empty conditions are omitted');
      assert.equal(await data.locator('[data-y3client-report-caption]').allTextContents().then(values => values.some(value => value.includes('99:59:59'))), false);
      assert.equal(await data.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, query);
      const before = await page.evaluate(() => __y3ClientNavigation.submissionRevision);
      await data.locator('[data-y3client-report-pages] select').selectOption('2');
      await data.locator('[data-y3client-report-pages] button').click();
      await page.waitForFunction(retainHeader => {
        window.__y3ClientReportMerge?.reconcile();
        const header=Array.from(frames).find(frame=>frame.name==='receipt-header');
        if(!retainHeader&&header.fixtureReceiptRequest?.method!=='POST')return false;
        const data=Array.from(frames).find(frame=>frame.name==='receipt-data');
        return data?.document.querySelector('[data-y3client-report-combined]') && data.document.getElementById('receipt-table').textContent.includes('FICTIONAL-PAGE2-1');
      }, query.includes('retain-header'));
      assert.equal(await page.evaluate(() => __y3ClientNavigation.submissionRevision), before + 1, 'One delegated click counts once');
      assert.equal(await page.evaluate(() => __y3ClientNavigation.resultSubmissionRevision === __y3ClientNavigation.submissionRevision), true, query);
      assert.equal(await page.evaluate(() => fixturePagerClicks), 1);
      assert.equal(await page.evaluate(() => fixturePagerWindow), 'receipt-header');
      if (!query.includes('retain-header')) assert.deepEqual(await header.evaluate(() => fixtureReceiptRequest), { method: 'POST', values: { unchanged: ['FICTIONAL-RECEIPT-TOKEN'], PgMax: ['2'], PgSelect: ['2'] } });
      assert.equal((await page.evaluate(discovery)).filter(pane => pane.kind === 'result').length, 1);
      await header.evaluate(() => { document.querySelector('input[name=hyouzi]').disabled = true; top.__y3ClientReportMerge.reconcile(); });
      assert.equal(await data.locator('[data-y3client-report-pages] button').isDisabled(), true, 'Pager availability follows original control');
      await header.evaluate(() => { document.querySelector('input[name=hyouzi]').disabled = false; top.__y3ClientReportMerge.reconcile(); });
      // A new search may refresh either half first. Never combine the new date with old rows.
      await page.evaluate(() => {
        const header=Array.from(frames).find(frame=>frame.name==='receipt-header');
        __y3ClientNavigation.submissionRevision++;
        header.document.getElementById('receipt-summary').rows[4].cells[1].textContent='2026/10/18 15:00:00 現在';
        __y3ClientNavigation.resultSubmissionRevision=__y3ClientNavigation.submissionRevision;
        __y3ClientReportMerge.reconcile();
      });
      assert.equal(await data.locator('[data-y3client-report-combined]').count(), 0);
      assert.equal(await page.evaluate(() => __y3ClientNavigation.resultSubmissionRevision), 0);
      await page.evaluate(() => {
        const data=Array.from(frames).find(frame=>frame.name==='receipt-data');
        data.document.getElementById('receipt-table').rows[1].cells[3].textContent='FICTIONAL-NEW-SEARCH';
        __y3ClientReportMerge.reconcile();
      });
      assert.equal(await data.locator('[data-y3client-report-combined]').count(), 1);
    }
    await page.goto(origin + base + '_2.asp?mode=empty');
    await page.waitForFunction(() => { window.__y3ClientReportMerge?.reconcile(); return !!frames['receipt-data'].document.querySelector('[data-y3client-report-combined]'); });
    assert.equal((await page.evaluate(discovery)).filter(pane => pane.kind === 'result').length, 1);
    assert.equal(await page.frames().find(frame => frame.name() === 'receipt-data').locator('#receipt-empty').textContent(), '該当データがありません。');
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ status:'passed', checks:['one receipt result in both frame orders', 'late header and late data', 'source table/form/handler identities unchanged', 'frame-local detail action unchanged', 'original pager POST and hidden fields', 'data-only pager refresh', 'one logical submission per delegated click', 'no stale metadata and data mixing', 'empty conditions collapsed', 'end-of-day sentinel formatted', '390px body fit', 'original pager disabled state', 'explicit empty reports remain combined'], scope:'Fictional loopback Chromium fixtures only' }, null, 2));
  } finally { if (browser) await browser.close(); server.kill(); }
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
