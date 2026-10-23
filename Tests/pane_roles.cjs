// Fictional source-shaped navigation/pager/data leaves. URL suffixes alone do not prove results.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const origin='http://127.0.0.1:17879',base='/scripts/verona/print/prtz094';
const get=(filename,name)=>fs.readFileSync(path.join(__dirname,'../Y3Client',filename),'utf8').match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`))[1].replaceAll('https://adidas-y3.poscmcloud.jp:15505',origin);
const scripts=['viewportAndTouch','mobileRedesign','inventoryPresentation'].map(n=>get('LegacySiteSupport.swift',n)).concat(get('ReportPresentation.swift','script')).join('\n');
const discovery=get('LegacySiteSupport.swift','discoverFrames'),focus=get('LegacySiteSupport.swift','frameFocus');
(async()=>{
 const server=spawn('python3',[path.join(__dirname,'WebKitHarness/serve_fixtures.py'),'--port','17879'],{stdio:'ignore'});let browser;
 try{
  for(let i=0;i<100;i++){try{if((await fetch(origin+'/health')).ok)break;}catch(_){}await new Promise(r=>setTimeout(r,30));}
  browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined,args:['--no-sandbox']});
  for(const width of [390,320]){
   const context=await browser.newContext({viewport:{width,height:844}});
   await context.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
   await context.addInitScript({content:'document.addEventListener("DOMContentLoaded",()=>{'+scripts+'},{once:true});'});
   const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.goto(origin+base+'_2.asp?scenario=pane-roles');
   await page.waitForTimeout(250);
   assert.deepEqual((await page.evaluate(discovery)).map(p=>({path:p.path,kind:p.kind})),[{path:[0],kind:'navigation'},{path:[1],kind:'controls'},{path:[2],kind:'result'},{path:[3],kind:'result'}]);
   assert.equal(await page.evaluate(()=>frames['role-data'].document.getElementById('readonly-output').elements.reported_value.readOnly),true);
   const values=()=>page.evaluate(()=>Array.from(frames['role-data'].document.getElementById('role-real-data').rows).map(r=>Array.from(r.cells,c=>c.textContent)));
   const before=await values();
   for(const index of [2,3]){
    assert.equal(await page.evaluate('('+focus+')('+JSON.stringify([index])+')'),true);
    await page.waitForTimeout(250);
    assert.equal(await page.evaluate(i=>frames[i].innerHeight>=800,index),true);
   }
   assert.deepEqual(await values(),before);
   assert.equal(await page.evaluate(()=>frames['role-aggregate'].document.getElementById('role-real-aggregate').rows.length),5);
   assert.equal(await page.evaluate(()=>__y3ClientReportMerge.classify(frames['role-aggregate'])),null);
   await page.goto(origin+base+'_1.asp?scenario=pane-roles');
   await page.waitForTimeout(200);
   const expected=[{path:[0],kind:'navigation'},{path:[1],kind:'result'}];
   assert.deepEqual((await page.evaluate(discovery)).map(p=>({path:p.path,kind:p.kind})),expected);
   for(const text of ['対象となるデータは存在しません。','印紙税額マスターの設定をおこなってください。']){
    await page.evaluate(message=>{frames[1].document.body.textContent=message;},text);
    assert.deepEqual((await page.evaluate(discovery)).map(p=>({path:p.path,kind:p.kind})),expected);
   }
   assert.deepEqual(errors,[]);await context.close();
  }
  console.log(JSON.stringify({navigationNotResult:true,pagerNotResult:true,readonlyDataResult:true,legitimateAggregateKept:true,emptyAndConfigurationMessagesReachable:true,widths:[390,320]}));
 }finally{if(browser)await browser.close();server.kill();}
})().catch(e=>{console.error(e);process.exitCode=1;});
