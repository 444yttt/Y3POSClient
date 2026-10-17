// All examples are fictional. No requests leave the intercepted fixture origin.
// PLAYWRIGHT_MODULE=/workspace/scratch/xvfb/node_modules/playwright-core \
// CHROMIUM_EXECUTABLE=/usr/bin/chromium node Tests/inventory_features.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const origin = 'https://adidas-y3.poscmcloud.jp:15505';
const source = fs.readFileSync(path.join(__dirname, '../Y3Client/LegacySiteSupport.swift'), 'utf8');
const script = name => {
  const match = source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`));
  return match ? match[1] : null;
};
const output = process.env.INVENTORY_QA_OUTPUT || path.join(os.tmpdir(), 'y3-inventory-features-qa');
const standalone = process.env.INVENTORY_PRESENTATION_SCRIPT;
const presentation = standalone ? fs.readFileSync(standalone, 'utf8') : script('inventoryPresentation');
assert(presentation, 'Missing inventoryPresentation; set INVENTORY_PRESENTATION_SCRIPT only for a development preview');
const adapt = [script('viewportAndTouch'), script('mobileRedesign'), presentation].filter(Boolean).join('\n');
const autofill = script('staffCredentialAutofill');
assert(autofill, 'Missing staffCredentialAutofill');
const shell = body => `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空在庫データ</title><style>body{font:12px serif;margin:8px}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:4px;white-space:nowrap}input,select,button{font:12px serif}</style></head><body>${body}</body></html>`;
const product = 'MOCK-A001';
const updatedAt = '2026/10/17 17:34:46 現在';
const metadata = (code = product) => `<table id="inventory-summary" width="800"><tr><th>品番</th><th>作成日付</th></tr><tr><td>${code}</td><td>${updatedAt}</td></tr></table>
<form id="pager-form" name="form1" method="post" action="/fixture/page" target="inventory-metadata"><input type="hidden" name="unchanged" value="synthetic-pager-token"><input type="hidden" name="m01_hinban" value="${code}"><select name="PgSelect" id="page-select" onchange="window.fixturePageChanges=(window.fixturePageChanges||0)+1"><option value="1">1</option><option value="2">2</option></select><input type="submit" name="hyouzi" id="page-submit" value="表示"></form>`;
const metrics = [
  { key: 'available', label: '有効在庫', total: '003', values: ['0', '', '-1', '3', '1'] },
  { key: 'inTransit', label: '積送在庫', total: '0', values: ['0', '0', '0', '0', '0'] },
  { key: 'reserved', label: '取置在庫', total: '-', values: ['-', '0', '0', '0', '0'] },
  { key: 'sales', label: '販売実績', total: '20', values: ['1', '2', '3', '4', '5'] },
];
const emptyMetrics = metrics.map(metric => ({ ...metric, total: '0', values: ['0', '0', '0', '0', '0'] }));
const totalMetrics = metrics.map((metric, index) => ({ ...metric, total: ['900', '800', '700', '600'][index], values: ['11', '22', '33', '44', '55'] }));
const rows = (color, values) => values.map((metric, index) => `<tr>${index === 0 ? `<td rowspan="4">${color}</td>` : ''}<td>${metric.label}</td><td>${metric.total}</td>${metric.values.map(value => `<td>${value}</td>`).join('')}</tr>`).join('');
const matrix = ({ code = product, name = '架空のフーディ', codes = ['101', '102', '103', '104', '105'], category = 'ブルゾン・パーカー' } = {}) => `<table id="inventory-matrix" width="1040"><tbody>
<tr><th>品番</th><td>${code}</td><th>商品名</th><td colspan="5"><a id="product-link" href="javascript:void(0)" onclick="window.fixtureProductClicks=(window.fixtureProductClicks||0)+1;return false">${name}</a></td></tr>
<tr><th rowspan="2">カラー</th><th rowspan="2">区分</th><th rowspan="2">合計</th><th colspan="5">サイズ</th></tr>
<tr>${codes.map(value => `<th>${value}</th>`).join('')}</tr>
${rows('-5-', metrics)}${rows('-7-', emptyMetrics)}${rows('総計', totalMetrics)}</tbody></table>
<p id="fixture-category">${category}</p><input type="button" id="original-back" value="戻る" onclick="window.fixtureBackClicks=(window.fixtureBackClicks||0)+1">`;
// The legacy stock screen also transposes its axes: sizes are down rows and
// colors across columns. Empty header/data padding is emitted by the original grid.
const rowSizes = ['313', '314', '315', '316', '317', '318'];
const transposedRows = (size, index) => metrics.map((metric, metricIndex) => {
  const value = [String(index), '', '-', '-1'][metricIndex];
  return `<tr>${metricIndex === 0 ? `<td rowspan="4">${size}</td>` : ''}<td>${metric.label}</td><td>${index}${metricIndex}</td><td>${value}</td>${'<td></td>'.repeat(9)}</tr>`;
}).join('');
const transposed = ({ sizeCodes = rowSizes, productName = '架空のシューズ' } = {}) => `<div id="D_T01_H"><table id="T01_H" width="1200" style="width:625px;position:absolute;left:0;top:0"><tbody>
<tr><th>品番</th><td>MOCK-F001</td><th>商品名</th><td colspan="10"><a id="transposed-product-link" href="javascript:void(0)" onclick="window.fixtureTransposedClicks=(window.fixtureTransposedClicks||0)+1;return false">${productName}</a></td></tr>
<tr><th rowspan="2">サイズ</th><th rowspan="2"></th><th rowspan="2">合計</th><th colspan="10">カラー</th></tr>
<tr><th>-4-</th>${'<th></th>'.repeat(9)}</tr>
${sizeCodes.map(transposedRows).join('')}${transposedRows('総計', 9)}</tbody></table></div>
<div id="D_T01_B"><table id="T01_B" width="1200"><tbody>${sizeCodes.map(transposedRows).join('')}${transposedRows('総計', 9)}</tbody></table></div>`;
const fixturePaths = {
  full: '/scripts/verona/print/prtz011_4.asp',
  summary: '/scripts/verona/print/prtz011_3.asp',
  mismatch: '/fixture/mismatched',
  unsupported: '/scripts/verona/print/prtz011_90.asp',
  transposed: '/scripts/verona/print/prtz011_91.asp',
  combined: '/scripts/verona/print/prtz011_2.asp',
  matrixFrame: '/scripts/verona/print/prtz011_2_2.asp',
  summaryFrame: '/scripts/verona/print/prtz011_2_3.asp',
  outside: 'https://example.invalid/scripts/verona/print/prtz011_4.asp',
};
const fixtures = new Map([
  [origin + fixturePaths.full, shell(metadata() + matrix() + '<main id="combined-target"></main>')],
  [origin + fixturePaths.summary, shell(metadata())],
  [origin + fixturePaths.transposed, shell(transposed())],
  [origin + fixturePaths.combined, `<html><head><title>架空フレーム在庫照会</title></head><frameset rows="110,*"><frame name="inventory-metadata" src="${fixturePaths.summaryFrame}"><frame name="inventory-matrix" src="${fixturePaths.matrixFrame}"></frameset></html>`],
  [origin + fixturePaths.summaryFrame, shell(metadata('MOCK-F001'))],
  [origin + fixturePaths.matrixFrame, shell(transposed())],
  [origin + fixturePaths.mismatch, shell(metadata('MOCK-OLD001') + matrix() + '<main id="combined-target"></main>')],
  [origin + fixturePaths.unsupported, shell('<table id="unrelated"><tr><th>日付</th><th>売上</th></tr><tr><td>2026/10/17</td><td>317</td></tr></table>')],
  [fixturePaths.outside, shell(metadata() + matrix() + '<main id="combined-target"></main>')],
  [origin + '/fixture/page', shell('<p>架空ページ受信</p>')],
]);
// Other inventory entry points use the same shape with different ASP families,
// frame suffixes, frame ordering, and initialization timing.
const inventoryFamilies = [
  { key: 'print010', directory: 'print', family: '010', metadataSuffix: '3', matrixSuffix: '2', reverse: false },
  { key: 'print015', directory: 'print', family: '015', metadataSuffix: '3', matrixSuffix: '2', reverse: true },
  { key: 'display015', directory: 'display', family: '015', metadataSuffix: '3', matrixSuffix: '2', reverse: false, duplicateFullGrid: true },
  { key: 'display015-structural', directory: 'display', family: '015', metadataSuffix: '5', matrixSuffix: '7', reverse: true, navigation: true, lateGrid: true },
  { key: 'print010-mismatch', directory: 'print', family: '010', metadataSuffix: '3', matrixSuffix: '2', reverse: true, mismatched: true },
  { key: 'guide-women', directory: 'print', family: '015', metadataSuffix: '5', matrixSuffix: '7', reverse: true, categoryCode: '1APW', expectedCategory: 'apparelWomen', sizeCodes: ['100', '101', '102', '103', '104'], productName: '架空のウェア', expectedSizeTexts: ['2XS', 'XS', 'S', 'M', 'L'] },
  { key: 'guide-headwear', directory: 'display', family: '015', metadataSuffix: '5', matrixSuffix: '7', reverse: false, categoryCode: '3ACC', expectedCategory: 'headwear', sizeCodes: ['102', '103', '104'], productName: '架空のHAT', expectedSizeTexts: ['S', 'M', 'L'], expectedMeasures: ['56', '58', '60'] },
  { key: 'guide-socks', directory: 'print', family: '010', metadataSuffix: '5', matrixSuffix: '7', reverse: true, categoryCode: '3ACC', expectedCategory: 'socks', sizeCodes: ['605', '606', '607', '608'], productName: '架空のSOCKS', expectedSizeTexts: ['21-22cm', '22-24cm', '24-26cm', '26-28cm'] },
  { key: 'guide-one-size', directory: 'print', family: '015', metadataSuffix: '5', matrixSuffix: '7', reverse: false, categoryCode: '3ACC', expectedCategory: 'oneSize', sizeCodes: ['601', '608'], productName: '架空のONE SIZE BAG', expectedSizeTexts: ['NS', 'OSFA'] },
  { key: 'guide-unknown-608', directory: 'display', family: '015', metadataSuffix: '5', matrixSuffix: '7', reverse: true, categoryCode: '3ACC', expectedCategory: '', sizeCodes: ['608'], productName: '架空のバッグ', expectedSizeTexts: ['608'] },
];
for (const item of inventoryFamilies) {
  const base = `/scripts/verona/${item.directory}/prtz${item.family}`;
  const query = `?fixture=${item.key}`;
  item.root = base + '_2.asp' + query;
  item.metadata = base + `_2_${item.metadataSuffix}.asp` + query;
  item.matrix = base + `_2_${item.matrixSuffix}.asp` + query;
  item.navigationPath = base + '_2_1.asp' + query;
  const pair = [
    `<frame name="inventory-metadata" src="${item.metadata}">`,
    `<frame name="inventory-matrix" src="${item.matrix}">`,
  ];
  if (item.reverse) pair.reverse();
  if (item.navigation) pair.unshift(`<frame name="inventory-navigation" src="${item.navigationPath}">`);
  fixtures.set(origin + item.root, `<html><head><title>架空の在庫ファミリー確認</title></head><frameset rows="${item.navigation ? '60,110,*' : '110,*'}">${pair.join('')}</frameset></html>`);
  let summaryHTML = metadata('MOCK-F001');
  if (item.categoryCode) summaryHTML = summaryHTML.replace('<th>作成日付</th>', '<th>作成日付</th><th>カテゴリーNo</th>').replace(`<td>${updatedAt}</td>`, `<td>${updatedAt}</td><td>${item.categoryCode}</td>`);
  fixtures.set(origin + item.metadata, shell(summaryHTML));
  let grid = transposed({ sizeCodes: item.sizeCodes, productName: item.productName });
  if (item.duplicateFullGrid) {
    const fullHeader = grid.match(/<table id="T01_H"[\s\S]*?<\/table>/)[0];
    grid = grid.replace(/<table id="T01_B"[\s\S]*?<\/table>/, fullHeader.replace('id="T01_H"', 'id="T01_B"'));
  }
  if (item.mismatched) grid = grid.replaceAll('MOCK-F001', 'MOCK-OTHER001');
  if (item.lateGrid) {
    const payload = JSON.stringify(grid).replace(/</g, '\\u003c');
    fixtures.set(origin + item.matrix, shell(`<div id="late-grid"></div><script>window.addEventListener('load',()=>setTimeout(()=>{document.getElementById('late-grid').innerHTML=${payload};window.fixtureLateInventoryReady=true},180),{once:true})</script>`));
  } else fixtures.set(origin + item.matrix, shell(grid));
  if (item.navigation) fixtures.set(origin + item.navigationPath, shell(`<a id="original-search" href="${base}_1.asp" onclick="window.fixtureSearchClicks=(window.fixtureSearchClicks||0)+1;return false">検索条件</a>`));
}
const dailyPaths = {
  root: '/scripts/verona/print/prtz030_2.asp?fixture=noninventory',
  summary: '/scripts/verona/print/prtz030_2_3.asp?fixture=noninventory',
  matrix: '/scripts/verona/print/prtz030_2_2.asp?fixture=noninventory',
};
fixtures.set(origin + dailyPaths.root, `<html><head><title>架空の日別集計</title></head><frameset rows="110,*"><frame name="daily-summary" src="${dailyPaths.summary}"><frame name="daily-matrix" src="${dailyPaths.matrix}"></frameset></html>`);
fixtures.set(origin + dailyPaths.summary, shell('<table id="daily-summary"><tr><th>日付</th><th>店舗</th><th>数量</th></tr><tr><td>2026/10/17</td><td>架空店舗</td><td>3</td></tr></table>'));
fixtures.set(origin + dailyPaths.matrix, shell('<table id="daily-complex" width="1050"><tr><th rowspan="2">日付</th><th colspan="2">売上</th><th colspan="2">客数</th></tr><tr><th>数量</th><th>金額</th><th>組数</th><th>人数</th></tr><tr><td>2026/10/17</td><td>3</td><td>12,000</td><td>2</td><td>4</td></tr><tr><td>2026/10/18</td><td>5</td><td>20,000</td><td>3</td><td>6</td></tr></table>'));

const assertFits = async (page, width) => {
  const boxes = await page.locator('[data-y3client-inventory]').evaluateAll(nodes => nodes.map(node => {
    const box = node.getBoundingClientRect();
    return { left: box.left, right: box.right, scroll: node.scrollWidth, width: node.clientWidth };
  }));
  assert.equal(boxes.length, 1, 'One combined inventory result must be shown');
  assert(boxes.every(box => box.left >= -1 && box.right <= width + 1), 'Combined result must fit the phone viewport');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, 'The page itself must not scroll horizontally');
};
const snapshotOriginals = page => page.evaluate(() => {
  window.fixtureOriginals = {
    form: document.getElementById('pager-form'),
    pager: document.getElementById('page-select'),
    submit: document.getElementById('page-submit'),
    link: document.getElementById('product-link'),
    back: document.getElementById('original-back'),
    table: document.getElementById('inventory-matrix'),
  };
  window.fixtureOriginalState = {
    pagerOwner: fixtureOriginals.pager.form,
    pagerHandler: fixtureOriginals.pager.onchange,
    linkHandler: fixtureOriginals.link.onclick,
    backHandler: fixtureOriginals.back.onclick,
    tableText: fixtureOriginals.table.textContent,
    hidden: Array.from(fixtureOriginals.form.elements).filter(field => field.type === 'hidden').map(field => [field, field.name, field.value]),
    action: fixtureOriginals.form.action,
    target: fixtureOriginals.form.target,
    method: fixtureOriginals.form.method,
  };
});
const assertPreserved = async page => {
  assert.equal(await page.evaluate(() => Object.values(fixtureOriginals).every(node => node.isConnected)), true, 'Original result, pager, back and product nodes must stay connected');
  assert.equal(await page.evaluate(() => fixtureOriginals.pager.form === fixtureOriginalState.pagerOwner && fixtureOriginals.pager.onchange === fixtureOriginalState.pagerHandler && fixtureOriginals.link.onclick === fixtureOriginalState.linkHandler && fixtureOriginals.back.onclick === fixtureOriginalState.backHandler), true, 'Original control ownership and handlers must be preserved');
  assert.equal(await page.evaluate(() => fixtureOriginals.table.textContent === fixtureOriginalState.tableText && fixtureOriginalState.hidden.every(([field, name, value]) => field.name === name && field.value === value) && fixtureOriginals.form.action === fixtureOriginalState.action && fixtureOriginals.form.target === fixtureOriginalState.target && fixtureOriginals.form.method === fixtureOriginalState.method), true, 'Original table values and pager request semantics must be preserved');
};

async function checkCombinedInventory(context) {
  const page = await context.newPage();
  await page.goto(origin + fixturePaths.combined);
  await page.waitForLoadState('load');
  await page.evaluate(() => { window.__y3ClientNavigation = { submissionRevision: 3, resultSubmissionRevision: 2 }; });
  for (const frame of page.frames()) await frame.evaluate(adapt);
  assert.equal(await page.evaluate(() => typeof window.__y3ClientInventoryMerge?.reconcile), 'function', 'The integrated script must expose its trusted coordinator');
  await page.evaluate(() => window.__y3ClientInventoryMerge.reconcile());
  const metadataFrame = page.frames().find(frame => new URL(frame.url()).pathname === fixturePaths.summaryFrame);
  const matrixFrame = page.frames().find(frame => new URL(frame.url()).pathname === fixturePaths.matrixFrame);
  assert(metadataFrame && matrixFrame);
  await metadataFrame.waitForSelector('[data-y3client-inventory]');
  assert.equal(await page.evaluate(() => window.__y3ClientNavigation.resultSubmissionRevision), 3, 'A combined result becomes ready after its matching matrix is parsed');
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible').count(), 1, 'Result metadata and the matrix must combine in exactly one view');
  assert.equal(await metadataFrame.locator('html').getAttribute('data-y3client-inventory-primary') !== null, true);
  assert.equal(await matrixFrame.locator('html').getAttribute('data-y3client-inventory-secondary') !== null, true);
  assert.equal(await metadataFrame.locator('[data-y3client-inventory-color]').count(), 2, 'Full header clone and body clone must not double colors or totals');
  assert.equal(await metadataFrame.locator('[data-y3client-inventory-size-row]').count(), rowSizes.length * 2, 'Every actual size appears once per color/total group');
  assert.equal(await matrixFrame.locator('#T01_H').count(), 1);
  assert.equal(await matrixFrame.locator('#T01_B').count(), 1, 'Both original grid clones must remain connected for fallback');
  assert.equal(await metadataFrame.locator('#pager-form').count(), 1, 'The original pager must remain connected');
  const originalTableStyle = await matrixFrame.locator('#T01_H').getAttribute('style');
  await metadataFrame.locator('[data-y3client-inventory-table-button]').click();
  const raw = metadataFrame.locator('[data-y3client-inventory-raw]');
  assert.equal(await raw.isVisible(), true, 'The table fallback should appear in the same primary result frame');
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible,[data-y3client-inventory-raw]:visible').count(), 1);
  assert.equal(await raw.locator('table').count(), 1, 'Only one source table should be copied for fallback');
  assert.equal(await raw.locator('tr').count(), 3 + (rowSizes.length + 1) * 4, 'The full header clone and body clone must not double fallback rows');
  assert.equal(await raw.locator('table').evaluate(table => getComputedStyle(table).position), 'static', 'The legacy absolutely positioned grid must flow below the fallback controls');
  const tableBounds = await raw.locator('table').boundingBox();
  const backBounds = await raw.locator('[data-y3client-inventory-back]').boundingBox();
  assert(tableBounds && backBounds && tableBounds.y >= backBounds.y + backBounds.height, 'The raw table must not overlap or intercept its return button');
  assert.equal(await matrixFrame.locator('#T01_H').getAttribute('style'), originalTableStyle, 'Fallback layout changes must not alter the original Tscroller table style');
  await raw.locator('a').click();
  assert.equal(await matrixFrame.evaluate(() => window.fixtureTransposedClicks || 0), 1, 'Readonly fallback links should proxy the original handler exactly once');
  // Tscroller may replace its table without changing any SKU, text or quantity.
  // The raw view must rebuild its links against that new connected source node.
  await matrixFrame.evaluate(() => {
    const source = document.getElementById('T01_H');
    const replacement = source.cloneNode(true);
    window.fixtureOldSourceTable = source;
    source.replaceWith(replacement);
  });
  await page.evaluate(() => window.__y3ClientInventoryMerge.reconcile());
  assert.equal(await raw.isVisible(), true, 'An identical-data grid replacement should retain the selected table mode');
  await raw.locator('a').click();
  assert.equal(await matrixFrame.evaluate(() => window.fixtureTransposedClicks || 0), 2, 'An identical-data grid replacement must proxy the new connected link exactly once');
  assert.equal(await matrixFrame.evaluate(() => !window.fixtureOldSourceTable.isConnected && document.getElementById('T01_H').isConnected), true);
  assert.equal(await matrixFrame.locator('#T01_H').getAttribute('style'), originalTableStyle);
  await metadataFrame.locator('[data-y3client-inventory-raw] [data-y3client-inventory-back]').click({ timeout: 5000 });
  assert.equal(await raw.isVisible(), false);
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible').count(), 1, 'Returning from the table should restore exactly one card result');
  // A native discovery poll is repeatable and must not append another result.
  for (let index = 0; index < 3; index++) await page.evaluate(() => window.__y3ClientInventoryMerge.reconcile());
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible').count(), 1);
  // A newly selected product cannot be combined with the previous result frame.
  await page.evaluate(() => { window.__y3ClientNavigation.submissionRevision = 4; });
  await metadataFrame.evaluate(() => { document.querySelector('#inventory-summary tr:last-child td').textContent = 'MOCK-NEXT001'; });
  await page.evaluate(() => window.__y3ClientInventoryMerge.reconcile());
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible').count(), 0, 'Mismatched old matrix must not appear under a new product header');
  assert(await page.evaluate(() => window.__y3ClientNavigation.resultSubmissionRevision < window.__y3ClientNavigation.submissionRevision), 'An old matrix must not mark a new search as ready');
  // A complete late Tscroller replacement is picked up by a subsequent poll.
  await matrixFrame.evaluate(() => {
    const table = document.getElementById('T01_H');
    table.rows[0].cells[1].textContent = 'MOCK-NEXT001';
    const replacement = table.cloneNode(true);
    table.replaceWith(replacement);
  });
  await page.evaluate(() => window.__y3ClientInventoryMerge.reconcile());
  await metadataFrame.waitForSelector('[data-y3client-inventory]');
  assert((await metadataFrame.locator('[data-y3client-inventory-title]').innerText()).includes('MOCK-NEXT001'));
  assert.equal(await page.evaluate(() => window.__y3ClientNavigation.resultSubmissionRevision), 4, 'Late matching grid completion should mark only the current search ready');
  assert.equal(await metadataFrame.locator('[data-y3client-inventory]:visible').count(), 1);
  const focus = script('frameFocus');
  assert(focus, 'Missing frameFocus');
  assert.equal(await page.evaluate(`(${focus})([0])`), true, 'The merged result must work with native frame focusing');
  await metadataFrame.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: path.join(output, 'inventory-combined-frame.png'), fullPage: true });
  await metadataFrame.locator('[data-y3client-inventory-pages] select').selectOption('2');
  const pageRequest = page.waitForRequest(request => request.url() === origin + '/fixture/page');
  await metadataFrame.getByRole('button', { name: '在庫結果 表示', exact: true }).click();
  const request = await pageRequest;
  assert.equal(request.method(), 'POST', 'The generated pager must delegate to the original POST form');
  assert.equal(request.frame().name(), 'inventory-metadata', 'The original pager frame target must be preserved');
  const posted = new URLSearchParams(request.postData() || '');
  assert.equal(posted.get('PgSelect'), '2');
  assert.equal(posted.get('unchanged'), 'synthetic-pager-token');
  assert.equal(posted.get('m01_hinban'), 'MOCK-F001', 'The original hidden query fields must not be recreated or modified');
  await page.close();
}

function withDocumentEndScripts(html) {
  const injections = [script('viewportAndTouch'), script('mobileRedesign'), presentation];
  assert(injections.every(Boolean));
  assert(injections.every(content => !/<\/script/i.test(content)), 'Fixture script must not terminate its HTML script element');
  const bodyDocument = /<\/body>/i.test(html);
  const scripts = injections.map((content, index) => {
    const run = `window.__fixtureInjections ||= []; window.__fixtureInjections.push(${index}); ${content}`;
    // Chromium does not apply Playwright init scripts to legacy FRAME documents.
    // Inline leaf scripts run at the end of the parsed DOM, before load. Frameset
    // scripts wait for parsing so their FRAME nodes exist, like WK document-end.
    return `<script>${bodyDocument ? run : `document.addEventListener('DOMContentLoaded',()=>{${run}},{once:true});`}</script>`;
  }).join('\n');
  return bodyDocument ? html.replace(/<\/body>/i, () => scripts + '</body>') : html.replace(/<\/head>/i, () => scripts + '</head>');
}

async function checkInventoryFamilies(browser) {
  const reports = [];
  for (const item of inventoryFamilies) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const unknown = [];
    await context.route('**/*', async route => {
      const body = fixtures.get(route.request().url());
      if (body === undefined) { unknown.push(route.request().url()); await route.abort(); return; }
      await route.fulfill({ contentType: 'text/html; charset=utf-8', body: withDocumentEndScripts(body) });
    });
    // No adaptation is run manually after load; fixtures inject at document end.
    const page = await context.newPage();
    await page.goto(origin + item.root);
    const metadataFrame = page.frames().find(frame => frame.url() === origin + item.metadata);
    const matrixFrame = page.frames().find(frame => frame.url() === origin + item.matrix);
    assert(metadataFrame && matrixFrame, `${item.key}: both report documents must load`);
    if (item.lateGrid) {
      // A native discovery retry occurs after a late grid is generated.
      await matrixFrame.waitForFunction(() => window.fixtureLateInventoryReady === true);
    }
    const discovery = script('discoverFrames');
    assert(discovery);
    let panes = await page.evaluate(discovery);
    if (!item.mismatched) {
      await metadataFrame.waitForSelector('[data-y3client-inventory]:visible', { timeout: 5000 }).catch(async error => {
        const status = await page.evaluate(() => ({
          coordinator: typeof window.__y3ClientInventoryMerge?.reconcile,
          frames: Array.from(window.frames).map(frame => ({
            path: frame.location.pathname,
            ready: frame.document.readyState,
            api: typeof frame.__y3InventoryPresentation,
            injections: frame.__fixtureInjections,
            metadata: frame.__y3InventoryPresentation?.parseInventorySummary(frame.document),
            matrices: Array.from(frame.document.querySelectorAll('table')).map(table => !!frame.__y3InventoryPresentation?.parseInventoryTable(table)),
          })),
        }));
        throw new Error(`${item.key}: ${error.message}; fixture status ${JSON.stringify(status)}`, { cause: error });
      });
      panes = await page.evaluate(discovery);
      assert.equal(panes.filter(pane => pane.kind === 'result').length, 1, `${item.key}: one inventory result must replace generic result 1/2 panes`);
      const expectedIndex = (item.navigation ? 1 : 0) + (item.reverse ? 1 : 0);
      assert.deepEqual(panes.find(pane => pane.kind === 'result').path, [expectedIndex], `${item.key}: frame order must not determine which result is metadata`);
      assert.equal(await metadataFrame.locator('[data-y3client-inventory-primary]').count(), 1);
      assert.equal(await matrixFrame.locator('[data-y3client-inventory-secondary]').count(), 1);
      assert.equal(await metadataFrame.locator('[data-y3client-result-card]').count(), 0, `${item.key}: metadata must not become a false product/timestamp card`);
      assert.equal(await metadataFrame.locator('[data-y3client-inventory-size-row]').count(), (item.sizeCodes || rowSizes).length * 2);
      assert.equal(await metadataFrame.locator('#inventory-summary').count(), 1);
      assert.equal(await matrixFrame.locator('#T01_H,#T01_B').count(), 2);
      if (item.categoryCode) {
        const resolved = await metadataFrame.evaluate(() => {
          const api = window.__y3InventoryPresentation;
          const summary = api.parseInventorySummary(document.getElementById('inventory-summary'));
          const source = Array.from(top.frames).find(frame => frame.document.getElementById('T01_H'));
          return api.resolveCategory(summary, api.parseInventoryTable(source.document.getElementById('T01_H')));
        });
        assert.equal(resolved, item.expectedCategory, `${item.key}: metadata-only category must reach the inventory resolver`);
        const cells = await metadataFrame.locator('[data-y3client-color-code="-4-"] [data-y3client-inventory-size-row] td:first-child').allTextContents();
        const normalized = cells.map(value => value.replace(/[–—−]/g, '-').replace(/\s+/g, ''));
        item.expectedSizeTexts.forEach((expected, index) => assert(normalized[index].includes(expected), `${item.key}: category-specific size label must appear`));
        if (item.expectedMeasures) item.expectedMeasures.forEach((expected, index) => assert(normalized[index].includes(expected), 'Confirmed hat circumference must appear beside its label'));
        if (item.expectedCategory === '') assert(!cells.join(' ').includes('OSFA') && !cells.join(' ').includes('26–28'), 'Unknown code608 must not borrow one-size or sock labels');
      }
      if (item.navigation) {
        await metadataFrame.getByRole('button', { name: '検索条件を変更', exact: true }).click();
        const navigation = page.frames().find(frame => frame.url() === origin + item.navigationPath);
        assert(navigation);
        assert.equal(await navigation.evaluate(() => window.fixtureSearchClicks || 0), 1, 'Alternate ASP families must retain their original search action');
      }
    } else {
      assert.equal(await metadataFrame.locator('[data-y3client-inventory]').count(), 0, 'A different product must keep the original fallback view');
      assert.equal(await metadataFrame.locator('[data-y3client-result-card]').count(), 0, 'Unmerged metadata must not be flattened into a false result card');
      assert.equal(await metadataFrame.locator('#inventory-summary').isVisible(), true);
      const expectedMetadata = panes.find(pane => pane.path[0] === (item.reverse ? 1 : 0));
      assert(expectedMetadata && expectedMetadata.kind !== 'result', 'Fallback metadata is a control/summary document, not a second inventory result');
    }
    assert.equal(unknown.length, 0, 'Family fixtures must never send live requests');
    reports.push({ family: item.key, merged: !item.mismatched, parsedDocumentInjection: true });
    await context.close();
  }
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.route('**/*', async route => {
    const body = fixtures.get(route.request().url());
    if (body === undefined) { await route.abort(); throw new Error('Unexpected daily fixture request'); }
    await route.fulfill({ contentType: 'text/html; charset=utf-8', body: withDocumentEndScripts(body) });
  });
  const page = await context.newPage();
  await page.goto(origin + dailyPaths.root);
  const panes = await page.evaluate(script('discoverFrames'));
  assert.equal(panes.filter(pane => pane.kind === 'result').length, 2, 'Non-inventory daily reports must retain their distinct result panes');
  for (const frame of page.frames()) assert.equal(await frame.locator('[data-y3client-inventory-primary],[data-y3client-inventory-secondary],[data-y3client-inventory]').count(), 0, 'A complex daily report must not be classified as an inventory matrix');
  const dailyFrame = page.frames().find(frame => frame.url() === origin + dailyPaths.matrix);
  assert(dailyFrame);
  assert.equal(await dailyFrame.locator('#daily-complex').count(), 1);
  assert((await dailyFrame.locator('#daily-complex').textContent()).includes('12,000'));
  assert.equal(await dailyFrame.locator('#daily-complex').isVisible(), true, 'Original daily complex table must remain available');
  await context.close();
  return reports;
}

async function checkSizeGuide(browser) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const unknown = [];
  await context.route('**/*', async route => {
    const body = fixtures.get(route.request().url());
    if (body === undefined) { unknown.push(route.request().url()); await route.abort(); return; }
    await route.fulfill({ contentType: 'text/html; charset=utf-8', body });
  });
  const page = await context.newPage();
  await page.goto(origin + fixturePaths.full);
  await snapshotOriginals(page);
  await page.evaluate(adapt);
  const codes = Array.from({ length: 19 }, (_, index) => String(306 + index));
  const expected = {
    JP: Array.from({ length: 19 }, (_, index) => 22 + index * 0.5),
    UK: Array.from({ length: 19 }, (_, index) => 3.5 + index * 0.5),
    US: Array.from({ length: 19 }, (_, index) => 4 + index * 0.5),
    USW: Array.from({ length: 17 }, (_, index) => 5 + index * 0.5),
    EU: ['36', '36 2/3', '37 1/3', '38', '38 2/3', '39 1/3', '40', '40 2/3', '41 1/3', '42', '42 2/3', '43 1/3', '44', '44 2/3', '45 1/3', '46', '46 2/3', '47 1/3', '48'],
  };
  const mapped = await page.evaluate(codes => {
    const api = window.__y3InventoryPresentation;
    return Object.fromEntries(['JP', 'UK', 'US', 'USW', 'EU', 'CH'].map(unit => [unit, codes.map(code => api.formatSize(code, 'footwear', unit))]));
  }, codes);
  for (const unit of ['JP', 'UK', 'US', 'USW']) {
    for (let index = 0; index < expected[unit].length; index++) {
      assert.equal(mapped[unit][index].confirmed, true, `Guide code ${codes[index]} must have a confirmed ${unit} size`);
      assert.equal(Number(mapped[unit][index].text), expected[unit][index]);
    }
  }
  assert.deepEqual(mapped.EU.map(value => value.text), expected.EU, 'Fractional EU sizes must follow every guide row');
  for (const index of [17, 18]) {
    assert.equal(mapped.USW[index].confirmed, false, 'Blank women sizes in the guide must remain unconfirmed');
    assert.equal(mapped.USW[index].code, codes[index]);
  }
  assert.equal(mapped.CH[0].confirmed, false, 'Missing CH must not be inferred from the new JP rows');
  assert.equal(mapped.CH[11].text, '265', 'The existing referenced CH size for code317 must remain unchanged');
  const domain = await page.evaluate(() => {
    const api = window.__y3InventoryPresentation;
    const format = (code, category) => api.formatSize(code, category, 'JP');
    const categoryCodes = ['100', '101', '102', '103', '104', '105', '106'];
    return {
      generic: categoryCodes.map(code => format(code, 'apparel')),
      women: categoryCodes.map(code => format(code, 'apparelWomen')),
      men: categoryCodes.map(code => format(code, 'apparelMen')),
      unisex: categoryCodes.map(code => format(code, 'apparelUnisex')),
      hats: ['100', '101', '102', '103', '104', '105'].map(code => format(code, 'headwear')),
      socks: ['605', '606', '607', '608'].map(code => format(code, 'socks')),
      oneSize: ['601', '608'].map(code => format(code, 'oneSize')),
      unknown: format('608', 'unmapped-category'),
    };
  });
  const clothing = ['2XS', 'XS', 'S', 'M', 'L', 'XL', '2XL'];
  assert.deepEqual(domain.generic.map(size => size.text), clothing);
  assert.deepEqual(domain.unisex.map(size => size.text), clothing);
  assert.deepEqual(domain.women.slice(0, 5).map(size => size.text), clothing.slice(0, 5));
  assert.equal(domain.women[5].confirmed, false);
  assert.deepEqual(domain.men.slice(1).map(size => size.text), clothing.slice(1));
  assert.equal(domain.men[0].confirmed, false);
  assert.deepEqual(domain.hats.map(size => size.text), clothing.slice(0, 6), 'Previous confirmed hat labels must be preserved');
  assert.deepEqual(domain.hats.slice(2, 5).map(size => size.measurement), ['頭囲 56cm', '頭囲 58cm', '頭囲 60cm']);
  assert(domain.hats.slice(0, 2).concat(domain.hats[5]).every(size => !size.measurement), 'Unspecified hat circumferences must not be invented');
  assert.deepEqual(domain.socks.map(size => size.text), ['21–22cm', '22–24cm', '24–26cm', '26–28cm']);
  assert.deepEqual(domain.socks.map(size => size.measurement), ['EU 34–36', 'EU 37–39', 'EU 40–42', 'EU 43–45']);
  assert.deepEqual(domain.oneSize.map(size => size.text), ['NS', 'OSFA']);
  assert.equal(domain.unknown.confirmed, false);
  assert.equal(domain.unknown.text, '608', 'Code608 requires category context');
  const resolved = await page.evaluate(() => {
    const api = window.__y3InventoryPresentation;
    const model = (productName = '架空の商品', sizeCodes = ['101'], categoryCode = '') => ({ product: { productName, categoryCode }, sizeCodes });
    return {
      women: api.resolveCategory({ categoryCode: '1APW' }, model()),
      men: api.resolveCategory({ categoryCode: '2APM' }, model()),
      footwear: api.resolveCategory({ categoryCode: '4FTW' }, model('架空の商品', ['317'])),
      unisex: api.resolveCategory({ categoryCode: '5APU' }, model()),
      socks: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のSOCKS', ['605', '608'])),
      headwear: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のHAT', ['102', '104'])),
      oneSize: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のONE SIZE BAG', ['601', '608'])),
      unknown608: api.resolveCategory({}, model('架空の商品', ['608'])),
      genericACC: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のバッグ', ['608'])),
      conflict: api.resolveCategory({ categoryCode: '1APW' }, model('架空の商品', ['101'], '2APM')),
      explicitOverName: api.resolveCategory({ categoryCode: '1APW' }, model('架空のMEN SHIRT', ['101'])),
      capOneSize: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のCAP ONE SIZE', ['608'])),
      socksOneSize: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のSOCKS ONE SIZE', ['608'])),
      accessoryNS: api.resolveCategory({ categoryCode: '3ACC' }, model('架空のバッグ', ['601'])),
      labeledSocks: api.resolveCategory({ categoryLabel: 'ACC ソックス' }, model('架空の商品', ['608'])),
      labeledHeadwear: api.resolveCategory({ categoryLabel: 'ACC キャップ' }, model('架空の商品', ['102'])),
      labeledCapOneSize: api.resolveCategory({ categoryLabel: 'ACC CAP ONE SIZE' }, model('架空の商品', ['608'])),
      labeledSocksOneSize: api.resolveCategory({ categoryLabel: 'ACC SOCKS ONE SIZE' }, model('架空の商品', ['608'])),
    };
  });
  assert.deepEqual(resolved, { women: 'apparelWomen', men: 'apparelMen', footwear: 'footwear', unisex: 'apparelUnisex', socks: 'socks', headwear: 'headwear', oneSize: 'oneSize', unknown608: '', genericACC: '', conflict: '', explicitOverName: 'apparelWomen', capOneSize: 'oneSize', socksOneSize: 'socks', accessoryNS: 'oneSize', labeledSocks: 'socks', labeledHeadwear: 'headwear', labeledCapOneSize: 'oneSize', labeledSocksOneSize: 'socks' });
  const aliases = ['カテゴリNo', 'カテゴリーNo', 'カテゴリ番号', 'カテゴリー番号', 'カテゴリーＮＯ'];
  const summaries = await page.evaluate(aliases => {
    const api = window.__y3InventoryPresentation;
    return aliases.map(alias => {
      const table = document.createElement('table');
      table.innerHTML = `<tr><th>品番</th><th>作成日付</th><th>${alias}</th></tr><tr><td>MOCK-GUIDE</td><td>2026/10/17 17:34:46 現在</td><td>1APW</td></tr>`;
      return api.parseInventorySummary(table);
    });
  }, aliases);
  summaries.forEach(summary => assert.equal(summary.categoryCode, '1APW', 'Category-number aliases must survive metadata parsing'));
  await page.evaluate(codes => {
    const api = window.__y3InventoryPresentation;
    const matrix = api.parseInventoryTable(document.getElementById('inventory-matrix'));
    matrix.sizeCodes = codes;
    matrix.colors = matrix.colors.slice(0, 1);
    const raw = ['0', '', '-', '-1', '003'];
    for (const metric of Object.values(matrix.colors[0].metrics)) metric.values = codes.map((_, index) => raw[index % raw.length]);
    const summary = api.parseInventorySummary(document.getElementById('inventory-summary'));
    summary.categoryKey = 'footwear';
    api.renderInventory(summary, matrix, document.getElementById('combined-target'));
  }, codes);
  assert.deepEqual((await page.locator('[data-y3client-size-unit]').evaluateAll(buttons => buttons.map(button => button.getAttribute('data-y3client-size-unit')))).sort(), ['CH', 'EU', 'JP', 'UK', 'US', 'USW']);
  const totalsBefore = await page.locator('[data-y3client-inventory-totals]').allTextContents();
  for (const unit of ['JP', 'UK', 'US', 'USW', 'EU', 'CH']) {
    await page.locator(`[data-y3client-size-unit="${unit}"]`).click();
    const rows = await page.locator('[data-y3client-inventory-size-row]').evaluateAll(rows => rows.map(row => Array.from(row.cells).map(cell => cell.textContent)));
    assert.equal(rows.length, 19);
    rows.forEach((cells, index) => assert.deepEqual(cells.slice(1), [['0', '', '-', '-1', '003'][index % 5] || '\u00a0', ['0', '', '-', '-1', '003'][index % 5] || '\u00a0'], 'Every new unit must preserve raw stock and sales cells'));
    assert.deepEqual(await page.locator('[data-y3client-inventory-totals]').allTextContents(), totalsBefore, 'Unit changes must not alter supplied totals');
    await assertFits(page, 390);
  }
  await assertPreserved(page);
  assert.equal(unknown.length, 0);
  await context.close();
  return { footwearGuideRows: 19, footwearUnits: 6, categoryScopedCodes: true, metadataAliases: aliases.length, stockValuesPreserved: true };
}

async function checkStaffAutofill(browser) {
  const loginURL = origin + '/verona/data/cmtz030.asp?fixture=synthetic';
  const loginHTML = shell(`<form id="staff-login" method="post" action="/fixture/login-post" onsubmit="window.fixtureLoginPosts=(window.fixtureLoginPosts||0)+1;return false"><label>スタッフID<input name="tanto_id" type="text"></label><label>パスワード<input name="tanto_pw" type="password"></label><input id="login-button" type="submit" value="ログイン"></form>`);
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  let unknownRequests = 0;
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    let body;
    if (url.pathname === '/verona/data/cmtz030.asp') body = loginHTML;
    else if (url.pathname === '/fixture/framed-login') body = shell(`<iframe id="untrusted-login-frame" src="${loginURL}"></iframe>`);
    else if (url.pathname === '/fixture/wrong-login-path') body = loginHTML;
    else { unknownRequests++; await route.abort(); return; }
    await route.fulfill({ contentType: 'text/html; charset=utf-8', body });
  });
  const page = await context.newPage();
  const fixtureID = 'mock-staff';
  const fixturePassword = 'fictional-password-for-test';
  const fill = (frame = page, documentURL = loginURL) => frame.evaluate(({ source, staffID, password, documentURL }) => {
    return new Function('staffID', 'password', 'documentURL', source)(staffID, password, documentURL);
  }, { source: autofill, staffID: fixtureID, password: fixturePassword, documentURL });
  await page.goto(loginURL);
  assert.equal(await fill(), true, 'Saved defaults must prefill the main-frame staff login');
  assert.equal(await page.locator('input[name="tanto_id"]').inputValue(), fixtureID);
  assert.equal(await page.locator('input[name="tanto_pw"]').inputValue(), fixturePassword);
  assert.equal(await page.evaluate(() => window.fixtureLoginPosts || 0), 0, 'Autofill must never submit the login form');
  assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0, 'The injected script must not persist credentials in web storage');
  assert.equal(await page.evaluate(() => typeof window.staffID === 'undefined' && typeof window.password === 'undefined'), true, 'Credential arguments must not become page globals');
  await page.locator('#login-button').click();
  assert.equal(await page.evaluate(() => fixtureLoginPosts), 1, 'One manual login-button press must submit once');
  await page.locator('input[name="tanto_id"]').fill('manually-edited-id');
  await page.locator('input[name="tanto_pw"]').fill('manually-edited-password');
  assert.equal(await fill(), false, 'An autofill refresh must not overwrite manual edits');
  assert.equal(await page.locator('input[name="tanto_id"]').inputValue(), 'manually-edited-id');
  assert.equal(await page.locator('input[name="tanto_pw"]').inputValue(), 'manually-edited-password');
  for (const scenario of ['wrongSavedURL', 'foreignAction', 'foreignBase', 'actionUserinfo', 'getForm', 'duplicateID', 'hiddenPassword', 'readonlyID']) {
    await page.goto(loginURL);
    if (scenario === 'foreignAction') await page.locator('#staff-login').evaluate(form => { form.action = 'https://example.invalid/credential-collector'; });
    if (scenario === 'foreignBase') await page.locator('#staff-login').evaluate(form => { const base = document.createElement('base'); base.href = 'https://example.invalid/'; document.head.prepend(base); form.setAttribute('action', 'login.asp'); });
    if (scenario === 'actionUserinfo') await page.locator('#staff-login').evaluate(form => { form.action = 'https://mock:fictional@adidas-y3.poscmcloud.jp:15505/login.asp'; });
    if (scenario === 'getForm') await page.locator('#staff-login').evaluate(form => { form.method = 'get'; });
    if (scenario === 'duplicateID') await page.locator('#staff-login').evaluate(form => { const input = document.createElement('input'); input.name = 'tanto_id'; form.appendChild(input); });
    if (scenario === 'hiddenPassword') await page.locator('input[name="tanto_pw"]').evaluate(input => { input.style.display = 'none'; });
    if (scenario === 'readonlyID') await page.locator('input[name="tanto_id"]').evaluate(input => { input.readOnly = true; });
    assert.equal(await fill(page, scenario === 'wrongSavedURL' ? loginURL + '&other=1' : loginURL), false, `Unsafe login case ${scenario} must not receive defaults`);
    assert.equal(await page.locator('input[name="tanto_pw"]').inputValue(), '');
    assert.equal(await page.evaluate(() => window.fixtureLoginPosts || 0), 0);
  }
  for (const wrongURL of ['https://example.invalid/verona/data/cmtz030.asp', origin + '/fixture/wrong-login-path', 'https://adidas-y3.poscmcloud.jp:7705/verona/data/cmtz030.asp']) {
    await page.goto(wrongURL);
    assert.equal(await fill(page, wrongURL), false, 'Another origin, port or path must never receive the saved login');
    assert.equal(await page.locator('input[name="tanto_pw"]').inputValue(), '');
  }
  await page.goto(origin + '/fixture/framed-login');
  const frame = page.frames().find(frame => frame.url() === loginURL);
  assert(frame);
  assert.equal(await fill(frame), false, 'Even a matching login document must not autofill a subframe');
  assert.equal(await frame.locator('input[name="tanto_pw"]').inputValue(), '');
  assert.equal(unknownRequests, 0, 'Login fixtures must not send network requests');
  await context.close();
  return { defaultsPrefilled: true, manualSubmitOnly: true, manualEditsPreserved: true, unsafeDocumentsUntouched: true };
}

async function main() {
  fs.mkdirSync(output, { recursive: true, mode: 0o700 });
  fs.chmodSync(output, 0o700);
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || '/usr/bin/chromium', args: ['--no-sandbox'] });
  const reports = [];
  try {
    if (process.env.INVENTORY_GUIDE_ONLY === '1') {
      console.log(JSON.stringify({ guide: await checkSizeGuide(browser) }, null, 2));
      return;
    }
    if (process.env.INVENTORY_FAMILY_ONLY === '1') {
      console.log(JSON.stringify({ families: await checkInventoryFamilies(browser) }, null, 2));
      return;
    }
    for (const width of [390, 350, 320]) {
      const context = await browser.newContext({ viewport: { width, height: 844 }, isMobile: true, hasTouch: true });
      const unknown = [];
      await context.route('**/*', async route => {
        const body = fixtures.get(route.request().url());
        if (body === undefined) { unknown.push(route.request().url()); await route.abort(); return; }
        await route.fulfill({ contentType: 'text/html; charset=utf-8', body });
      });
      const page = await context.newPage();
      await page.goto(origin + fixturePaths.full);
      await snapshotOriginals(page);
      await page.evaluate(adapt);
      const parsed = await page.evaluate(() => window.__y3InventoryPresentation.parseInventoryTable(document.getElementById('inventory-matrix')));
      assert(parsed, 'The observed color / four-metric matrix must parse');
      assert.equal(parsed.schemaVersion, 1);
      assert.equal(parsed.product.productCode, product);
      assert.equal(parsed.product.productName, '架空のフーディ');
      assert.deepEqual(parsed.sizeCodes, ['101', '102', '103', '104', '105']);
      assert.equal(parsed.colors.length, 3);
      const black = parsed.colors.find(color => color.color === '-5-');
      const total = parsed.colors.find(color => color.isTotal);
      assert(black && total, 'Separate colors and the supplied total section must remain distinguishable');
      for (const metric of metrics) {
        assert.equal(black.metrics[metric.key].label, metric.label);
        assert.equal(black.metrics[metric.key].total, metric.total, 'Metric totals must be the server values');
        assert.deepEqual(black.metrics[metric.key].values, metric.values, 'Empty, zero, dash and negative cells must retain their exact text');
      }
      for (const metric of totalMetrics) {
        assert.equal(total.metrics[metric.key].total, metric.total, 'Supplied total rows must not be recomputed or added to color rows');
        assert.deepEqual(total.metrics[metric.key].values, metric.values);
      }
      const summary = await page.evaluate(() => window.__y3InventoryPresentation.parseInventorySummary(document.getElementById('inventory-summary')));
      assert.equal(summary.productCode, product);
      assert.equal(summary.updatedAt, updatedAt);
      await page.evaluate(() => {
        const api = window.__y3InventoryPresentation;
        const summary = api.parseInventorySummary(document.getElementById('inventory-summary'));
        summary.categoryKey = 'apparel';
        api.renderInventory(summary, api.parseInventoryTable(document.getElementById('inventory-matrix')), document.getElementById('combined-target'));
      });
      assert.equal(await page.locator('[data-y3client-inventory]').count(), 1);
      const resultText = await page.locator('[data-y3client-inventory]').innerText();
      assert(resultText.includes(product) && resultText.includes('架空のフーディ') && resultText.includes(updatedAt), 'Product, name and update time belong in the combined result header');
      assert(resultText.includes('XS'), 'Explicit apparel code 101 mapping must be visible');
      assert(resultText.includes('有効在庫') && resultText.includes('積送在庫') && resultText.includes('取置在庫') && resultText.includes('販売実績'), 'Every size must expose all four distinct metrics');
      await assertFits(page, width);
      await assertPreserved(page);
      await page.screenshot({ path: path.join(output, `inventory-apparel-${width}.png`), fullPage: true });
      await page.locator('#page-select').selectOption('2');
      assert.equal(await page.evaluate(() => fixturePageChanges), 1, 'Original pagination event must run exactly once');
      assert.equal(await page.locator('#page-select').inputValue(), '2');
      // The original link/back handlers can still be invoked after presentation.
      assert.equal(await page.evaluate(() => { fixtureOriginals.link.click(); fixtureOriginals.back.click(); return fixtureProductClicks === 1 && fixtureBackClicks === 1; }), true);
      // No global sequential mapping: identical codes in another category retain codes.
      const sizes = await page.evaluate(() => {
        const api = window.__y3InventoryPresentation;
        return {
          apparel: api.formatSize('101', 'apparel', 'JP'),
          unknownCategory: api.formatSize('101', 'unmapped-category', 'JP'),
          unknownHat: api.formatSize('205', 'headwear', 'JP'),
          footKnown: api.formatSize('317', 'footwear', 'JP'),
          footUnknown: api.formatSize('399', 'footwear', 'JP'),
        };
      });
      assert(JSON.stringify(sizes.apparel).includes('XS'));
      assert(!JSON.stringify(sizes.unknownCategory).includes('XS'), 'Known size codes must not relabel an unconfirmed category');
      assert(JSON.stringify(sizes.unknownHat).includes('205'), 'Unknown category sizes must keep their original code');
      assert(JSON.stringify(sizes.footKnown).includes('27.5'));
      assert.equal(sizes.footUnknown.confirmed, false, 'Unverified footwear codes must not be inferred');
      assert(sizes.footUnknown.code === '399' && JSON.stringify(sizes.footUnknown).includes('399'));
      if (!standalone) {
        const confirmed = await page.evaluate(() => {
          const api = window.__y3InventoryPresentation;
          return { apparel: ['100', '101', '102', '103', '104', '105'].map(code => api.formatSize(code, 'apparel', 'JP').text), shoes: ['313', '314', '315', '316', '317', '318'].map(code => api.formatSize(code, 'footwear', 'JP').text), headwear: ['100', '101', '102', '103', '104', '105'].map(code => api.formatSize(code, 'headwear', 'JP').text) };
        });
        assert.deepEqual(confirmed.apparel, ['2XS', 'XS', 'S', 'M', 'L', 'XL']);
        assert.deepEqual(confirmed.shoes.map(Number), [25.5, 26, 26.5, 27, 27.5, 28]);
        assert.deepEqual(confirmed.headwear, ['2XS', 'XS', 'S', 'M', 'L', 'XL']);
      }
      // A confirmed per-category catalog drives each footwear unit, without changing quantities.
      await page.evaluate(() => {
        const api = window.__y3InventoryPresentation;
        api.configureSizeMappings({ verifiedFootwear: { kind: 'footwear', title: '架空の確認済み靴カテゴリ', codes: { '317': { JP: '27.5', US: '9.5', EU: '43 1/3', CH: '265' } } } });
        const model = api.parseInventoryTable(document.getElementById('inventory-matrix'));
        model.sizeCodes[0] = '317';
        const summary = api.parseInventorySummary(document.getElementById('inventory-summary'));
        summary.categoryKey = 'verifiedFootwear';
        api.renderInventory(summary, model, document.getElementById('combined-target'));
      });
      assert.equal(await page.locator('[data-y3client-size-unit]').count(), 4, 'Footwear must offer JP, US, EU and CH');
      for (const [unit, label] of [['US', '9.5'], ['EU', '43 1/3'], ['CH', '265'], ['JP', '27.5']]) {
        await page.locator(`[data-y3client-size-unit="${unit}"]`).click();
        assert.equal(await page.locator(`[data-y3client-size-unit="${unit}"]`).getAttribute('aria-pressed'), 'true');
        const sizeRow = page.locator('[data-y3client-color-code="-5-"] [data-y3client-inventory-size-row][data-y3client-size-code="317"]');
        const cells = await sizeRow.locator('td').allTextContents();
        assert(cells[0].includes(label) && cells[0].includes('317'), 'Converted size must retain its original code');
        assert.deepEqual(cells.slice(1), ['0', '1'], 'Unit switching must preserve available stock and sales values');
      }
      const details = page.locator('[data-y3client-color-code="-5-"] [data-y3client-inventory-details]');
      await details.locator('summary').click();
      assert.equal(await details.getAttribute('open'), '');
      const detailCells = await details.locator('[data-y3client-inventory-detail-row][data-y3client-size-code="317"] td').allTextContents();
      assert.equal(detailCells[1].trim(), '0');
      assert.equal(detailCells[2].trim(), '-');
      const filter = page.locator('[data-y3client-inventory-stock-filter]');
      assert.equal(await filter.count(), 1, 'A stock filter should help users inspect stocked sizes');
      assert.equal(await filter.isChecked(), false, 'The default view must preserve every supplied size');
      const totalsBefore = await page.locator('[data-y3client-inventory-totals]').allTextContents();
      await filter.check();
      assert.equal(await details.getAttribute('open'), '', 'Stock filtering should retain an already-open metric detail section');
      const blackCard = page.locator('[data-y3client-color-code="-5-"]');
      const activeCodes = await blackCard.locator('[data-y3client-inventory-size-row]').evaluateAll(rows => rows.map(row => row.getAttribute('data-y3client-size-code')));
      assert.deepEqual(activeCodes, ['102', '103', '104', '105'], 'Stock filter must hide exact available zero, while preserving blank and negative values');
      const detailCodes = await blackCard.locator('[data-y3client-inventory-detail-row]').evaluateAll(rows => rows.map(row => row.getAttribute('data-y3client-size-code')));
      assert.deepEqual(detailCodes, activeCodes, 'Details must show the same filtered sizes as primary stock/sales rows');
      assert.equal(await page.locator('[data-y3client-color-code="-7-"] [data-y3client-inventory-size-row]').count(), 0);
      assert.equal(await page.locator('[data-y3client-color-code="-7-"] [data-y3client-inventory-empty]').isVisible(), true, 'A color with no matching sizes needs an explicit empty state');
      assert.deepEqual(await page.locator('[data-y3client-inventory-totals]').allTextContents(), totalsBefore, 'Filtering must not change server-provided color or overall totals');
      await page.locator('[data-y3client-size-unit="US"]').click();
      assert.equal(await filter.isChecked(), true, 'Unit switching must retain the current stock filter');
      assert.equal(await details.getAttribute('open'), '', 'Unit switching should retain an already-open metric detail section');
      assert.equal(await blackCard.locator('[data-y3client-inventory-size-row]').count(), 4);
      await filter.uncheck();
      assert.equal(await blackCard.locator('[data-y3client-inventory-size-row]').count(), 5, 'Removing the filter must restore hidden sizes');
      assert.equal(await page.locator('[data-y3client-color-code="-7-"] [data-y3client-inventory-size-row]').count(), 5);
      await assertFits(page, width);
      await page.screenshot({ path: path.join(output, `inventory-footwear-${width}.png`), fullPage: true });
      const eventCount = await page.evaluate(() => {
        let count = 0;
        document.getElementById('combined-target').addEventListener('y3client:inventory-show-table', () => count++);
        document.querySelector('[data-y3client-inventory-table-button]').click();
        return count;
      });
      assert.equal(eventCount, 1, 'Table fallback must dispatch exactly one event');
      reports.push({ width, parsedColors: parsed.colors.length, preservedMetrics: 4, phoneFit: true, units: 4 });
      assert.equal(unknown.length, 0, 'Every request must stay within local fixtures');
      await context.close();
    }
    // A non-inventory table must not be silently treated as a size matrix.
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await context.route('**/*', async route => {
      const body = fixtures.get(route.request().url());
      if (body === undefined) { await route.abort(); throw new Error('Unexpected fixture request'); }
      await route.fulfill({ contentType: 'text/html; charset=utf-8', body });
    });
    const page = await context.newPage();
    await page.goto(origin + fixturePaths.unsupported);
    await page.evaluate(presentation);
    assert.equal(await page.evaluate(() => window.__y3InventoryPresentation.parseInventoryTable(document.getElementById('unrelated'))), null);
    await page.goto(origin + fixturePaths.transposed);
    await page.evaluate(presentation);
    const rowSizeResult = await page.evaluate(() => window.__y3InventoryPresentation.parseInventoryTable(document.getElementById('T01_H')));
    assert(rowSizeResult, 'The live size-row / color-column stock matrix must parse');
    assert.equal(rowSizeResult.product.productCode, 'MOCK-F001');
    assert.deepEqual(rowSizeResult.sizeCodes, rowSizes);
    assert.equal(rowSizeResult.colors.length, 2, 'One nonblank color and one supplied total must remain, without empty grid padding');
    const oneColor = rowSizeResult.colors.find(color => !color.isTotal);
    const rowTotals = rowSizeResult.colors.find(color => color.isTotal);
    assert.equal(oneColor.color, '-4-');
    assert.deepEqual(oneColor.metrics.available.values, ['0', '1', '2', '3', '4', '5']);
    assert.deepEqual(oneColor.metrics.inTransit.values, ['', '', '', '', '', '']);
    assert.deepEqual(oneColor.metrics.reserved.values, ['-', '-', '-', '-', '-', '-']);
    assert.deepEqual(oneColor.metrics.sales.values, ['-1', '-1', '-1', '-1', '-1', '-1']);
    assert.equal(oneColor.metrics.available.total, '9', 'Color totals come from the server total row');
    assert.deepEqual(rowTotals.metrics.available.values, ['00', '10', '20', '30', '40', '50'], 'Per-size total cells keep their exact textual values');
    assert.equal(rowTotals.metrics.available.total, '90');
    const ambiguousPadding = await page.evaluate(() => {
      const table = document.getElementById('T01_H');
      table.rows[3].cells[4].textContent = '0';
      return window.__y3InventoryPresentation.parseInventoryTable(table);
    });
    assert.equal(ambiguousPadding, null, 'A nonblank quantity below an unnamed color must cause a safe table fallback, even when it is zero');
    await page.goto(fixturePaths.outside);
    const outsideBefore = await page.content();
    await page.evaluate(presentation);
    assert.equal(await page.evaluate(() => typeof window.__y3InventoryPresentation), 'undefined', 'The presentation API must not be installed on another origin');
    assert.equal(await page.content(), outsideBefore, 'Untrusted-origin DOM must remain unchanged');
    if (!standalone) await checkCombinedInventory(context);
    await context.close();
    const families = standalone ? [] : await checkInventoryFamilies(browser);
    const guide = standalone ? null : await checkSizeGuide(browser);
    const login = await checkStaffAutofill(browser);
    console.log(JSON.stringify({ inventoryFeatures: reports, transposedMatrix: true, combinedFrames: !standalone, families, guide, nonInventoryReportsPreserved: !standalone, untrustedOriginUntouched: true, login, screenshots: output }, null, 2));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
