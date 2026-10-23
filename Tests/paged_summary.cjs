// Source-shaped created-at-only header with PageNum and three original POST forms.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const origin='http://127.0.0.1:17869',base='/scripts/verona/print/prtz096';
const get=(filename,name)=>fs.readFileSync(path.join(__dirname,'../Y3Client',filename),'utf8').match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`))[1].replaceAll('https://adidas-y3.poscmcloud.jp:15505',origin);
const scripts=['viewportAndTouch','mobileRedesign','inventoryPresentation'].map(n=>get('LegacySiteSupport.swift',n)).concat(get('ReportPresentation.swift','script')).join('\n');
(async()=>{
 const server=spawn('python3',[path.join(__dirname,'WebKitHarness/serve_fixtures.py'),'--port','17869'],{stdio:'ignore'});let browser;
 try{
  for(let i=0;i<100;i++){try{if((await fetch(origin+'/health')).ok)break;}catch(_){}await new Promise(r=>setTimeout(r,30));}
  browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined,args:['--no-sandbox']});
  for(const width of [390,320]){
   const context=await browser.newContext({viewport:{width,height:844}});
   await context.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
   await context.addInitScript({content:'document.addEventListener("DOMContentLoaded",()=>{'+scripts+'},{once:true});'});
   const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.goto(origin+base+'_1.asp?mode=page-num');
   const data=()=>page.frames().find(f=>f.name()==='receipt-data');
   const header=()=>page.frames().find(f=>f.name()==='receipt-header');
   await page.waitForFunction(()=>{__y3ClientReportMerge?.reconcile();return !!frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]');});
   assert.equal((await page.evaluate(get('LegacySiteSupport.swift','discoverFrames'))).filter(p=>p.kind==='result').length,1);
   assert.equal(await header().evaluate(()=>top.__y3ClientReportMerge.classify(window)),'metadata');
   assert.equal(await data().locator('[data-y3client-report-fields] div').count(),1);
   assert.equal(await header().evaluate(()=>fixtureSummaryOriginals.every(o=>o.form.isConnected&&o.form.target===o.target&&o.form.action===o.action&&o.fields.every(f=>f.form===o.form))),true);
   await data().locator('[data-y3client-report-pages] select').selectOption('2');
   await data().getByRole('button',{name:'検索結果 表示',exact:true}).click();
   await page.waitForFunction(()=>{__y3ClientReportMerge?.reconcile();return frames['summary-report']?.fixtureSummaryPost?.values?.token?.[0]==='FICTIONAL-SHOW'&&frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]')?.textContent.includes('検索結果');});
   assert.deepEqual(await page.evaluate(()=>frames['summary-report'].fixtureSummaryPost),{method:'POST',values:{token:['FICTIONAL-SHOW'],PageNum:['2'],submit3:[' 表示 ']}});
   assert.equal(await data().getByRole('button',{name:'検索結果 次へ',exact:true}).isDisabled(),true);
   await data().getByRole('button',{name:'検索結果 前へ',exact:true}).click();
   await page.waitForFunction(()=>{__y3ClientReportMerge?.reconcile();return frames['summary-report']?.fixtureSummaryPost?.values?.token?.[0]==='FICTIONAL-PREVIOUS'&&frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]');});
   assert.deepEqual(await page.evaluate(()=>frames['summary-report'].fixtureSummaryPost),{method:'POST',values:{token:['FICTIONAL-PREVIOUS'],PageNum:['1'],submit1:['前ページ']}});
   await data().getByRole('button',{name:'検索結果 次へ',exact:true}).click();
   await page.waitForFunction(()=>{__y3ClientReportMerge?.reconcile();return frames['summary-report']?.fixtureSummaryPost?.values?.token?.[0]==='FICTIONAL-NEXT'&&frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]');});
   assert.deepEqual(await page.evaluate(()=>frames['summary-report'].fixtureSummaryPost),{method:'POST',values:{token:['FICTIONAL-NEXT'],PageNum:['2'],submit2:['次ページ']}});
   assert.equal(await data().evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),true);
   // A date caption beside a real aggregate is not a metadata-only document.
   await header().evaluate(()=>{const t=document.createElement('table');t.innerHTML='<tr><th>店舗</th><th>金額</th></tr><tr><td>架空A</td><td>12</td></tr>';document.body.appendChild(t);});
   assert.equal(await header().evaluate(()=>top.__y3ClientReportMerge.classify(window)),null);
   await page.evaluate(()=>__y3ClientReportMerge.reconcile());
   assert.equal(await data().locator('[data-y3client-report-combined]').count(),0,'Keep meaningful aggregates separate');
   // The same leaf can contain its caption, pager and ranking data with hidden row keys.
   await page.goto(origin+base+'_1.asp?mode=inline-ranking');
   const ranking=()=>page.frames().find(f=>f.name()==='ranking-data');
   await ranking().locator('#ranking-original-table').waitFor();
   assert.equal(await ranking().evaluate(()=>top.__y3ClientReportMerge.classify(window)),null);
   const rankingPanes=(await page.evaluate(get('LegacySiteSupport.swift','discoverFrames'))).filter(p=>p.kind==='result');
   assert.equal(rankingPanes.length,1,'Inline ranking must remain an accessible result');
   assert.equal(await ranking().evaluate(()=>{
    const table=document.getElementById('ranking-original-table'),form=document.getElementById('ranking-original-form');
    return table.rows.length===7&&Array.from(table.rows).every(row=>row.cells.length===9)&&table.querySelectorAll('input[type="hidden"]').length===20&&
     Array.from(table.querySelectorAll('input')).every(input=>input.form===form)&&fixtureSummaryOriginals.every(o=>o.form.isConnected&&o.form.target===o.target&&o.form.action===o.action&&o.fields.every(f=>f.form===o.form));
   }),true,'All original tables and form ownership survive');
   await page.evaluate('('+get('LegacySiteSupport.swift','frameFocus')+')('+JSON.stringify(rankingPanes[0].path)+')');
   assert.equal(await ranking().evaluate(()=>innerHeight>700&&innerWidth===document.documentElement.clientWidth),true);
   await ranking().locator('select[name="PageNum"]').selectOption('2');
   await ranking().locator('input[name="submit3"]').click();
   await page.waitForFunction(()=>frames['summary-report']?.fixtureSummaryPost?.values?.token?.[0]==='FICTIONAL-SHOW'&&frames['summary-report']?.frames['ranking-data']?.document.getElementById('ranking-original-table'));
   assert.deepEqual(await page.evaluate(()=>frames['summary-report'].fixtureSummaryPost),{method:'POST',values:{token:['FICTIONAL-SHOW'],PageNum:['2'],submit3:[' 表示 ']}});
   assert.equal(await ranking().evaluate(()=>top.__y3ClientReportMerge.classify(window)),null);
   await page.goto(origin+base+'_1.asp?mode=unnamed-page-num');
   await page.waitForFunction(()=>{__y3ClientReportMerge?.reconcile();return !!frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]');});
   assert.equal(await data().locator('[data-y3client-report-pages] button').count(),3);
   assert.equal(await header().evaluate(()=>fixtureSummaryOriginals.every(o=>o.form.isConnected&&o.fields.every(f=>f.form===o.form))&&Array.from(document.querySelectorAll('input[type="submit"]')).every(control=>!control.name)),true);
   await data().locator('[data-y3client-report-pages] select').selectOption('2');
   for(const [title,token,number] of [['表示','FICTIONAL-SHOW','2'],['前へ','FICTIONAL-PREVIOUS','1'],['次へ','FICTIONAL-NEXT','2']]){
    await data().getByRole('button',{name:'検索結果 '+title,exact:true}).click();
    await page.waitForFunction(token=>{__y3ClientReportMerge?.reconcile();return frames['summary-report']?.fixtureSummaryPost?.values?.token?.[0]===token&&frames['summary-report']?.frames['receipt-data']?.document.querySelector('[data-y3client-report-combined]');},token);
    assert.deepEqual(await page.evaluate(()=>frames['summary-report'].fixtureSummaryPost),{method:'POST',values:{token:[token],PageNum:[number]}});
   }
   await header().evaluate(()=>document.getElementById('summary-show').appendChild(document.querySelector('input[type="submit"]').cloneNode(true)));
   await page.evaluate(()=>__y3ClientReportMerge.reconcile());
   assert.equal(await data().getByRole('button',{name:'検索結果 表示',exact:true}).count(),0,'Ambiguous unnamed controls are never guessed');
   assert.deepEqual(errors,[]);await context.close();
  }
  console.log(JSON.stringify({createdOnlyHeader:true,pageNumThreeForms:true,originalPostValues:true,originalTargets:true,aggregatePreserved:true,inlineRankingWithTwentyHiddenKeys:true,unnamedPagerOriginalPost:true,ambiguousControlsIgnored:true,widths:[390,320]}));
 }finally{if(browser)await browser.close();server.kill();}
})().catch(e=>{console.error(e);process.exitCode=1;});
