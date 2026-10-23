// Fictional product-master detail with an original return button in its final row.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const origin='https://adidas-y3.poscmcloud.jp:15505';
const source=fs.readFileSync(path.join(__dirname,'../Y3Client/LegacySiteSupport.swift'),'utf8');
const script=name=>source.match(new RegExp('static let '+name+' = #"""([\\s\\S]*?)"""#'))[1];
const summary='<table id="product-summary"><tr><td>品番</td><td>MOCK-MASTER001</td><td>カラー</td><td>MOCK-COLOR</td><td>サイズ</td><td>317</td><td>商品名</td><td colspan="3">架空商品</td></tr><tr>'+Array.from({length:10},(_,i)=>'<td>架空条件'+i+'</td>').join('')+'</tr><tr><td>作成日付</td><td colspan="9">2026/10/23 12:00:00 現在</td></tr></table>';
const counts=[1,2,4,4,3,2,4,6,6,5,6,6,6,3,6,2,4,2,2,2,1];
const details='<form name="original-detail"><table id="product-detail">'+counts.map((n,index)=>'<tr>'+Array.from({length:n},(_,column)=>'<td'+(column===n-1?' colspan="'+(7-n)+'"':'')+'>'+(index===20?'<input id="original-back" type="button" name="button1" value="戻る" onclick="window.fixtureBackClicks++">':'架空商品項目'+index+'-'+column)+'</td>').join('')+'</tr>').join('')+'</table></form>';
const shell=body=>'<!doctype html><html><head><meta charset="utf-8"></head><body>'+body+'<script>window.fixtureBackClicks=0;window.originalBack=document.getElementById("original-back");window.originalBackHandler=originalBack?.onclick;</script></body></html>';
(async()=>{
 const b=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||'/usr/bin/chromium',args:['--no-sandbox']});
 try{
  const c=await b.newContext({viewport:{width:390,height:844}});
  await c.route('**/*',r=>{const p=new URL(r.request().url()).pathname;if(p.endsWith('dstz100_3.asp'))return r.fulfill({contentType:'text/html',body:'<html><head></head><frameset rows="55,*"><frame src="/fixture/nav"><frame name="master-data" src="/scripts/verona/display/dstz100_3_2.asp"></frameset></html>'});return r.fulfill({contentType:'text/html; charset=utf-8',body:p.endsWith('dstz100_3_2.asp')?shell(summary+details):shell('<a href="/fixture/home">検索条件</a>')});});
  const p=await c.newPage();await p.goto(origin+'/scripts/verona/display/dstz100_3.asp');
  for(const f of p.frames())for(const name of ['viewportAndTouch','mobileRedesign','inventoryPresentation'])await f.evaluate(script(name));
  const data=p.frames().find(f=>f.name()==='master-data');
  assert.equal(await data.evaluate(()=>__y3ClientIsInventoryMetadata()),false,'A Back button never hides the product detail table as metadata');
  const panes=await p.evaluate(script('discoverFrames'));assert.equal(panes.find(p=>p.path[0]===1)?.kind,'result');
  await p.evaluate('('+script('frameFocus')+')([1])');
  assert.equal(await data.evaluate(()=>innerWidth>0&&innerHeight>0&&document.getElementById('product-detail').getBoundingClientRect().height>0),true);
  assert.equal(await data.evaluate(()=>originalBack===document.getElementById('original-back')&&originalBack.onclick===originalBackHandler),true);
  await data.locator('#original-back').click();assert.equal(await data.evaluate(()=>fixtureBackClicks),1);
  await data.evaluate(()=>{document.getElementById('product-detail').remove();const table=document.createElement('table');table.id='pager-only';table.innerHTML='<tr><td><select name="PgSelect"><option>1</option><option>2</option></select></td></tr><tr><td><input type="button" value="表示"></td></tr><tr><td><input type="button" value="前ページ"></td></tr><tr><td><input type="button" value="次ページ"></td></tr>';document.body.appendChild(table);});
  assert.equal(await data.evaluate(()=>__y3ClientIsInventoryMetadata()),true,'Pager-only rows still stay metadata');
  console.log(JSON.stringify({status:'passed',checks:['master detail with final original Back stays result','metadata and detail original nodes preserved','positive focused detail bounds','original Back handler unchanged','pure pager remains metadata']}));
 }finally{await b.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
