// Fictional layouts only: every request is fulfilled locally or aborted.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const source = fs.readFileSync(path.join(__dirname, '../Y3Client/LegacySiteSupport.swift'), 'utf8');
const focus = source.match(/static let frameFocus = #"""([\s\S]*?)"""#/)[1];
const origin = 'https://adidas-y3.poscmcloud.jp:15505';
const frame = index => `<frame name="fixture-${index}" src="/leaf-${index}">`;
const cases = [
  { name: 'two rows and one explicit column', attrs: 'rows="100,*" cols="*"', count: 2 },
  { name: 'one explicit row and two columns', attrs: 'rows="*" cols="120,*"', count: 2 },
  { name: 'two-dimensional grid', attrs: 'rows="100,*" cols="120,*"', count: 4 },
  { name: 'implicit axes', attrs: '', count: 3 },
];
const snapshot = () => Array.from(document.querySelectorAll('frameset')).map(node => ({ rows: node.getAttribute('rows'), cols: node.getAttribute('cols') }));
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || '/usr/bin/chromium', args: ['--no-sandbox'] });
  try {
    for (const width of [390, 320]) {
      const context = await browser.newContext({ viewport: { width, height: 844 } });
      let layout = '';
      await context.route('**/*', route => {
        const url = new URL(route.request().url());
        if (url.origin !== origin) return route.abort();
        const leaf = url.pathname === '/timer-condition' ? '<html><body><div id="calendar" hidden>架空カレンダー</div><script>setInterval(()=>{parent.fixtureTimerTicks=(parent.fixtureTimerTicks||0)+1;parent.document.getElementById("timer-frameset").setAttribute("rows",document.getElementById("calendar").hidden?"100,*":"350,*")},200)</script></body></html>' : '<html><body><table><tr><th>架空明細</th></tr><tr><td>FICTIONAL</td></tr></table></body></html>';
        return route.fulfill({ contentType: 'text/html; charset=utf-8', body: url.pathname === '/root' ? layout : leaf });
      });
      const page = await context.newPage();
      for (const item of cases) {
        layout = `<html><head></head><frameset ${item.attrs}>${Array.from({ length: item.count }, (_, index) => frame(index)).join('')}</frameset></html>`;
        await page.goto(origin + '/root');
        const original = await page.evaluate(snapshot);
        await page.evaluate(() => { window.originalFrames = Array.from(document.querySelectorAll('frame')); });
        for (let selected = 0; selected < item.count; selected++) {
          assert.equal(await page.evaluate(`(${focus})([${selected}])`), true, item.name);
          const size = await page.evaluate(index => ({ width: frames[index].innerWidth, height: frames[index].innerHeight }), selected);
          assert(size.width >= width - 16 && size.height >= 800, `${item.name} child ${selected}: ${JSON.stringify(size)}`);
          assert.equal(await page.evaluate(() => originalFrames.every(node => node.isConnected && node.contentWindow)), true);
        }
        const selectedLayout = await page.evaluate(snapshot);
        assert.equal(await page.evaluate(`(${focus})([999])`), false);
        assert.deepEqual(await page.evaluate(snapshot), selectedLayout, 'Invalid focus preserves the selected layout');
        assert.equal(await page.evaluate(`(${focus})(null)`), true);
        assert.deepEqual(await page.evaluate(snapshot), original, item.name + ' restores exact source attributes');
      }
      layout = `<html><head></head><frameset rows="80,*" cols="*">${frame(0)}<frame src="/nested"></frameset></html>`;
      await context.route(origin + '/nested', route => route.fulfill({ contentType: 'text/html', body: `<html><head></head><frameset rows="*" cols="120,*">${frame(1)}${frame(2)}</frameset></html>` }));
      await page.goto(origin + '/root');
      const outer = await page.evaluate(snapshot);
      const inner = await page.frames().find(item => item.url() === origin + '/nested').evaluate(snapshot);
      assert.equal(await page.evaluate(`(${focus})([1,1])`), true);
      assert.equal(await page.evaluate(() => frames[1].frames[1].innerHeight >= 800 && frames[1].frames[1].innerWidth >= innerWidth - 24), true);
      await page.evaluate(`(${focus})(null)`);
      assert.deepEqual(await page.evaluate(snapshot), outer);
      assert.deepEqual(await page.frames().find(item => item.url() === origin + '/nested').evaluate(snapshot), inner);
      layout = '<html><head></head><frameset id="timer-frameset" rows="100,*" cols="*"><frame src="/timer-condition"><frame src="/leaf-result"></frameset></html>';
      await page.goto(origin + '/root');
      await page.evaluate(`(${focus})([1])`);
      await page.waitForTimeout(650);
      assert.equal(await page.evaluate(() => fixtureTimerTicks >= 3 && frames[1].innerHeight >= 800 && frames[0].innerHeight === 0), true, 'Daily datepicker timer must not undo result focus');
      await page.evaluate(() => { frames[0].document.getElementById('calendar').hidden = false; });
      await page.waitForTimeout(250);
      assert.equal(await page.evaluate(() => frames[1].innerHeight >= 800), true);
      await page.evaluate(`(${focus})([0])`);
      await page.waitForTimeout(250);
      assert.equal(await page.evaluate(() => frames[0].innerHeight >= 800 && frames[1].innerHeight === 0), true, 'Condition focus also survives its calendar timer');
      await page.evaluate(`(${focus})(null)`);
      await page.waitForTimeout(250);
      assert.equal(await page.locator('frameset').getAttribute('rows'), '350,*', 'Show all releases the guard and permits original calendar resizing');
      await context.close();
    }
    console.log(JSON.stringify({ status: 'passed', layouts: cases.map(item => item.name).concat('nested mixed axes'), widths: [390, 320], allSelectedFramesFillViewport: true, periodicSourceLayoutChangesProtected: true, showAllReleasesGuard: true, originalAttributesAndFrameNodesPreserved: true }));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
