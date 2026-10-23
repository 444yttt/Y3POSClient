// Read-only fictional all-location report; every request stays on loopback.
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const origin='http://127.0.0.1:17868', base='/scripts/verona/print/prtz450';
const legacy=fs.readFileSync(path.join(__dirname,'../Y3Client/LegacySiteSupport.swift'),'utf8');
const report=fs.readFileSync(path.join(__dirname,'../Y3Client/ReportPresentation.swift'),'utf8');
const script=(source,name)=>source.match(new RegExp('static let '+name+' = #"""([\\s\\S]*?)"""#'))[1].replaceAll('https://adidas-y3.poscmcloud.jp:15505',origin);
const adapt=['viewportAndTouch','mobileRedesign','inventoryPresentation'].map(name=>script(legacy,name)).concat(script(report,'script')).join('\n');
const serverCode=`import sys\nsys.path.insert(0,${JSON.stringify(path.join(__dirname,'WebKitHarness'))})\nfrom all_locations_fixtures import response\nfrom urllib.parse import urlsplit,parse_qs\nfrom http.server import BaseHTTPRequestHandler,ThreadingHTTPServer\nclass Handler(BaseHTTPRequestHandler):\n def log_message(self,*args):pass\n def do_POST(self):\n  self.values=parse_qs(self.rfile.read(int(self.headers.get('Content-Length','0'))).decode(),keep_blank_values=True);self.do_GET()\n def do_GET(self):\n  parsed=urlsplit(self.path);body=response(parsed.path,parsed.query,self.command,getattr(self,'values',{}))\n  if parsed.path=='/health':body='ok'\n  self.send_response(200 if body is not None else 404);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write((body or '').encode())\nThreadingHTTPServer(('127.0.0.1',17868),Handler).serve_forever()\n`;
(async()=>{
 const server=spawn('python3',['-c',serverCode],{stdio:'ignore'});let browser;
 try{
  for(let i=0;i<100;i++){try{if((await fetch(origin+'/health')).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
  browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||'/usr/bin/chromium',args:['--no-sandbox']});
  for(const width of [390,320]){
   const context=await browser.newContext({viewport:{width,height:844},isMobile:true,hasTouch:true});
   await context.route('**/*',async route=>{if(!route.request().url().startsWith(origin+'/'))return route.abort();const response=await route.fetch();let body=await response.text();const injection='<script>'+ (body.includes('</body>')?adapt:'document.addEventListener("DOMContentLoaded",()=>{'+adapt+'},{once:true});')+'</script>';body=body.includes('</body>')?body.replace('</body>',()=>injection+'</body>'):body.replace('</head>',()=>injection+'</head>');await route.fulfill({response,body});});
   const p=await context.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));
   await p.goto(origin+base+'_1.asp');const condition=p.frames().find(f=>f.url().includes('_1_2.asp'));
   await condition.locator('[name=ft_goods_code]').fill('MOCK-ALL001');await condition.locator('[name=ken]').click();
   await p.waitForURL(origin+base+'_2.asp');
   await p.waitForFunction(()=>Array.from(frames).some(f=>f.document.documentElement.hasAttribute('data-y3client-report-primary')));
   let panes=await p.evaluate(script(legacy,'discoverFrames'));assert.equal(panes.filter(p=>p.kind==='result').length,1,'Only product data, not metadata, is a result');
   assert.deepEqual(panes.find(p=>p.kind==='result').path,[2]);
   await p.evaluate('('+script(legacy,'frameFocus')+')([2])');
   let data=p.frames().find(f=>f.url().includes('_2_2.asp'));
   assert.deepEqual(await data.evaluate(()=>fixtureAllSearchFields),{unchanged:['FICTIONAL-SEARCH-TOKEN'],ft_goods_code:['MOCK-ALL001']});
   assert.equal(await data.evaluate(()=>fixtureOriginalDetailForm===document.getElementById('all-location-detail')),true);
   await data.locator('input[type=submit]').click();await p.waitForURL(origin+base+'_3.asp');
   await p.waitForFunction(()=>Array.from(frames).some(f=>f.document.documentElement.hasAttribute('data-y3client-report-primary')));
   panes=await p.evaluate(script(legacy,'discoverFrames'));assert.equal(panes.filter(p=>p.kind==='result').length,1);assert.deepEqual(panes.find(p=>p.kind==='result').path,[2]);
   await p.evaluate('('+script(legacy,'frameFocus')+')([2])');data=p.frames().find(f=>f.url().includes('_3_2.asp'));
   await data.locator('[data-y3client-all-locations-view]').waitFor();
   assert.deepEqual(await data.evaluate(()=>fixtureAllDetailFields),{product:['MOCK-ALL001'],unchanged:['FICTIONAL-DETAIL-TOKEN']});
   const original=await data.evaluate(()=>JSON.stringify(fixtureStockData()));
   assert.equal(await data.locator('[data-y3client-all-locations-row]').count(),4);
   assert.deepEqual(await data.locator('[data-y3client-all-locations-quantity]').allTextContents(),['1','0','-1','—']);
   assert.equal(await data.locator('[data-y3client-all-locations-total-quantity]').innerText(),'006');
   const getSize=()=>data.locator('[data-y3client-all-locations-row][data-y3client-size-code="313"] td').first().innerText();
   for(const [unit,expected] of [['US','7.5'],['USW','8.5'],['UK','7'],['EU','40 2/3'],['CH','250'],['JP','25.5']]){
    await data.locator('[data-y3client-all-locations-unit="'+unit+'"]').click();assert((await getSize()).includes(expected));
    assert.deepEqual(await data.locator('[data-y3client-all-locations-quantity]').allTextContents(),['1','0','-1','—']);
    assert.equal(await data.evaluate(()=>JSON.stringify(fixtureStockData())),original);
   }
   assert((await data.locator('[data-y3client-all-locations-row][data-y3client-size-code="317"]').innerText()).includes('27.5'));
   assert.equal(await data.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),true);
   assert.equal(await data.locator('[data-y3client-all-locations-hint]:visible').count(),0);
   await data.evaluate(()=>{fixtureOriginalStock.rows[1].cells[2].textContent='999';});
   await data.waitForFunction(()=>document.querySelector('[data-y3client-all-locations-row][data-y3client-size-code=\"999\"]'));
   assert((await data.locator('[data-y3client-all-locations-row][data-y3client-size-code=\"999\"]').innerText()).includes('999'));
   assert.equal(await data.locator('[data-y3client-all-locations-unit]').count(),0,'Unknown category/size codes are not guessed as footwear');
   assert.deepEqual(await data.locator('[data-y3client-all-locations-quantity]').allTextContents(),['1','0','-1','—']);
   await data.locator('[data-y3client-all-locations-table-toggle]').click();assert.equal(await data.locator('#all-location-stock').isVisible(),true);
   await data.locator('[data-y3client-all-locations-table-toggle]').click();assert.equal(await data.locator('#all-location-stock').isVisible(),false);
   await data.evaluate(()=>{fixtureOriginalStock.rows[0].cells[9].textContent='未知の在庫列';});
   await data.waitForFunction(()=>!document.querySelector('[data-y3client-all-locations-view]'));
   assert.equal(await data.locator('#all-location-stock').isVisible(),true,'Unsupported layout restores the original source table');
   await data.locator('input[name=back]').click();await p.waitForURL(origin+base+'_2.asp');
   assert.deepEqual(errors,[]);await context.close();
  }
  console.log(JSON.stringify({status:'passed',phoneWidths:[390,320],checks:['original search POST','metadata plus product list one result','original detail form POST','metadata plus flat stock one result','source rows and totals preserved','six size units and unknown-code fallback','unknown values and negatives preserved','raw table toggling','original return navigation','unsupported source fallback']},null,2));
 }finally{if(browser)await browser.close();server.kill();}
})().catch(e=>{console.error(e);process.exitCode=1;});
