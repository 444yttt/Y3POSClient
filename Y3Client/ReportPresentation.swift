import Foundation

enum ReportPresentation {
    static func mergedReplacement(for path: [Int], previous: [FramePane], current: [FramePane]) -> FramePane? {
        guard previous.first(where: { $0.path == path })?.kind == .result,
              current.first(where: { $0.path == path })?.kind == .controls else { return nil }
        let results = current.filter { $0.kind == .result }
        return results.count == 1 ? results[0] : nil
    }

    // Keep the site's data document, forms, handlers and named frames intact. Only the
    // read-only condition summary and delegates for its original pager are added there.
    static let script = #"""
    (() => {
      'use strict';
      const ORIGIN='https://adidas-y3.poscmcloud.jp:15505';
      const reportPath=/^\/scripts\/verona\/(?:print|display|dwh)\/(prtz\d+)(?:_\d+)*\.asp$/i;
      const trusted=win=>{try{return win.location.origin===ORIGIN;}catch(_){return false;}};
      let host;
      try{host=window.top;if(!trusted(host)||!reportPath.test(host.location.pathname)||!host.document.querySelector('frameset'))return;}catch(_){return;}
      if(host.__y3ClientReportMerge){host.__y3ClientReportMerge.reconcile();return;}
      const generated='[data-y3client-report-combined]';
      const clean=value=>String(value??'').normalize('NFKC').replace(/\s+/g,' ').trim();
      const key=value=>clean(value).replace(/[\s:：]/g,'');
      const created=/^(作成日付|作成日時|更新日時|更新日付|更新日)$/;
      const labels=new Set(['店舗','店舗名','日付','期間','業務区分','年度','シーズン','カテゴリー','カテゴリ','ブランド','サブブランド','アイテム','担当者','レシートNo','レシートNo.','レシートNO','レシートNO.','JAN']);
      const state={primary:null,secondary:null,view:null,signature:'',readySubmission:0};
      let accepted=null,ownPager=null,running=false,scheduled=false;
      const watched=new WeakSet();
      const current=frame=>{try{return trusted(frame.win)&&frame.win.document===frame.doc;}catch(_){return false;}};
      const clear=()=>{
        if(state.primary)state.primary.documentElement.removeAttribute('data-y3client-report-primary');
        if(state.secondary)state.secondary.documentElement.removeAttribute('data-y3client-report-secondary');
        state.view?.remove();state.primary=null;state.secondary=null;state.view=null;state.signature='';
      };
      const invalidate=()=>{
        clear();
        const navigation=host.__y3ClientNavigation;
        if(navigation&&(navigation.resultSubmissionRevision===state.readySubmission||
          (accepted&&navigation.submissionRevision>accepted.submission)))navigation.resultSubmissionRevision=0;
        state.readySubmission=0;
      };
      const schedule=()=>{if(scheduled)return;scheduled=true;host.setTimeout(()=>{scheduled=false;reconcile();},60);};
      const leaves=()=>{
        const all=[];
        const walk=(win,depth)=>{
          if(depth>8||!trusted(win)||all.length>=32)return;
          const doc=win.document;
          if(!watched.has(doc)){
            watched.add(doc);
            win.addEventListener('load',schedule,{once:true});
            new MutationObserver(records=>{if(records.some(record=>!record.target.closest?.(generated)&&
              !(record.type==='childList'&&Array.from(record.addedNodes).every(node=>node.nodeType===1&&node.matches?.(generated))&&
                Array.from(record.removedNodes).every(node=>node.nodeType===1&&node.matches?.(generated)))))schedule();}).observe(doc.documentElement,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['disabled','selected']});
          }
          const frames=Array.from(doc.querySelectorAll('frame')).filter(frame=>frame.contentWindow);
          if(frames.length){for(const frame of frames)walk(frame.contentWindow,depth+1);return;}
          if(doc.body?.tagName==='BODY')all.push({win,doc,path:win.location.pathname});
        };
        walk(host,0);return all;
      };
      const tables=doc=>Array.from(doc.querySelectorAll('table')).filter(table=>!table.closest(generated)&&!table.querySelector('table'));
      const metadata=frame=>{
        if(frame.win.__y3ClientHasInventoryMetrics?.()||frame.win.__y3ClientIsInventoryMetadata?.()||
          frame.doc.querySelector('input[type="text" i],input[type="search" i],input[type="date" i],input[type="password" i],textarea'))return null;
        const fields=[],sources=[];
        for(const table of tables(frame.doc)){
          const rows=Array.from(table.rows);
          if(rows.length<2||rows.length>40||table.querySelector('input:not([type="hidden" i]),select,button,textarea'))continue;
          const entries=[];
          for(const row of rows){
            const cells=Array.from(row.cells);
            if(cells.length<2||cells.length>12||cells.length%2)continue;
            for(let index=0;index<cells.length;index+=2){
              const name=key(cells[index].textContent);
              if(!labels.has(name)&&!created.test(name))continue;
              entries.push({label:clean(cells[index].textContent),key:name,value:clean(cells[index+1].textContent)});
            }
          }
          if(entries.length>=2){fields.push(...entries);sources.push(table);}
        }
        if(!fields.some(field=>created.test(field.key)&&field.value)||!fields.some(field=>/^(店舗|店舗名|日付|期間)$/.test(field.key)&&field.value))return null;
        // A receipt table containing data is never consumed as a condition header.
        if(tables(frame.doc).some(table=>!sources.includes(table)&&table.rows.length>3&&!table.querySelector('input,select,button,textarea')))return null;
        return {frame,fields,sources};
      };
      const data=frame=>{
        if(frame.win.__y3ClientHasInventoryMetrics?.()||frame.win.__y3ClientIsInventoryMetadata?.()||frame.doc.documentElement.hasAttribute('data-y3client-inventory-primary'))return null;
        const candidates=tables(frame.doc).filter(table=>table.rows.length>=2&&
          !table.hasAttribute('data-y3client-report-summary')&&!table.closest('[data-y3client-form-table],[data-y3client-search-table],[data-y3client-pager-table]')&&
          !table.querySelector('input[type="text" i],input[type="password" i],textarea'));
        if(!candidates.length){
          const message=clean(Array.from(frame.doc.body.childNodes).filter(node=>!node.matches?.(generated)&&!node.matches?.('script,style')).map(node=>node.textContent).join(' '));
          if(message.length>1000||!/(該当(?:する)?データ(?:が|は)?(?:ありません|存在しません)|対象(?:の)?データ(?:が|は)?ありません)/.test(message))return null;
          return {frame,tables:[],signature:JSON.stringify(message)};
        }
        return {frame,tables:candidates,signature:JSON.stringify(candidates.map(table=>table.textContent))};
      };
      const pair=frames=>{
        const family=reportPath.exec(host.location.pathname)?.[1].toLowerCase();
        const relevant=frames.filter(frame=>reportPath.exec(frame.path)?.[1].toLowerCase()===family);
        if(relevant.some(frame=>frame.doc.readyState!=='complete'))return null;
        const headers=relevant.map(metadata).filter(Boolean);
        if(headers.length!==1)return null;
        const header=headers[0],results=relevant.filter(frame=>frame!==header.frame).map(data).filter(Boolean);
        return results.length===1?{header,result:results[0]}:null;
      };
      const node=(doc,tag,attribute,text)=>{const result=doc.createElement(tag);if(attribute)result.setAttribute(attribute,'');if(text!==undefined)result.textContent=text;return result;};
      const installStyle=doc=>{
        if(doc.getElementById('y3client-combined-report-style'))return;
        const style=node(doc,'style');style.id='y3client-combined-report-style';style.textContent=`
          [data-y3client-report-combined] { max-width:100%; margin:0 0 18px; color:#17191d; font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-report-combined] * { box-sizing:border-box; }
          [data-y3client-report-combined] h1 { margin:0 0 8px; font:700 23px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; letter-spacing:-.03em; }
          [data-y3client-report-caption] { margin:3px 0; color:#515b64; font-size:12px; overflow-wrap:anywhere; }
          [data-y3client-report-updated] { margin:4px 0 12px; color:#737b82; font-size:11px; overflow-wrap:anywhere; }
          [data-y3client-report-conditions] { margin:12px 0; padding:0 12px; border:1px solid #dfe4e8; border-radius:12px; background:#fff; }
          [data-y3client-report-conditions] summary { min-height:44px; padding:12px 0; cursor:pointer; font-size:12px; color:#59626c; }
          [data-y3client-report-fields] { margin:0 0 12px; }
          [data-y3client-report-fields] div { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,2fr); gap:8px; padding:6px 0; border-top:1px solid #eef0f2; }
          [data-y3client-report-fields] dt { color:#737b82; font-size:11px; }
          [data-y3client-report-fields] dd { margin:0; font-size:12px; overflow-wrap:anywhere; white-space:normal; }
          [data-y3client-report-pages] { display:flex; flex-wrap:wrap; align-items:center; gap:8px; margin:12px 0; }
          [data-y3client-report-pages] label { display:flex; align-items:center; gap:8px; color:#59626c; font-size:12px; }
          [data-y3client-report-pages] select, [data-y3client-report-pages] button { min-width:44px; min-height:48px; max-width:100%; padding:8px 12px; border:1px solid #dce1e5; border-radius:9px; background:#fff; color:#17191d; font:14px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-report-pages] button:disabled { opacity:.4; }
          [data-y3client-report-combined] :focus-visible { outline:2px solid #111; outline-offset:2px; }
          html[data-y3client-report-primary] table[data-y3client-report-data-table]:not([data-y3client-result-list='cards']) { display:block!important; width:100%!important; max-width:100%!important; overflow-x:auto!important; box-sizing:border-box; }
        `;(doc.head||doc.documentElement).appendChild(style);
      };
      const pager=(header,doc)=>{
        const original=header.frame.doc.querySelector('select[name="PgSelect" i]');
        if(!original)return null;
        const section=node(doc,'div','data-y3client-report-pages'),label=node(doc,'label',null,'ページ');
        const select=node(doc,'select');select.setAttribute('aria-label','検索結果のページ');
        for(const option of original.options){const copy=node(doc,'option',null,option.text);copy.value=option.value;copy.disabled=option.disabled;select.appendChild(copy);}select.value=original.value;
        label.appendChild(select);section.appendChild(label);
        const max=header.frame.doc.querySelector('input[name="PgMax" i]');
        if(max&&/^\d{1,6}$/.test(max.value))section.appendChild(node(doc,'span',null,'/ '+max.value));
        for(const [name,title] of [['hyouzi','表示'],['Front','前へ'],['Back','次へ']]){
          const control=header.frame.doc.querySelector('input[name="'+name+'" i],button[name="'+name+'" i]');if(!control)continue;
          const button=node(doc,'button',null,title);button.type='button';button.disabled=control.disabled;button.setAttribute('aria-label','検索結果 '+title);
          button.addEventListener('click',()=>{
            if(!current(header.frame)||!original.isConnected||!control.isConnected||control.disabled)return;
            original.value=select.value;
            // Delegation keeps legacy Form.submit(), target names and frame-local handlers.
            const navigation=host.__y3ClientNavigation||(host.__y3ClientNavigation={submissionRevision:0,resultSubmissionRevision:0});
            navigation.lastSubmissionAt=Date.now();navigation.submissionRevision=Math.min((navigation.submissionRevision||0)+1,1000000000);
            ownPager={submission:navigation.submissionRevision,header:header.frame.doc};
            control.click();reconcile();
          });section.appendChild(button);
        }
        return section;
      };
      const build=(header,result)=>{
        const doc=result.frame.doc,section=node(doc,'section','data-y3client-report-combined');
        section.appendChild(node(doc,'h1',null,'検索結果'));
        for(const field of header.fields.filter(field=>/^(店舗|店舗名|日付|期間)$/.test(field.key)&&field.value)){
          // 99:59:59 is the site's end-of-day query sentinel, not a valid clock time.
          const display=field.value.replace(/ 00:00:00(?=\s*[~〜～])/g,'').replace(/ 99:59:59/g,' 終日');
          section.appendChild(node(doc,'p','data-y3client-report-caption',display));
        }
        const update=header.fields.find(field=>created.test(field.key));
        if(update)section.appendChild(node(doc,'p','data-y3client-report-updated','作成日時 '+update.value));
        const details=node(doc,'details','data-y3client-report-conditions');details.appendChild(node(doc,'summary',null,'検索内容を確認'));
        const fields=node(doc,'dl','data-y3client-report-fields');
        for(const field of header.fields.filter(field=>field.value)){const row=node(doc,'div');row.appendChild(node(doc,'dt',null,field.label));row.appendChild(node(doc,'dd',null,field.value));fields.appendChild(row);}details.appendChild(fields);section.appendChild(details);
        const pages=pager(header,doc);if(pages)section.appendChild(pages);
        return section;
      };
      function reconcile(){
        if(running)return !!state.view;
        running=true;
        try{
          const match=pair(leaves());
          if(!match){invalidate();return false;}
          const {header,result}=match,submission=host.__y3ClientNavigation?.submissionRevision||0;
          const headerSignature=JSON.stringify(header.fields);
          if(accepted&&submission>accepted.submission){
            const freshHeader=header.frame.doc!==accepted.header||headerSignature!==accepted.headerSignature||header.sources.some((table,index)=>table!==accepted.headerTables[index]);
            const freshResult=result.frame.doc!==accepted.result||result.signature!==accepted.resultSignature||result.tables.some((table,index)=>table!==accepted.resultTables[index]);
            const retainedPagerHeader=ownPager?.submission===submission&&ownPager.header===header.frame.doc;
            if((!freshHeader&&!retainedPagerHeader)||!freshResult){invalidate();return false;}
          }
          const originalPage=header.frame.doc.querySelector('select[name="PgSelect" i]');
          const pagerState=[originalPage?.value,originalPage?Array.from(originalPage.options).map(option=>[option.value,option.text,option.disabled]):[],
            header.frame.doc.querySelector('input[name="PgMax" i]')?.value,
            ['hyouzi','Front','Back'].map(name=>header.frame.doc.querySelector('input[name="'+name+'" i],button[name="'+name+'" i]')?.disabled)];
          const signature=JSON.stringify([header.fields,result.signature,pagerState]);
          if(state.primary!==result.frame.doc||state.secondary!==header.frame.doc||state.signature!==signature||!state.view?.isConnected){
            const open=state.view?.querySelector('details')?.open||false;
            clear();installStyle(result.frame.doc);state.view=build(header,result);state.view.querySelector('details').open=open;
            result.frame.doc.body.prepend(state.view);state.primary=result.frame.doc;state.secondary=header.frame.doc;state.signature=signature;
            result.frame.doc.documentElement.setAttribute('data-y3client-report-primary','');header.frame.doc.documentElement.setAttribute('data-y3client-report-secondary','');
          }
          for(const table of result.tables)if(!table.closest('[data-y3client-table-scroll]'))table.setAttribute('data-y3client-report-data-table','');
          const navigation=host.__y3ClientNavigation||(host.__y3ClientNavigation={submissionRevision:0,resultSubmissionRevision:0});
          state.readySubmission=navigation.resultSubmissionRevision=submission;
          accepted={submission,header:header.frame.doc,headerTables:header.sources,headerSignature,result:result.frame.doc,resultTables:result.tables,resultSignature:result.signature};
          ownPager=null;
          return true;
        }catch(_){invalidate();return false;}finally{running=false;}
      }
      host.__y3ClientReportMerge={reconcile};reconcile();
    })();
    """#
}
