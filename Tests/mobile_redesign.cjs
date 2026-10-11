// Realistic synthetic records only. Every network request is intercepted locally.
// PLAYWRIGHT_MODULE=/workspace/scratch/xvfb/node_modules/playwright-core
// CHROMIUM_EXECUTABLE=/usr/bin/chromium node Tests/mobile_redesign.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const origin = 'https://adidas-y3.poscmcloud.jp:15505';
const sourcePath = path.join(__dirname, '../Y3Client/LegacySiteSupport.swift');
const outputPath = process.env.MOBILE_QA_OUTPUT || '/workspace/scratch/y3-mobile-redesign-qa';
const source = fs.readFileSync(sourcePath, 'utf8');
const getScript = name => {
  const match = source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`));
  assert(match, `Missing script ${name}`);
  return match[1];
};
const scripts = {
  before: getScript('viewportAndTouch'),
  adapt: getScript('viewportAndTouch') + '\n' + getScript('mobileRedesign'),
  navigationState: getScript('navigationState'),
};
const shell = body => `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空データによるUI確認</title><style>body{font:12px serif;margin:8px;background:#fff}table{border-collapse:collapse}td,th{border:1px solid #a9a9a9;padding:3px;white-space:nowrap}a{color:#003399}input,select,button{font:12px serif}h2{font:16px serif}</style></head><body>${body}</body></html>`;
const pages = {
  menu: '/scripts/verona/menu/metz010_1.asp',
  nestedMenu: '/scripts/verona/menu/metz010_2.asp',
  form: '/scripts/verona/dwh/prtz011_1.asp',
  stock: '/scripts/verona/dwh/prtz011_2.asp',
  daily: '/scripts/verona/dwh/prtz030_2_2.asp',
};
const fixtures = new Map([
  [origin + pages.menu, shell(`
    <script>function funcLinkSend(name,color){window.fixtureMenuClicks=(window.fixtureMenuClicks||0)+1;document.forms.frmForm.Title.value=name;document.forms.frmForm.ColorSEQ.value=color;document.forms.frmForm.requestSubmit();return false}</script>
    <form id="menu-form" name="frmForm" action="/fixture/menu-post" method="post" target="fixtureResults"><input type="hidden" name="Title" value=""><input type="hidden" name="ColorSEQ" value=""><input type="hidden" name="unchanged" value="synthetic-token"></form>
    <table width="760"><tr><td colspan="2">Y3 POS CM CLOUD　メニュー選択画面</td></tr>
    <tr><td bgcolor="#b7cddd" width="170">売上・日報</td><td><a id="menu-daily" href="javascript:void(0)" onclick="return funcLinkSend('日別売上照会','1')">日別売上照会</a><br><a id="menu-period" href="javascript:void(0)" onclick="return funcLinkSend('期間別売上照会','2')">期間別売上照会</a></td></tr>
    <tr><td bgcolor="#b7cddd">在庫・商品</td><td><a id="menu-stock" href="javascript:void(0)" onclick="return funcLinkSend('在庫照会','3')">在庫照会</a><br><a id="menu-products" href="javascript:void(0)" onclick="return funcLinkSend('商品マスター照会','4')">商品マスター照会</a></td></tr>
    <tr><td bgcolor="#b7cddd">データ出力</td><td><a id="menu-export" href="/fixture/export" target="fixtureResults" onclick="window.fixtureExportClicks=(window.fixtureExportClicks||0)+1">販売データエクスポート</a></td></tr></table>
    <iframe name="fixtureResults" src="/fixture/empty" hidden></iframe>
  `)],
  [origin + pages.nestedMenu, shell(`
    <script>function funcLinkSend(name,color){window.fixtureMenuClicks=(window.fixtureMenuClicks||0)+1;document.forms.frmForm.Title.value=name;document.forms.frmForm.ColorSEQ.value=color;document.forms.frmForm.requestSubmit();return false}</script>
    <form id="menu-form" name="frmForm" action="/fixture/menu-post" method="post" target="fixtureResults"><input type="hidden" name="Title" value=""><input type="hidden" name="ColorSEQ" value=""><input type="hidden" name="unchanged" value="synthetic-token"></form>
    <table id="fixture-logo" width="760"><tr><td><img alt="架空のロゴ" width="200" height="40" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/xioAAAAASUVORK5CYII="></td></tr></table>
    <table id="nested-business-table" width="760"><tr id="nested-menu-header"><td colspan="2" height="25" align="left">
      <table id="nested-tabs" align="left"><tr><td height="25"><a id="category-data" name="TitleNAME3" href="javascript:void(0)" onclick="return funcLinkSend('カテゴリ閲覧','3')">データ閲覧</a></td><td>.</td><td height="25"><a id="category-stock" name="TitleNAME4" href="javascript:void(0)" onclick="return funcLinkSend('カテゴリ在庫','4')">在庫管理</a></td><td>.</td><td height="25"><a id="category-export" name="TitleNAME7" href="javascript:void(0)" onclick="return funcLinkSend('カテゴリ出力','7')">エクスポート</a></td></tr></table>
      <table id="nested-account" align="right"><tr><td><font>架空店舗・架空スタッフ</font></td><td><a id="fixture-logout" href="javascript:void(0)" onclick="window.fixtureLogoutClicks=(window.fixtureLogoutClicks||0)+1;return false">POSCM - LOGOUT</a></td></tr></table>
    </td></tr>
    <tr><td colspan="2">&lt;販売情報&gt;</td></tr>
    <tr id="nested-daily-row"><td width="170"><font><a id="menu-daily" href="javascript:void(0)" onclick="return funcLinkSend('日別売上照会','1')">日別売上照会</a></font></td><td>日付ごとの販売実績を確認できます</td></tr>
    <tr><td><font><a id="menu-period" href="javascript:void(0)" onclick="return funcLinkSend('期間別売上照会','2')">期間別売上照会</a></font></td><td>期間を指定して販売状況を確認できます</td></tr>
    <tr><td colspan="2">&lt;在庫情報&gt;</td></tr>
    <tr><td><font><a id="menu-stock" href="javascript:void(0)" onclick="return funcLinkSend('在庫照会','3')">在庫照会</a></font></td><td>品番・エリアを指定して在庫を確認できます</td></tr>
    <tr><td><font><a id="menu-products" href="javascript:void(0)" onclick="return funcLinkSend('商品マスター照会','4')">商品マスター照会</a></font></td><td>登録されている商品の詳細を確認できます</td></tr>
    <tr><td><font><a id="menu-export" href="/fixture/export" target="fixtureResults" onclick="window.fixtureExportClicks=(window.fixtureExportClicks||0)+1">販売データエクスポート</a></font></td><td>販売データをファイルに保存できます</td></tr>
    </table><iframe name="fixtureResults" src="/fixture/empty" hidden></iframe>
  `)],
  [origin + pages.form, shell(`
    <script>function dispHinbanSearch(){var n=document.getElementById('layer0');n.style.display=n.style.display==='none'?'block':'none'}function SelectHinban(value){form1.m01_hinban.value=value;dispHinbanSearch()}</script>
    <a id="site-home" href="/scripts/verona/menu/metz010_1.asp" target="_top" onclick="window.fixtureHomeClicks=(window.fixtureHomeClicks||0)+1;return false">メニュー選択画面</a><h2>在庫照会</h2>
    <form id="search-form" name="form1" action="/fixture/search-post" method="post" target="fixtureResults" onsubmit="window.fixtureSubmitClicks=(window.fixtureSubmitClicks||0)+1">
    <input type="hidden" name="ft_mode" value="inventory"><input type="hidden" name="unchanged" value="synthetic-token">
    <table width="540"><tr><td width="120">品番</td><td><input id="product-field" name="m01_hinban" type="text" value="MOCK-A001" size="25"><input id="helper-toggle" type="button" value="品番検索" onclick="dispHinbanSearch()"></td></tr>
    <tr><td>対象エリア</td><td><select id="area-field" name="m91_zone_id"><option value="all">全エリア</option><option value="west">架空エリア 西</option></select></td></tr>
    <tr><td>表示区分</td><td><input id="radio-total" type="radio" name="ft_hyouzi" value="total" checked><label for="radio-total">集計</label><input id="radio-detail" type="radio" name="ft_hyouzi" value="detail"><label for="radio-detail">明細</label></td></tr>
    <tr><td>販売期間</td><td><input id="date-start" type="text" name="ft_fromYYYYMMDD" value="20261001" size="10"> ～ <input id="date-end" type="text" name="ft_toYYYYMMDD" value="20261011" size="10"></td></tr>
    <tr><td>出力項目</td><td><input id="check-stock" type="checkbox" name="ft_stock" value="1" checked><label for="check-stock">在庫数</label><input id="check-sales" type="checkbox" name="ft_sales" value="1"><label for="check-sales">販売数</label></td></tr>
    <tr><td colspan="2"><input id="submit-search" type="submit" value="検索"><input id="reset-search" type="reset" value="クリア"></td></tr></table></form>
    <span id="layer0" style="display:none;position:absolute;left:91px;top:91px;width:400px;height:200px"><iframe name="fraHinbanSearch" src="/fixture/helper" width="400" height="200"></iframe></span>
    <iframe name="fixtureResults" src="/fixture/empty" hidden></iframe>
  `)],
  [origin + pages.stock, shell(`
    <a href="/scripts/verona/menu/metz010_1.asp" target="_top">メニュー選択画面</a><h2>在庫照会結果（架空データ）</h2>
    <form id="pager-form" name="form1" method="post" action="/fixture/page-post"><input type="hidden" name="m01_hinban" value="MOCK-A001"><input type="hidden" name="PageCount" value="1"><input type="hidden" name="PgMax" value="2"><select id="page-select" name="PgSelect" onchange="window.fixturePageChanges=(window.fixturePageChanges||0)+1"><option value="1">1</option><option value="2">2</option></select></form>
    <div id="D_stock_H" style="position:absolute;width:770px;top:80px;left:8px;overflow:hidden"><table id="stock-header" width="770"><tbody><tr><th>品番</th><th>商品名</th><th>カラー</th><th>サイズ</th><th>在庫数</th><th>販売数</th></tr></tbody></table></div>
    <div id="D_stock_B" style="position:absolute;width:770px;top:108px;left:8px;overflow:auto"><table id="stock-data" width="770"><tbody>
    <tr><td>MOCK-A001</td><td><a id="product-detail" href="/fixture/detail" target="fixtureResults" onclick="window.fixtureDetailClicks=(window.fixtureDetailClicks||0)+1">架空のロングスリーブ トレーニングシャツ</a></td><td>BLACK</td><td>M</td><td align="right">12</td><td align="right">3</td></tr>
    <tr><td>MOCK-A002</td><td>架空のライトジャケット</td><td>WHITE</td><td>L</td><td align="right">7</td><td align="right">1</td></tr>
    <tr><td>MOCK-A003</td><td>架空のバッグ</td><td>BLUE</td><td>FREE</td><td align="right">4</td><td align="right">2</td></tr>
    </tbody></table></div><iframe name="fixtureResults" src="/fixture/empty" hidden></iframe>
  `)],
  [origin + pages.daily, shell(`
    <h2>日別売上集計（架空データ）</h2><table id="complex-grid" width="1050"><tbody>
    <tr><th rowspan="2">日付</th><th colspan="2">売上</th><th colspan="2">在庫</th><th colspan="2">返品</th><th colspan="2">客数</th></tr><tr><th>数量</th><th>金額</th><th>数量</th><th>金額</th><th>数量</th><th>金額</th><th>組数</th><th>人数</th></tr>
    <tr><td>2026/10/01</td><td>3</td><td>12,000</td><td>17</td><td>68,000</td><td>1</td><td>4,000</td><td>3</td><td>4</td></tr><tr><td>2026/10/02</td><td>5</td><td>20,000</td><td>12</td><td>48,000</td><td>0</td><td>0</td><td>4</td><td>6</td></tr><tr><td colspan="3">期間合計</td><td>12</td><td>48,000</td><td>1</td><td>4,000</td><td>7</td><td>10</td></tr>
    </tbody></table>
  `)],
  [origin + '/fixture/helper', shell(`<form id="helper-form"><table width="406"><tr><td>品番</td><td><input name="HINBAN" type="text" value="MOCK-A"></td></tr></table></form><a id="helper-select" href="javascript:void(0)" onclick="parent.SelectHinban('MOCK-SELECTED');return false">架空商品の選択</a>`)],
  [origin + '/fixture/empty', shell('')],
  [origin + '/fixture/menu-post', shell('<p>架空メニューPOST受信</p>')],
  [origin + '/fixture/search-post', shell('<p>架空検索POST受信</p>')],
  [origin + '/fixture/page-post', shell('<p>架空ページPOST受信</p>')],
  [origin + '/fixture/export', shell('<p>架空エクスポート</p>')],
  [origin + '/fixture/detail', shell('<p>架空商品詳細</p>')],
]);
const framedCondition = '/scripts/verona/print/prtz030_1_1.asp';
const framedResult = '/scripts/verona/print/prtz030_2_2.asp';
fixtures.set(origin + '/fixture/framed', `<html><head><title>架空フレーム帳票</title></head><frameset rows="115,*"><frame name="prtz030_1_1" src="${framedCondition}"><frame name="prtz030_2" src="${framedResult}"></frameset></html>`);
fixtures.set(origin + framedCondition, shell(`<form id="framed-search" name="form1" method="post" action="${framedResult}" target="prtz030_2"><table width="540"><tr><td>日付</td><td><input type="text" name="ft_YYYYMMDD_F" value="20261011"><input type="text" name="ft_YYYYMMDD_T" value="20261011"></td></tr><tr><td colspan="2"><input id="framed-submit" type="submit" value="検索"></td></tr></table><input type="hidden" name="synthetic_session" value="unchanged"></form>`));
fixtures.set(origin + framedResult, shell('<table id="framed-result-table" width="650"><tr><th>日付</th><th>品番</th><th>数量</th><th>金額</th></tr><tr><td>2026/10/11</td><td>MOCK-A001</td><td>3</td><td>12,000</td></tr><tr><td>2026/10/11</td><td>MOCK-A002</td><td>1</td><td>4,000</td></tr><tr><td>2026/10/11</td><td>MOCK-A003</td><td>2</td><td>8,000</td></tr><tr><td>2026/10/11</td><td>MOCK-A004</td><td>1</td><td>4,000</td></tr><tr><td>2026/10/11</td><td>MOCK-A005</td><td>1</td><td>4,000</td></tr></table>'));
const lateGrid = '/scripts/verona/dwh/prtz099_2.asp';
fixtures.set(origin + lateGrid, shell(`
  <h2>在庫照会結果（遅いグリッド初期化）</h2>
  <form id="late-pager" name="form1" method="post" action="/fixture/page-post"><input type="hidden" name="unchanged" value="late-synthetic"><select id="late-page-select" name="PgSelect" onchange="window.fixtureLatePageChanges=(window.fixtureLatePageChanges||0)+1"><option value="1">1</option><option value="2">2</option></select></form>
  <table id="late-source" width="770"><tr><th>品番</th><th>商品名</th><th>カラー</th><th>サイズ</th><th>在庫数</th><th>販売数</th></tr>
  <tr><td>MOCK-L001</td><td><a id="late-product-detail" href="javascript:void(0)" onclick="window.fixtureLateDetailClicks=(window.fixtureLateDetailClicks||0)+1;return false">架空の遅いグリッド商品</a></td><td>BLACK</td><td>M</td><td>12</td><td>3</td></tr>
  <tr><td>MOCK-L002</td><td>架空のジャケット</td><td>WHITE</td><td>L</td><td>7</td><td>1</td></tr><tr><td>MOCK-L003</td><td>架空のバッグ</td><td>BLUE</td><td>FREE</td><td>4</td><td>2</td></tr></table>
  <script>
    // Like the observed Tscroller, the site creates cloned H/B grids in its load handler.
    window.addEventListener('load', function () {
      const source = document.getElementById('late-source');
      const header = document.createElement('div'); header.id = 'D_late_H'; header.style.cssText = 'position:absolute;left:8px;top:80px;width:770px;overflow:hidden';
      const body = document.createElement('div'); body.id = 'D_late_B'; body.style.cssText = 'position:absolute;left:8px;top:108px;width:770px;overflow:auto';
      const headerTable = source.cloneNode(true); headerTable.id = 'late-header'; while (headerTable.rows.length > 1) headerTable.deleteRow(1);
      const bodyTable = source.cloneNode(true); bodyTable.id = 'late-data'; bodyTable.deleteRow(0);
      header.appendChild(headerTable); body.appendChild(bodyTable); source.replaceWith(header, body);
      const link = bodyTable.querySelector('#late-product-detail');
      window.fixtureLateObjects = { table: bodyTable, link: link, handler: link.onclick, pager: document.getElementById('late-page-select') };
      window.fixtureGridBuilt = true;
    }, { once: true });
  </script>
`));

const snapshotOriginals = page => page.evaluate(() => {
  window.fixtureOriginals = {
    forms: Array.from(document.forms),
    fields: Array.from(document.querySelectorAll('input[id],select[id]')),
    links: Array.from(document.querySelectorAll('a[id]')),
  };
  window.fixtureOriginalFields = fixtureOriginals.fields.map(field => ({ field, form: field.form, name: field.name, type: field.type, value: field.value }));
  window.fixtureOriginalHandlers = fixtureOriginals.links.map(link => [link, link.onclick]);
  window.fixtureOriginalFormState = fixtureOriginals.forms.map(form => ({
    form, method: form.method, target: form.target, action: form.action,
    hidden: Array.from(form.elements).filter(field => field.type === 'hidden').map(field => [field, field.name, field.value]),
  }));
});
const assertPreserved = async page => {
  assert.equal(await page.evaluate(() => Object.values(fixtureOriginals).flat().every(node => node.isConnected)), true, 'Original event-bearing nodes must remain connected');
  assert.equal(await page.evaluate(() => fixtureOriginalFields.every(({ field, form, name, type, value }) => field.form === form && field.name === name && field.type === type && field.value === value)), true, 'Controls must retain form ownership, names, types and values');
  assert.equal(await page.evaluate(() => fixtureOriginalHandlers.every(([link, handler]) => link.onclick === handler && (!link.id || document.getElementById(link.id) === link))), true, 'Links must keep their original identity and event handlers');
  assert.equal(await page.evaluate(() => fixtureOriginalFormState.every(state => state.form.method === state.method && state.form.target === state.target && state.form.action === state.action && state.hidden.every(([field, name, value]) => field.name === name && field.value === value))), true, 'Form ownership, method, target and hidden fields must stay intact');
};

async function main() {
  fs.mkdirSync(outputPath, { recursive: true, mode: 0o700 });
  fs.chmodSync(outputPath, 0o700);
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || '/usr/bin/chromium', args: ['--no-sandbox'] });
  const reports = [];
  try {
    for (const width of [390, 320]) {
      const context = await browser.newContext({ viewport: { width, height: 844 }, isMobile: true, hasTouch: true });
      const requests = [];
      const unknown = [];
      let framedPosts = 0;
      await context.route('**/*', async route => {
        const request = route.request();
        let body = fixtures.get(request.url());
        if (body === undefined) { unknown.push(request.url()); await route.abort(); return; }
        if (request.method() === 'POST') requests.push({ url: request.url(), body: new URLSearchParams(request.postData() || '') });
        if (request.url() === origin + framedResult && request.method() === 'POST') body = body.replace('<html lang="ja">', `<html lang="ja" data-fixture-post="${++framedPosts}">`);
        await route.fulfill({ contentType: 'text/html; charset=utf-8', body });
      });
      const page = await context.newPage();
      const adapt = async () => {
        for (const frame of page.frames()) await frame.evaluate(scripts.adapt);
        await page.waitForFunction(() => !!document.querySelector('meta[name="viewport"]'));
      };
      const interactionChecks = async kind => {
        if (kind === 'menu' || kind === 'nestedMenu') {
          const filter = page.locator('[data-y3client-menu-search]');
          assert.equal(await filter.count(), 1, 'Menu must expose a real search field');
          await filter.fill('在庫');
          assert.equal(await page.locator('#menu-stock').isVisible(), true);
          assert.equal(await page.locator('#menu-daily').isVisible(), false, 'Menu search should hide irrelevant items');
          await filter.fill('');
          assert.equal(await page.locator('#menu-daily').isVisible(), true);
          const menuBounds = await page.locator('#menu-daily,#menu-stock,#menu-export').evaluateAll(links => links.map(link => { const box = link.getBoundingClientRect(); return { left: box.left, right: box.right, height: box.height }; }));
          assert(menuBounds.every(box => box.left >= 0 && box.right <= width + 1 && box.height >= 44), 'Menu cards must fit phone width and provide touch targets');
          const pending = page.waitForRequest(request => request.url() === origin + '/fixture/menu-post');
          await page.locator('#menu-daily').click();
          const request = await pending;
          assert.equal(await page.evaluate(() => fixtureMenuClicks), 1, 'Preserved menu inline handler must run once');
          const posted = new URLSearchParams(request.postData() || '');
          assert.equal(request.method(), 'POST');
          assert.equal(posted.get('Title'), '日別売上照会');
          assert.equal(posted.get('ColorSEQ'), '1');
          assert.equal(posted.get('unchanged'), 'synthetic-token');
          assert.equal(await page.locator('#menu-form').getAttribute('target'), 'fixtureResults');
          if (kind === 'nestedMenu') {
            assert.equal(await page.locator('#fixture-logo').isVisible(), false, 'The legacy logo-only desktop table should not consume phone space');
            const layout = await page.evaluate(() => {
              const rect = element => { const box = element.getBoundingClientRect(); return { left: box.left, right: box.right, top: box.top, bottom: box.bottom, width: box.width, height: box.height }; };
              return { chips: Array.from(document.querySelectorAll('a[name^="TitleNAME"]')).map(rect), row: rect(document.getElementById('nested-daily-row')), link: rect(document.getElementById('menu-daily')) };
            });
            assert.equal(layout.chips.length, 3);
            assert(layout.chips.every(chip => chip.left >= 0 && chip.right <= width + 1 && chip.height >= 44), 'Nested category chips must fit and keep touch targets');
            assert(Math.max(...layout.chips.map(chip => chip.bottom)) <= layout.row.top, 'Nested chips must not overlap the business cards below');
            assert(layout.link.width >= layout.row.width - 38, 'FONT-wrapped business link must fill the card content width');
            const cardClick = page.waitForRequest(request => request.url() === origin + '/fixture/menu-post');
            await page.touchscreen.tap(layout.row.right - 20, layout.row.bottom - 10);
            assert.equal(new URLSearchParams((await cardClick).postData()).get('Title'), '日別売上照会', 'Tapping the card description must click the original business link');
            assert.equal(await page.evaluate(() => fixtureMenuClicks), 2);
            const categoryClick = page.waitForRequest(request => request.url() === origin + '/fixture/menu-post');
            await page.locator('#category-stock').click();
            const categoryPost = new URLSearchParams((await categoryClick).postData());
            assert.equal(categoryPost.get('Title'), 'カテゴリ在庫');
            assert.equal(categoryPost.get('ColorSEQ'), '4');
            assert.equal(categoryPost.get('unchanged'), 'synthetic-token');
            assert.equal(await page.evaluate(() => fixtureMenuClicks), 3, 'Category chips must retain their site-owned POST handler');
          }
        }
        if (kind === 'form') {
          assert(await page.locator('[data-y3client-field]').count() >= 5, 'Conditions must be grouped into labeled fields');
          const bounds = await page.locator('#product-field,#area-field,#date-start,#date-end,#submit-search,#reset-search').evaluateAll(fields => fields.map(field => { const box = field.getBoundingClientRect(); return { left: box.left, right: box.right, height: box.height }; }));
          assert(bounds.every(box => box.left >= 0 && box.right <= width + 1 && box.height >= 44), 'Input fields and actions must fit the phone without shrinking their touch area');
          assert.equal(await page.locator('#product-field,#area-field,#date-start,#date-end').evaluateAll(fields => fields.every(field => (field.labels && field.labels.length) || (field.getAttribute('aria-label') || '').trim() || (field.getAttribute('aria-labelledby') || '').split(/\s+/).some(id => document.getElementById(id)?.textContent.trim()))), true, 'Reorganized fields need accessible names');
          assert.equal(await page.locator('label[for="radio-detail"],label[for="check-sales"]').evaluateAll(labels => labels.every(label => label.getBoundingClientRect().height >= 44)), true, 'Radio and checkbox label targets must remain large enough to tap');
          await page.locator('label[for="radio-detail"]').click();
          assert.equal(await page.locator('#radio-detail').isChecked(), true);
          assert.equal(await page.locator('#radio-total').isChecked(), false);
          await page.locator('label[for="check-sales"]').click();
          assert.equal(await page.locator('#check-sales').isChecked(), true);
          await page.locator('#area-field').selectOption('west');
          await page.locator('#helper-toggle').click();
          const overlay = await page.locator('#layer0').evaluate(element => ({ display: getComputedStyle(element).display, left: element.getBoundingClientRect().left, right: element.getBoundingClientRect().right, width: innerWidth }));
          assert.notEqual(overlay.display, 'none');
          assert(overlay.left >= 0 && overlay.right <= width + 1, 'Open helper overlay must fit the phone');
          const helper = page.frames().find(frame => frame.name() === 'fraHinbanSearch');
          await helper.locator('#helper-select').click();
          assert.equal(await page.locator('#product-field').inputValue(), 'MOCK-SELECTED', 'Helper must still select into the original form field');
          assert.equal(await page.locator('#layer0').evaluate(element => getComputedStyle(element).display), 'none');
          await page.evaluate(scripts.adapt);
          assert.equal(await page.locator('#product-field').inputValue(), 'MOCK-SELECTED', 'Reapplying presentation must keep user input');
          assert.equal(await page.locator('#radio-detail').isChecked(), true);
          assert.equal(await page.locator('#check-sales').isChecked(), true);
          const pending = page.waitForRequest(request => request.url() === origin + '/fixture/search-post');
          await page.locator('#submit-search').click();
          const request = await pending;
          assert.equal(request.method(), 'POST');
          const posted = new URLSearchParams(request.postData() || '');
          assert.equal(posted.get('m01_hinban'), 'MOCK-SELECTED');
          assert.equal(posted.get('m91_zone_id'), 'west');
          assert.equal(posted.get('ft_hyouzi'), 'detail');
          assert.equal(posted.get('ft_sales'), '1');
          assert.equal(posted.get('ft_stock'), '1');
          assert.equal(posted.get('ft_mode'), 'inventory');
          assert.equal(posted.get('unchanged'), 'synthetic-token');
          assert.equal(posted.get('ft_fromYYYYMMDD'), '20261001');
          assert.equal(posted.get('ft_toYYYYMMDD'), '20261011');
          assert.equal(await page.evaluate(() => fixtureSubmitClicks), 1, 'Submit handler must remain attached');
          assert.equal(await page.locator('#search-form').getAttribute('target'), 'fixtureResults');
          await page.locator('#reset-search').click();
          assert.equal(await page.locator('#product-field').inputValue(), 'MOCK-A001');
          assert.equal(await page.locator('#radio-total').isChecked(), true);
          assert.equal(await page.locator('#check-sales').isChecked(), false);
        }
        if (kind === 'stock') {
          assert.equal(await page.locator('[data-y3client-result-list]').count(), 1, 'Simple frozen stock results should become a list');
          const cards = page.locator('[data-y3client-result-card]');
          assert.equal(await cards.count(), 3);
          assert.deepEqual(await cards.first().locator('td').evaluateAll(cells => cells.map(cell => cell.getAttribute('data-y3client-label'))), ['品番', '商品名', 'カラー', 'サイズ', '在庫数', '販売数'], 'Cards must map each value to the matching frozen header');
          const bounds = await cards.evaluateAll(rows => rows.map(row => { const box = row.getBoundingClientRect(); return { left: box.left, right: box.right }; }));
          assert(bounds.every(box => box.left >= 0 && box.right <= width + 1), 'Result cards must fit the phone');
          assert.notEqual(await cards.first().evaluate(row => getComputedStyle(row).display), 'table-row');
          const toggle = page.locator('[data-y3client-table-toggle]');
          assert.equal(await toggle.count(), 1);
          await toggle.click();
          assert.equal(await page.locator('#stock-data tr').first().evaluate(row => getComputedStyle(row).display), 'table-row', 'Table toggle should restore aligned rows');
          const tableBounds = await page.locator('#D_stock_B[data-y3client-table-scroll]').evaluate(element => ({ client: element.clientWidth, scroll: element.scrollWidth, right: element.getBoundingClientRect().right, overflow: getComputedStyle(element).overflowX }));
          assert(tableBounds.client <= width && tableBounds.right <= width + 1 && tableBounds.scroll > tableBounds.client && ['auto', 'scroll'].includes(tableBounds.overflow), 'Table mode should scroll inside a bounded container');
          assert(await page.evaluate(() => document.documentElement.scrollWidth) <= width + 1, 'Full table mode must keep the outer page bounded');
          await page.screenshot({ path: path.join(outputPath, `stock-table-${width}.png`), fullPage: true });
          await page.locator('#D_stock_B').evaluate(element => { element.scrollLeft = 120; });
          await page.waitForFunction(() => document.getElementById('D_stock_H').scrollLeft === document.getElementById('D_stock_B').scrollLeft && document.getElementById('D_stock_B').scrollLeft > 0);
          await toggle.click();
          assert.notEqual(await page.locator('#stock-data tr').first().evaluate(row => getComputedStyle(row).display), 'table-row');
          await page.locator('#page-select').selectOption('2');
          assert.equal(await page.evaluate(() => fixturePageChanges), 1, 'Pager handler and its control must survive');
          const pending = page.waitForRequest(request => request.url() === origin + '/fixture/detail');
          await page.locator('#product-detail').click();
          await pending;
          assert.equal(await page.evaluate(() => fixtureDetailClicks), 1, 'Result action must use the site-owned link');
        }
        if (kind === 'daily') {
          assert.equal(await page.locator('[data-y3client-result-card]').count(), 0, 'A complex grouped grid must not be flattened into misleading cards');
          const fallback = page.locator('[data-y3client-table-scroll]');
          assert.equal(await fallback.count(), 1);
          const bounds = await fallback.evaluate(element => ({ client: element.clientWidth, scroll: element.scrollWidth, right: element.getBoundingClientRect().right, overflow: getComputedStyle(element).overflowX }));
          assert(bounds.client <= width && bounds.right <= width + 1 && bounds.scroll > bounds.client && ['auto', 'scroll'].includes(bounds.overflow), 'Complex grid should use bounded horizontal scrolling');
          assert(await fallback.evaluate(element => { element.scrollLeft = 120; return element.scrollLeft; }) > 0, 'Grouped report columns must remain reachable by scrolling');
          assert.equal(await page.locator('#complex-grid th[colspan="2"]').count(), 4);
          assert.equal(await page.locator('#complex-grid th[rowspan="2"]').count(), 1);
          assert.equal(await page.locator('#complex-grid td[colspan="3"]').count(), 1, 'Complex grid spans and aggregate meaning must remain intact');
        }
      };
      for (const [kind, pathname] of Object.entries(pages)) {
        await page.goto(origin + pathname);
        await snapshotOriginals(page);
        // Before = the previous app's touch-size adapter, without the new layout renderer.
        if (width === 390) {
          for (const frame of page.frames()) await frame.evaluate(scripts.before);
          await page.screenshot({ path: path.join(outputPath, `${kind}-before.png`), fullPage: true });
        }
        await adapt();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await assertPreserved(page);
        await page.screenshot({ path: path.join(outputPath, `${kind}-after-${width}.png`), fullPage: true });
        const documentWidth = await page.evaluate(() => document.documentElement.scrollWidth);
        reports.push({ width, kind, documentWidth });
        assert(documentWidth <= width + 1, `${kind} outer document overflows ${width}px phone (${documentWidth}px); use bounded inner scrolling`);
        await interactionChecks(kind);
      }
      await page.goto(origin + '/fixture/framed');
      await adapt();
      assert.deepEqual(await page.evaluate(scripts.navigationState), { submissionRevision: 0, resultSubmissionRevision: 0 });
      const condition = page.frames().find(frame => frame.name() === 'prtz030_1_1');
      const result = page.frames().find(frame => frame.name() === 'prtz030_2');
      for (const revision of [1, 2]) {
        const pending = page.waitForRequest(request => request.url() === origin + framedResult && request.method() === 'POST');
        if (revision === 2) await page.waitForTimeout(220); // Two deliberate searches, outside the double-tap debounce window.
        if (revision === 1) await condition.locator('#framed-submit').click();
        else await condition.evaluate(() => document.forms.form1.submit());
        const request = await pending;
        assert.equal(new URLSearchParams(request.postData()).get('synthetic_session'), 'unchanged');
        await page.waitForFunction(expected => frames[1].document.documentElement?.getAttribute('data-fixture-post') === String(expected), revision);
        await result.evaluate(scripts.adapt);
        assert.deepEqual(await page.evaluate(scripts.navigationState), { submissionRevision: revision, resultSubmissionRevision: revision }, 'Normal submit and direct native form.submit must each track one ready result without exposing values');
      }
      reports.push({ width, kind: 'framed search', revisions: await page.evaluate(scripts.navigationState) });
      // Emulate WK's document-end injection before window.load, rather than adapting after goto.
      await context.addInitScript(({ before, adapt, pathname }) => {
        if (location.pathname !== pathname) return;
        document.addEventListener('DOMContentLoaded', () => {
          (0, eval)(before);
          (0, eval)(adapt);
          window.fixtureAtDocumentEnd = { gridAlreadyBuilt: !!window.fixtureGridBuilt, resultsAlreadyStyled: !!document.getElementById('y3client-results-style') };
        }, { once: true });
      }, { before: scripts.before, adapt: scripts.adapt, pathname: lateGrid });
      await page.goto(origin + lateGrid);
      await page.waitForFunction(() => document.querySelectorAll('#late-data [data-y3client-result-card]').length === 3);
      assert.deepEqual(await page.evaluate(() => fixtureAtDocumentEnd), { gridAlreadyBuilt: false, resultsAlreadyStyled: false }, 'Grid rendering should wait for the site-owned load constructor');
      assert.equal(await page.evaluate(() => fixtureGridBuilt && fixtureLateObjects.table === document.getElementById('late-data') && fixtureLateObjects.link === document.getElementById('late-product-detail') && fixtureLateObjects.link.onclick === fixtureLateObjects.handler && fixtureLateObjects.pager === document.getElementById('late-page-select')), true, 'Adapting a late grid must keep the site-created objects and their handlers');
      assert.equal(await page.locator('#late-data[data-y3client-result-list="cards"]').count(), 1);
      assert.deepEqual(await page.locator('#late-data tr').first().locator('td').evaluateAll(cells => cells.map(cell => cell.getAttribute('data-y3client-label'))), ['品番', '商品名', 'カラー', 'サイズ', '在庫数', '販売数']);
      const lateWidth = await page.evaluate(() => document.documentElement.scrollWidth);
      assert(lateWidth <= width + 1, `Late grid should fit ${width}px phone after its own constructor (${lateWidth}px)`);
      await page.screenshot({ path: path.join(outputPath, `stock-late-after-${width}.png`), fullPage: true });
      await page.locator('#late-product-detail').click();
      assert.equal(await page.evaluate(() => fixtureLateDetailClicks), 1);
      await page.locator('#late-page-select').selectOption('2');
      assert.equal(await page.evaluate(() => fixtureLatePageChanges), 1);
      assert.equal(await page.locator('#late-pager input[name="unchanged"]').inputValue(), 'late-synthetic');
      reports.push({ width, kind: 'late frozen grid', documentWidth: lateWidth });
      assert.deepEqual(unknown, [], 'No request may escape fixture routing');
      await context.close();
    }
    fs.writeFileSync(path.join(outputPath, 'verification.json'), JSON.stringify({ scope: 'Synthetic mobile Chromium only; no credentials, real records or iPhone device execution.', reports }, null, 2), { mode: 0o600 });
    console.log(JSON.stringify({ status: 'passed fixture interactions', output: outputPath, reports }, null, 2));
  } finally { await browser.close(); }
}

if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { origin, pages, fixtures, shell };
