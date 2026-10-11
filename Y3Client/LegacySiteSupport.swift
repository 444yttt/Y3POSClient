import Foundation

struct FramePane: Identifiable {
    enum Kind: String { case condition, result, controls, navigation, export }
    let path: [Int]
    let title: String
    let kind: Kind
    var id: String { path.map(String.init).joined(separator: ".") }
}

enum LegacySiteSupport {
    // Structural counters only. No field values or report contents leave the web document.
    static let navigationState = #"""
    (() => {
      try {
        if (location.origin !== 'https://adidas-y3.poscmcloud.jp:15505') return {};
        const state = window.__y3ClientNavigation || {};
        return {
          submissionRevision: Number.isSafeInteger(state.submissionRevision) ? state.submissionRevision : 0,
          resultSubmissionRevision: Number.isSafeInteger(state.resultSubmissionRevision) ? state.resultSubmissionRevision : 0
        };
      } catch (_) { return {}; }
    })();
    """#
    // Runs inside each document, never through a native message or credentials bridge.
    static let viewportAndTouch = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const exportDocument = location.origin === 'https://adidas-y3.poscmcloud.jp:7705' &&
        location.pathname === '/dataspider/trigger/hanbai.asp';
      if ((location.origin !== origin && !exportDocument) || !document.documentElement) return;
      const root = document.documentElement;
      root.setAttribute('data-y3client-phone', '');
      const head = document.head;
      if (head && !head.querySelector('meta[name="viewport"]')) {
        const viewport = document.createElement('meta');
        viewport.name = 'viewport';
        viewport.content = 'width=device-width, initial-scale=1';
        head.appendChild(viewport);
      }
      if (head && !document.getElementById('y3client-touch-style')) {
        const style = document.createElement('style');
        style.id = 'y3client-touch-style';
        style.textContent = `
          html[data-y3client-phone] { -webkit-text-size-adjust: 100%; }
          html[data-y3client-phone] input:not([type="hidden" i]),
          html[data-y3client-phone] select,
          html[data-y3client-phone] textarea,
          html[data-y3client-phone] button {
            font-size: 16px !important; min-height: 44px; box-sizing: border-box;
          }
          html[data-y3client-phone] input[type="submit" i],
          html[data-y3client-phone] input[type="reset" i],
          html[data-y3client-phone] input[type="button" i],
          html[data-y3client-phone] button {
            min-width: 44px; padding: 8px 12px;
          }
          html[data-y3client-phone] input[name*="YYYYMMDD" i] {
            width: 9ch !important; min-width: 9ch; padding-inline: 3px;
          }
          html[data-y3client-phone] input:focus,
          html[data-y3client-phone] select:focus,
          html[data-y3client-phone] textarea:focus { scroll-margin-block: 88px; }
          html[data-y3client-phone] form[data-y3client-search] { max-width: 100%; }
          html[data-y3client-phone] table[data-y3client-search-table] {
            display: block; width: 100% !important; max-width: 100%; box-sizing: border-box;
          }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody { display: block; max-width: 100%; }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody > tr {
            display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px;
            width: 100%; box-sizing: border-box;
          }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody > tr > td {
            display: block; flex: 0 1 auto; width: auto !important; max-width: 100%;
            white-space: normal !important; box-sizing: border-box;
          }
          html[data-y3client-menu] a,
          html[data-y3client-export] a[download] {
            display: inline-block; font-size: 16px !important; line-height: 1.4;
            min-height: 44px; box-sizing: border-box; padding: 10px 6px;
          }
          html[data-y3client-phone] iframe[name="fraHinbanSearch"] {
            max-width: calc(100vw - 16px);
          }
          html[data-y3client-stock] #layer0 {
            left: 8px !important; right: 8px !important; width: auto !important;
            max-width: calc(100vw - 16px); height: min(65vh, 500px) !important;
          }
          html[data-y3client-stock] iframe[name="fraHinbanSearch"] {
            width: 100% !important; height: 100% !important;
          }
        `;
        head.appendChild(style);
      }
      if (/\/scripts\/verona\/menu\//i.test(location.pathname)) {
        root.setAttribute('data-y3client-menu', '');
      }
      if (/\/prtz011_1\.asp$/i.test(location.pathname)) root.setAttribute('data-y3client-stock', '');
      // Form elements may be outside FORM in these legacy tables; use their existing form ownership.
      for (const form of document.forms) {
        const fields = Array.from(form.elements).filter(element => element.tagName === 'INPUT' &&
          element.type !== 'hidden' && (['text', 'date', 'search'].includes(element.type) || /YYYYMMDD/i.test(element.name)));
        if (!fields.length) continue;
        form.setAttribute('data-y3client-search', '');
        for (const field of fields) {
          const table = field.closest('table');
          if (!table || table.querySelectorAll('tr').length > 8) continue;
          let clonedResult = false;
          for (let ancestor = table; ancestor; ancestor = ancestor.parentElement) {
            if (/^D_.*_[HB]$/.test(ancestor.id)) { clonedResult = true; break; }
          }
          if (!clonedResult) table.setAttribute('data-y3client-search-table', '');
        }
      }
      if (exportDocument) {
        root.setAttribute('data-y3client-export', '');
        for (const anchor of document.querySelectorAll('a[href]')) {
          const url = new URL(anchor.href, location.href);
          if (url.origin !== origin || !/^\/scripts\/verona\/download\/[^/]+\.(csv|xls)$/i.test(url.pathname)) continue;
          anchor.setAttribute('download', '');
          if (/右クリック/.test(anchor.textContent)) {
            anchor.textContent = /\.csv$/i.test(url.pathname) ? 'CSVを保存' : 'Excelを保存';
          }
        }
      }
      // Only the observed fixed-height search frame is enlarged. Report grids keep their ratios.
      for (const frameset of document.querySelectorAll('frameset[rows]')) {
        const rows = frameset.getAttribute('rows').split(',');
        const first = Array.from(frameset.children).find(node => node.tagName === 'FRAME');
        if (rows[0].trim() === '115' && first && /(?:_1_1|condition|search)$/i.test(first.name)) {
          rows[0] = '180';
          frameset.setAttribute('rows', rows.join(','));
        }
      }
    })();
    """#

    // Reflows existing controls and result nodes; the site keeps its own forms and handlers.
    static let mobileRedesign = #"""
    (() => {
      const origin='https://adidas-y3.poscmcloud.jp:15505';
      if(location.origin!==origin || !document.body || document.body.tagName!=='BODY')return;
      document.documentElement.setAttribute('data-y3client-layout','');
      if(document.getElementById('y3client-layout-base'))return;
      const style=document.createElement('style'); style.id='y3client-layout-base';
      style.textContent=`
        html[data-y3client-layout] { background:#f4f5f6; color:#17191d; font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif; -webkit-text-size-adjust:100%; }
        html[data-y3client-layout] body { margin:0!important; padding:18px 16px 28px!important; box-sizing:border-box; max-width:100%; background:transparent!important; font-family:inherit!important; font-size:14px; line-height:1.5; }
        html[data-y3client-layout] font { font-family:inherit!important; }
        html[data-y3client-layout] input,html[data-y3client-layout] select,html[data-y3client-layout] button,html[data-y3client-layout] textarea { font-family:inherit!important; }
        html[data-y3client-layout] h1,html[data-y3client-layout] h2 { font-family:inherit; letter-spacing:-.5px; }
        html[data-y3client-layout] a[href*='metz010_1.asp'] { display:inline-flex; align-items:center; min-height:44px; margin:0 0 6px; font:500 12px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; color:#717780; text-decoration:none; }
        html[data-y3client-layout] center { max-width:100%; }
      `;
      document.head?.appendChild(style);
    })();

    (() => {
      'use strict';
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      if (location.origin !== origin || !document.documentElement || !document.body) return;
      const root = document.documentElement;
      const normalize = value => String(value || '').normalize('NFKC').toLocaleLowerCase('ja').replace(/\s+/g, ' ').trim();
      const text = node => (node.textContent || '').replace(/\s+/g, ' ').trim();
      const menuPage = /^\/scripts\/verona\/menu\/[^/]+\.asp$/i.test(location.pathname);
      const searchPage = /^\/scripts\/verona\/(?:dwh|print|display)\/[^/]+\.asp$/i.test(location.pathname);
      const frozen = node => {
        for (let parent = node; parent; parent = parent.parentElement) {
          if (/^D_.*_[HB]$/.test(parent.id || '')) return true;
        }
        return false;
      };
      if (!document.getElementById('y3client-menu-form-style')) {
        const style = document.createElement('style');
        style.id = 'y3client-menu-form-style';
        style.textContent = `
          html[data-y3client-menu-dashboard] table { width:100%!important; max-width:100%; box-sizing:border-box; }
          [data-y3client-menu-table] { display:block!important; width:100%!important; max-width:100%; height:auto!important; border:0!important; border-spacing:0; }
          [data-y3client-menu-table] > tbody { display:block!important; width:100%; }
          [data-y3client-menu-section] { display:block!important; width:auto!important; margin:0 0 14px; padding:16px; border:1px solid #e4e7e9!important; border-radius:16px; background:#fff!important; box-sizing:border-box; }
          [data-y3client-menu-section] > td { display:block!important; width:auto!important; max-width:100%; border:0!important; padding:0!important; background:transparent!important; white-space:normal!important; box-sizing:border-box; }
          [data-y3client-menu-category] { font-size:13px!important; font-weight:700!important; letter-spacing:.035em; color:#687078; margin-bottom:12px; }
          [data-y3client-menu-description] { margin:10px 0 0; color:#737b82!important; font:400 12px/1.5 -apple-system,BlinkMacSystemFont,sans-serif!important; text-align:left!important; }
          [data-y3client-menu-description] * { font:inherit!important; color:inherit!important; }
          [data-y3client-menu-single] > td[data-y3client-menu-actions] { display:block!important; }
          [data-y3client-menu-business] { position:relative; }
          [data-y3client-menu-business] a[data-y3client-menu-item] { min-height:44px; padding:0!important; background:transparent; border:0; font-size:16px!important; }
          [data-y3client-menu-business] a[data-y3client-menu-item]::before { content:''; position:absolute; inset:0; border-radius:16px; }
          [data-y3client-menu-account] { float:none!important; clear:both; margin:8px 0 12px; background:transparent!important; }
          [data-y3client-menu-account] tbody,[data-y3client-menu-account] tr { background:transparent!important; }
          [data-y3client-menu-account] tr { display:flex; flex-wrap:wrap; align-items:center; gap:6px 16px; }
          [data-y3client-menu-account] td,[data-y3client-menu-account] th { height:auto!important; border:0!important; background:transparent!important; padding:0!important; color:#737b82; font:400 11px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-menu-account] font { color:inherit!important; font:inherit!important; }
          [data-y3client-menu-actions] > font { display:contents!important; }
          [data-y3client-menu-section] > td[data-y3client-menu-actions], [data-y3client-menu-actions] { display:grid!important; grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }
          [data-y3client-menu-actions] > br, [data-y3client-menu-title], [data-y3client-menu-hidden] { display:none!important; }
          a[data-y3client-menu-item] { display:flex!important; align-items:center; justify-content:space-between; gap:10px; width:100%; min-height:70px; padding:14px!important; border:1px solid #e3e6e8; border-radius:12px; background:#f8f9fa; color:#111!important; text-decoration:none!important; font:600 15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif!important; white-space:normal!important; text-wrap:balance; overflow-wrap:anywhere; box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
          a[data-y3client-menu-item] * { color:inherit!important; font:inherit!important; }
          a[data-y3client-menu-item]:only-of-type { grid-column:1/-1; }
          a[data-y3client-menu-item]::after { content:'›'; font-size:24px; font-weight:400; line-height:1; color:#8c9399; flex-shrink:0; }
          a[data-y3client-menu-item]:active { background:#111; color:#fff!important; }
          a[data-y3client-menu-item]:focus-visible { outline:3px solid #111; outline-offset:3px; }
          [data-y3client-menu-tabs] { display:flex!important; flex-wrap:wrap; align-items:center; gap:8px; width:auto!important; padding:0 0 14px!important; border:0!important; background:transparent!important; }
          [data-y3client-menu-tabs-row] { display:flex!important; flex-wrap:wrap; gap:8px; height:auto!important; width:100%!important; }
          [data-y3client-menu-tabs-row] > td { display:contents!important; width:auto!important; border:0!important; background:transparent!important; }
          [data-y3client-menu-tabs-row] > td:not(:has(a[data-y3client-menu-category-link])) { display:none!important; }
          [data-y3client-menu-header], [data-y3client-menu-header] > td { display:block!important; height:auto!important; max-width:100%; width:auto!important; background:transparent!important; border:0!important; padding:0!important; box-sizing:border-box; }
          [data-y3client-menu-header] { width:100%!important; }
          [data-y3client-menu-heading], [data-y3client-menu-heading] > td { display:block!important; width:auto!important; border:0!important; background:transparent!important; padding:0!important; }
          [data-y3client-menu-heading] { margin:22px 4px 12px; color:#737b82; font-size:12px; }
          [data-y3client-menu-heading] * { color:inherit!important; font:inherit!important; }
          a[data-y3client-menu-category-link] { display:inline-flex!important; align-items:center; justify-content:center; min-height:44px; margin:0; padding:9px 13px!important; border:1px solid #d9dfe3; border-radius:100px; background:#fff; color:#111!important; text-decoration:none!important; font:600 13px/1.3 -apple-system,BlinkMacSystemFont,sans-serif!important; white-space:normal!important; box-sizing:border-box; }
          a[data-y3client-menu-category-link] * { font:inherit!important; color:inherit!important; }
          a[data-y3client-menu-category-link]:active { background:#111; color:#fff!important; }
          [data-y3client-menu-utility] { display:inline-flex!important; align-items:center; min-height:44px; padding:8px 0!important; font-size:13px!important; color:#59616a!important; }
          [data-y3client-menu-tools] { margin:4px 0 20px; }
          [data-y3client-menu-tools] h1 { margin:0 0 6px; font:700 25px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; letter-spacing:-.03em; color:#111; }
          [data-y3client-menu-tools] p { margin:0 0 16px; font-size:13px; line-height:1.5; color:#737b82; }
          [data-y3client-menu-search] { display:block; width:100%!important; min-height:50px!important; padding:13px 15px!important; border:1px solid #dce1e5!important; border-radius:12px; background:#fff!important; color:#111; font-size:16px!important; box-sizing:border-box; -webkit-appearance:none; }
          [data-y3client-menu-search]:focus { outline:2px solid #111; outline-offset:1px; }
          [data-y3client-menu-empty] { margin:24px 0; padding:24px 18px; border-radius:14px; background:#fff; text-align:center; font-size:14px; color:#737b82; }
          [data-y3client-menu-empty][hidden] { display:none!important; }
          [data-y3client-form-shell] { display:block!important; width:100%!important; max-width:100%; border:0!important; background:transparent!important; box-sizing:border-box; }
          [data-y3client-form-shell] > tbody, [data-y3client-form-shell] > tbody > tr, [data-y3client-form-shell] > tbody > tr > td { display:block!important; width:auto!important; max-width:100%; border:0!important; background:transparent!important; white-space:normal!important; box-sizing:border-box; }
          [data-y3client-form-table] { display:block!important; width:100%!important; max-width:100%; margin:12px 0 18px!important; padding:18px!important; border:1px solid #e1e5e8!important; border-radius:16px; background:#fff!important; box-sizing:border-box; }
          [data-y3client-form-table] > tbody { display:block!important; }
          [data-y3client-form-row] { display:grid!important; grid-template-columns:minmax(0,1fr); gap:7px; width:100%!important; margin:0 0 18px; box-sizing:border-box; }
          [data-y3client-form-row] > td, [data-y3client-action-row] > td { display:block!important; width:auto!important; max-width:100%; border:0!important; padding:0!important; background:transparent!important; white-space:normal!important; box-sizing:border-box; }
          [data-y3client-label-cell] { color:#515b64; text-align:left!important; font:600 12px/1.5 -apple-system,BlinkMacSystemFont,sans-serif!important; }
          [data-y3client-label-cell] * { font:inherit!important; color:inherit!important; }
          [data-y3client-form-row] > td[data-y3client-field-cell], [data-y3client-field-cell] { display:flex!important; flex-wrap:wrap; align-items:center; gap:8px; color:#64707b; }
          [data-y3client-field]:not([type='checkbox' i]):not([type='radio' i]) { display:block; width:100%!important; max-width:100%; min-width:0!important; min-height:48px!important; margin:0; padding:11px 12px!important; border:1px solid #dce1e5!important; border-radius:10px; background:#fff!important; color:#111; font:400 16px/1.4 -apple-system,BlinkMacSystemFont,sans-serif!important; box-sizing:border-box; }
          [data-y3client-field]:focus { outline:2px solid #111; outline-offset:1px; }
          [data-y3client-form-row] > td[data-y3client-date-pair], [data-y3client-date-pair] { display:grid!important; grid-template-columns:minmax(0,1fr) auto minmax(0,1fr); align-items:center; gap:6px; }
          [data-y3client-date-pair] > [data-y3client-field] { padding-inline:8px!important; text-align:center; font-variant-numeric:tabular-nums; }
          input[data-y3client-field][type='checkbox' i], input[data-y3client-field][type='radio' i] { width:21px!important; height:21px!important; min-width:21px!important; min-height:21px!important; margin:0 0 0 2px; padding:0!important; accent-color:#111; flex-shrink:0; }
          [data-y3client-choice-label] { display:inline-flex!important; align-items:center; min-height:44px; margin:0 8px 0 -4px; padding:8px 6px; font:400 14px/1.4 -apple-system,BlinkMacSystemFont,sans-serif; color:#111; box-sizing:border-box; }
          [data-y3client-action-row] { display:block!important; margin:8px 0 0; }
          [data-y3client-action-row] > td { display:flex!important; flex-wrap:wrap; gap:10px; }
          [data-y3client-primary], [data-y3client-secondary] { min-height:48px!important; padding:11px 16px!important; border:1px solid #dce1e5!important; border-radius:10px; font:600 15px/1.4 -apple-system,BlinkMacSystemFont,sans-serif!important; white-space:normal!important; box-sizing:border-box; -webkit-appearance:none; }
          [data-y3client-primary] { flex:1 1 160px; background:#111!important; color:#fff!important; border-color:#111!important; }
          [data-y3client-secondary] { background:#f4f6f7!important; color:#3f4851!important; }
          [data-y3client-primary]:active { background:#343434!important; }
          [data-y3client-primary]:focus-visible, [data-y3client-secondary]:focus-visible { outline:3px solid #111; outline-offset:3px; }
          [data-y3client-login] [data-y3client-form-table] { max-width:440px; margin:24px auto!important; padding:24px!important; }
          @media (max-width:350px) { [data-y3client-menu-section] > td[data-y3client-menu-actions], [data-y3client-menu-actions] { grid-template-columns:minmax(0,1fr); } [data-y3client-form-table] { padding:14px!important; } }
        `;
        document.head?.appendChild(style);
      }

      if (menuPage && !document.querySelector('[data-y3client-menu-tools]')) {
        root.setAttribute('data-y3client-menu-dashboard', '');
        const sections = [];
        const items = [];
        const allAnchors = Array.from(document.body.querySelectorAll('a')).filter(anchor => text(anchor));
        const categoryLinks = allAnchors.filter(anchor => /^TitleNAME\d+$/i.test(anchor.name || '') && /^(データ閲覧|在庫管理|エクスポート)$/.test(text(anchor)));
        for (const anchor of categoryLinks) {
          anchor.setAttribute('data-y3client-menu-category-link', '');
          (anchor.closest('td,th') || anchor.parentElement)?.setAttribute('data-y3client-menu-tabs', '');
          anchor.closest('tr')?.setAttribute('data-y3client-menu-tabs-row', '');
          const tabsTable = anchor.closest('table');
          tabsTable?.setAttribute('data-y3client-menu-table', '');
          if (tabsTable) tabsTable.style.cssText += ';float:none!important;position:static!important;';
          tabsTable?.parentElement.closest('tr')?.setAttribute('data-y3client-menu-header', '');
        }
        for (const anchor of allAnchors) {
          if (categoryLinks.includes(anchor)) continue;
          const label = text(anchor);
          if (/^(ログアウト|終了|戻る|メニュー選択画面|logout|poscm\s*[-－]\s*logout)$/i.test(label)) {
            anchor.setAttribute('data-y3client-menu-utility', '');
            if (/logout/i.test(label)) anchor.closest('table')?.setAttribute('data-y3client-menu-account', '');
            continue;
          }
          const href = anchor.getAttribute('href') || '';
          if (!href && !anchor.hasAttribute('onclick')) continue;
          // Presentation changes keep the existing anchor, target and inline event handler.
          anchor.setAttribute('data-y3client-menu-item', '');
          const row = anchor.closest('tr');
          const cell = anchor.closest('td,th');
          let category = '';
          if (row && cell && cell.closest('tr') === row) {
            const cells = Array.from(row.cells);
            const labelCell = cells.find(candidate => candidate !== cell && !candidate.querySelector('a,input,select,textarea,button,table') && text(candidate));
            if (labelCell) {
              category = text(labelCell);
              labelCell.setAttribute(cells.indexOf(labelCell) > cells.indexOf(cell) ? 'data-y3client-menu-description' : 'data-y3client-menu-category', '');
            }
            cell.setAttribute('data-y3client-menu-actions', '');
            row.setAttribute('data-y3client-menu-section', '');
            const table = row.closest('table');
            table?.setAttribute('data-y3client-menu-table', '');
            let section = sections.find(record => record.row === row);
            if (!section) { section = { row, anchors: [] }; sections.push(section); }
            section.anchors.push(anchor);
          }
          items.push({ anchor, search: normalize(label + ' ' + category) });
        }
        if (items.length) {
          for (const section of sections) if (section.anchors.length === 1) {
            section.row.setAttribute('data-y3client-menu-single', '');
            if (section.row.querySelector('[data-y3client-menu-description]') && !section.row.querySelector('input,select,button,textarea')) section.row.setAttribute('data-y3client-menu-business', '');
          }
          const logo = Array.from(document.body.children).find(node => node.tagName === 'TABLE' && node.querySelector('img') && !node.querySelector('a,input,select,textarea,button'));
          logo?.setAttribute('data-y3client-menu-title', '');
          for (const row of document.querySelectorAll('tr')) {
            if (!row.querySelector('a,input,select,textarea,button') && /メニュー選択画面/.test(text(row))) row.setAttribute('data-y3client-menu-title', '');
            else if (!row.querySelector('a,input,select,textarea,button,table') && /^\s*[<＜].+[>＞]\s*$/.test(text(row))) row.setAttribute('data-y3client-menu-heading', '');
          }
          const tools = document.createElement('div');
          tools.setAttribute('data-y3client-menu-tools', '');
          const heading = document.createElement('h1');
          heading.textContent = '業務メニュー';
          const description = document.createElement('p');
          description.textContent = '使いたい機能を選択してください';
          const search = document.createElement('input');
          search.type = 'search';
          search.placeholder = 'メニューを検索';
          search.setAttribute('aria-label', 'メニューを検索');
          search.setAttribute('data-y3client-menu-search', '');
          search.autocomplete = 'off';
          const empty = document.createElement('p');
          empty.setAttribute('data-y3client-menu-empty', '');
          empty.setAttribute('role', 'status');
          empty.setAttribute('aria-live', 'polite');
          empty.textContent = '該当するメニューがありません';
          empty.hidden = true;
          tools.append(heading, description, search);
          document.body.insertBefore(tools, document.body.firstChild);
          document.body.appendChild(empty);
          search.addEventListener('keydown', event => { if (event.key === 'Enter') event.preventDefault(); });
          search.addEventListener('input', () => {
            const terms = normalize(search.value).split(' ').filter(Boolean);
            let matches = 0;
            for (const item of items) {
              const shown = terms.every(term => item.search.includes(term));
              item.anchor.toggleAttribute('data-y3client-menu-hidden', !shown);
              if (shown) matches++;
            }
            for (const section of sections) section.row.toggleAttribute('data-y3client-menu-hidden', section.anchors.every(anchor => anchor.hasAttribute('data-y3client-menu-hidden')));
            empty.hidden = matches > 0;
          });
        }
      }

      let generatedID = 0;
      const uniqueID = prefix => {
        let candidate;
        do { candidate = prefix + (++generatedID); } while (document.getElementById(candidate));
        return candidate;
      };
      for (const form of Array.from(document.forms)) {
        const controls = Array.from(form.elements).filter(control => /^(INPUT|SELECT|TEXTAREA)$/.test(control.tagName) && control.type !== 'hidden' && !frozen(control));
        const passwordForm = controls.some(control => control.type === 'password');
        const entryControls = controls.filter(control => control.tagName === 'TEXTAREA' || (control.tagName === 'INPUT' && /^(text|search|date|password|email|number|tel)$/.test(control.type)));
        if (!passwordForm && (!searchPage || !entryControls.length)) continue;
        if (passwordForm) root.setAttribute('data-y3client-login', '');
        form.setAttribute('data-y3client-mobile-form', passwordForm ? 'login' : 'search');
        const tables = new Set();
        for (const control of controls) {
          const table = control.closest('table');
          if (!table || frozen(table)) continue;
          const ownRows = Array.from(table.rows).filter(row => row.closest('table') === table);
          if (ownRows.length > 18) continue;
          tables.add(table);
          const button = control.tagName === 'INPUT' && /^(submit|reset|button)$/.test(control.type);
          if (button) {
            const primary = control.type === 'submit' || (control.type === 'button' && /^(検索|検索開始|検索実行|ログイン|表示|実行)$/.test(control.value.trim()));
            control.setAttribute(primary ? 'data-y3client-primary' : 'data-y3client-secondary', '');
            const row = control.closest('tr');
            if (row && !row.querySelector('input:not([type="hidden" i]):not([type="submit" i]):not([type="reset" i]):not([type="button" i]),select,textarea')) row.setAttribute('data-y3client-action-row', '');
            continue;
          }
          control.setAttribute('data-y3client-field', '');
          if (/YYYYMMDD/i.test(control.name || '') && !control.inputMode) control.inputMode = 'numeric';
          const cell = control.closest('td,th');
          const row = control.closest('tr');
          if (cell && row && cell.closest('tr') === row) {
            row.setAttribute('data-y3client-form-row', '');
            cell.setAttribute('data-y3client-field-cell', '');
            const labelCell = Array.from(row.cells).find(candidate => candidate !== cell && !candidate.querySelector('input,select,textarea,button,table') && text(candidate));
            const dates = Array.from(cell.children).filter(node => node.tagName === 'INPUT' && /YYYYMMDD/i.test(node.name || ''));
            const datePair = dates.length === 2 && cell.children.length === 2;
            if (labelCell) {
              labelCell.setAttribute('data-y3client-label-cell', '');
              if (!control.hasAttribute('aria-label') && !control.hasAttribute('aria-labelledby') && !(control.labels && control.labels.length)) {
                if (datePair && dates.includes(control)) {
                  control.setAttribute('aria-label', text(labelCell) + (dates.indexOf(control) === 0 ? ' 開始日' : ' 終了日'));
                } else {
                  if (!labelCell.id) labelCell.id = uniqueID('y3client-field-label-');
                  control.setAttribute('aria-labelledby', labelCell.id);
                }
              }
            }
            if (datePair) cell.setAttribute('data-y3client-date-pair', '');
          }
          if (/^(checkbox|radio)$/.test(control.type)) {
            for (const label of Array.from(control.labels || [])) label.setAttribute('data-y3client-choice-label', '');
            // Some old pages have plain text after the control; create only its label, not a replacement control.
            if (!(control.labels && control.labels.length)) {
              const following = control.nextSibling;
              if (following && following.nodeType === Node.TEXT_NODE && following.textContent.trim() && following.textContent.trim().length <= 60) {
                if (!control.id) control.id = uniqueID('y3client-choice-');
                const label = document.createElement('label');
                label.htmlFor = control.id;
                label.textContent = following.textContent;
                label.setAttribute('data-y3client-choice-label', '');
                following.replaceWith(label);
              }
            }
          }
        }
        for (const table of tables) {
          table.setAttribute('data-y3client-form-table', '');
          for (let ancestor = table.parentElement; ancestor && ancestor !== document.body; ancestor = ancestor.parentElement) {
            if (ancestor.tagName === 'TABLE' && !tables.has(ancestor) && !frozen(ancestor)) ancestor.setAttribute('data-y3client-form-shell', '');
          }
        }
      }
    })();

    (function adaptResults() {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      if (location.origin !== origin || !document.body || document.body.tagName !== 'BODY') return;
      const root = document.documentElement;
      const reportPage = /\/scripts\/verona\/(?:print|display|dwh)\/(?:prtz|dstz|help_)/i.test(location.pathname);
      if (!reportPage) return;
      // Legacy Tscroller builds the paired header/body tables in its load handler.
      if (document.readyState !== 'complete') { window.addEventListener('load', adaptResults, { once:true }); return; }
      root.setAttribute('data-y3client-redesign', '');
      if (!document.getElementById('y3client-results-style')) {
        const style = document.createElement('style'); style.id = 'y3client-results-style';
        style.textContent = `
          html[data-y3client-redesign] { background:#f4f5f6; color:#17191d; font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif; }
          html[data-y3client-redesign] body { margin:0!important; padding:18px 16px 28px!important; box-sizing:border-box; max-width:100%; background:transparent!important; font-family:inherit!important; font-size:14px; line-height:1.5; }
          html[data-y3client-redesign] font { font-family:inherit!important; font-size:inherit!important; color:inherit!important; }
          html[data-y3client-redesign] h1,html[data-y3client-redesign] h2 { font-size:21px; letter-spacing:-.5px; margin:10px 0 18px; }
          html[data-y3client-redesign] a { color:#17191d; text-underline-offset:3px; }
          [data-y3client-result-tools] { display:flex; align-items:center; justify-content:space-between; gap:12px; margin:12px 0; }
          [data-y3client-result-count] { font-size:13px; color:#646972; }
          [data-y3client-table-toggle] { border:1px solid #dadddf; background:#fff; border-radius:10px; font-size:13px!important; min-height:44px; padding:9px 14px; color:#17191d; font-weight:600; }
          [data-y3client-table-scroll] { width:100%!important; max-width:100%!important; box-sizing:border-box; overflow-x:auto!important; -webkit-overflow-scrolling:touch; border-radius:12px; background:#fff; }
          [data-y3client-table-scroll] > table:not([data-y3client-result-list='cards']) { border-collapse:collapse; font-size:13px; }
          [data-y3client-table-scroll] > table:not([data-y3client-result-list='cards']) td,
          [data-y3client-table-scroll] > table:not([data-y3client-result-list='cards']) th { padding:10px 12px; border:1px solid #e3e5e8; }
          [data-y3client-table-scroll] > table:not([data-y3client-result-list='cards']) th { background:#f0f1f3; font-weight:600; }
          table[data-y3client-natural-columns] { width:max-content!important; min-width:100%; table-layout:auto!important; }
          [data-y3client-page-selector] { min-width:64px!important; min-height:44px!important; padding:8px 10px!important; border:1px solid #dce1e5; border-radius:8px; background:#fff; font-size:16px!important; }
          [data-y3client-frozen-body],[data-y3client-frozen-header] { position:relative!important; left:0!important; top:0!important; height:auto!important; max-height:none!important; margin:0!important; }
          [data-y3client-frozen-header][data-y3client-hidden-header] { display:none!important; }
          table[data-y3client-result-list='cards'] { display:block!important; border:0!important; width:100%!important; min-width:0!important; max-width:100%!important; background:transparent!important; border-spacing:0; }
          table[data-y3client-result-list='cards'] > tbody { display:block!important; width:100%!important; }
          table[data-y3client-result-list='cards'] > thead { display:none!important; }
          table[data-y3client-result-list='cards'] [data-y3client-result-heading] { display:none!important; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] { display:grid!important; grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px 14px; margin:0 0 12px; padding:16px; width:100%!important; box-sizing:border-box; background:#fff!important; border:1px solid #e3e5e8!important; border-radius:14px; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] > td { display:flex!important; flex-direction:column; gap:3px; border:0!important; padding:0!important; width:auto!important; min-width:0!important; max-width:100%!important; text-align:left!important; vertical-align:top; white-space:normal!important; overflow-wrap:anywhere; background:transparent!important; font-size:15px!important; line-height:1.4; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] > td:before { content:attr(data-y3client-label); font-size:11px; color:#777d85; font-weight:500; line-height:1.4; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] > td[data-y3client-result-primary] { grid-column:1/-1; font-size:17px!important; font-weight:650; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] > td[data-y3client-number] { font-variant-numeric:tabular-nums; font-size:21px!important; font-weight:650; }
          table[data-y3client-result-list='cards'] tr[data-y3client-result-card] > td a { display:block; min-height:44px; text-decoration:none; font-weight:650; }
          html[data-y3client-redesign] [data-y3client-result-hint] { margin:8px 0 12px; color:#777d85; font-size:12px; }
          @media print { [data-y3client-result-tools],[data-y3client-result-hint]{display:none!important;} [data-y3client-table-scroll]{overflow:visible!important;} }
        `;
        document.head.appendChild(style);
      }
      const visibleControls = element => Array.from(element.querySelectorAll('input,select,textarea,button')).some(control => control.type !== 'hidden');
      for (const select of document.querySelectorAll('select[name="PgSelect" i],select[name*="page" i],select[name*="pageno" i]')) {
        select.setAttribute('data-y3client-page-selector','');
        if (!select.hasAttribute('aria-label') && !select.hasAttribute('aria-labelledby') && !select.labels?.length) select.setAttribute('aria-label','ページ');
      }
      const headerText = cell => {
        const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
        let text='', node;
        while ((node=walker.nextNode())) {
          if (!node.parentElement.closest('select,input,script,style')) text+=' '+node.textContent;
        }
        return text.replace(/\s+/g,' ').trim().slice(0,60);
      };
      const isData = table => table.rows.length >= 2 && !table.closest('[data-y3client-search-table],[data-y3client-menu-table]') && !visibleControls(table) && !table.querySelector('table');
      for (const table of Array.from(document.querySelectorAll('table'))) {
        if (!isData(table) || table.hasAttribute('data-y3client-result-list') || table.closest('[data-y3client-table-scroll]')) continue;
        const container=table.parentElement;
        const frozen=container && /^D_.*_B$/i.test(container.id);
        const headerContainer=frozen ? document.getElementById(container.id.replace(/_B$/i,'_H')) : null;
        const headerTable=headerContainer && headerContainer.querySelector('table');
        const rows=Array.from(table.rows);
        const ownHeader=rows[0];
        const headerRow=headerTable ? headerTable.rows[0] : ownHeader;
        const dataRows=headerTable ? rows : rows.slice(1);
        const labels=headerRow ? Array.from(headerRow.cells).map(headerText) : [];
        const simpleHeader=headerRow && labels.length>=2 && labels.length<=24 && Array.from(headerRow.cells).every(cell => cell.colSpan===1 && cell.rowSpan===1) && (headerTable ? headerTable.rows.length===1 : true);
        const recognizableHeader=headerTable || Array.from(headerRow?.cells || []).every(cell=>cell.tagName==='TH') || labels.some(label=>/品番|商品|店舗|日付|売上|金額|数量|在庫|サイズ|カラー|区分/.test(label));
        const simpleBody=dataRows.length>0 && dataRows.length<=500 && dataRows.every(row=>row.cells.length===labels.length && Array.from(row.cells).every(cell=>cell.colSpan===1 && cell.rowSpan===1));
        let scroll=container;
        if (frozen) {
          container.setAttribute('data-y3client-frozen-body','');
          if (headerContainer) {
            headerContainer.setAttribute('data-y3client-frozen-header','');
            headerContainer.setAttribute('data-y3client-table-scroll','');
            container.addEventListener('scroll',()=>{headerContainer.scrollLeft=container.scrollLeft;},{passive:true});
          }
        } else {
          scroll=document.createElement('div');
          container.insertBefore(scroll,table); scroll.appendChild(table);
        }
        scroll.setAttribute('data-y3client-table-scroll','');
        scroll.setAttribute('tabindex','0');
        scroll.setAttribute('role','region');
        scroll.setAttribute('aria-label','検索結果の表');
        if (!(simpleHeader && simpleBody && recognizableHeader)) {
          if (!frozen) table.setAttribute('data-y3client-natural-columns','');
          const hint=document.createElement('p'); hint.setAttribute('data-y3client-result-hint','');
          hint.textContent='表は左右にスクロールできます'; scroll.parentElement.insertBefore(hint,scroll);
          continue;
        }
        if (!headerTable) ownHeader.setAttribute('data-y3client-result-heading','');
        for (const row of dataRows) {
          row.setAttribute('data-y3client-result-card','');
          for (let index=0;index<row.cells.length;index++) {
            const cell=row.cells[index]; const label=labels[index] || '項目'+(index+1);
            cell.setAttribute('data-y3client-label',label);
            if (/商品名|品番|店舗名|日付/.test(label)) cell.setAttribute('data-y3client-result-primary','');
            if (/在庫数|販売数|売上数|数量|金額/.test(label)) cell.setAttribute('data-y3client-number','');
          }
        }
        const tools=document.createElement('div'); tools.setAttribute('data-y3client-result-tools','');
        const count=document.createElement('span'); count.setAttribute('data-y3client-result-count','');
        count.textContent=dataRows.length+'件を表示'; tools.appendChild(count);
        const toggle=document.createElement('button'); toggle.type='button'; toggle.setAttribute('data-y3client-table-toggle','');
        tools.appendChild(toggle);
        const insertionTarget=headerContainer || scroll;
        insertionTarget.parentElement.insertBefore(tools,insertionTarget);
        let cards=true;
        const show=()=>{
          table.setAttribute('data-y3client-result-list',cards?'cards':'table');
          toggle.textContent=cards?'表で表示':'一覧で表示'; toggle.setAttribute('aria-pressed',cards?'false':'true');
          if (headerContainer) headerContainer.toggleAttribute('data-y3client-hidden-header',cards);
          scroll.style.background=cards?'transparent':'';
        };
        toggle.addEventListener('click',()=>{cards=!cards;show();}); show();
      }
    })();

    (() => {
      const origin='https://adidas-y3.poscmcloud.jp:15505';
      if (location.origin!==origin || !document.body || document.body.tagName!=='BODY') return;
      let host;
      try { host=window.top; if(host.location.origin!==origin)return; } catch(_){return;}
      const state=host.__y3ClientNavigation || (host.__y3ClientNavigation={submissionRevision:0,resultSubmissionRevision:0});
      const path=location.pathname;
      const readOnlyPage=/\/scripts\/verona\/(?:print|display|dwh)\/(?:prtz|dstz)/i.test(path);
      const searchForms=readOnlyPage?Array.from(document.forms).filter(form=>!form.querySelector('input[type=password]') && Array.from(form.elements).some(input=>input.tagName==='INPUT' && ['text','search','date'].includes(input.type))):[];
      for(const form of searchForms)form.setAttribute('data-y3-form','');
      const mark=form=>{
        if(!form?.hasAttribute('data-y3-form'))return;
        const now=Date.now();
        if(now-(state.lastSubmissionAt || 0)<200)return;
        state.lastSubmissionAt=now;
        state.submissionRevision=Math.min((state.submissionRevision || 0)+1,1000000000);
      };
      if(!window.__y3ClientSubmissionObserver){
        window.__y3ClientSubmissionObserver=true;
        document.addEventListener('submit',event=>mark(event.target),true);
        const original=HTMLFormElement.prototype.submit;
        HTMLFormElement.prototype.submit=function(...args){mark(this);return original.apply(this,args);};
      }
      if(window!==host && readOnlyPage && !searchForms.length && (document.querySelector('table') || /\/prtz\d+_(?:[2-9]|[2-9]_[2-9])\.asp$/i.test(path))) {
        const ready=()=>{state.resultSubmissionRevision=state.submissionRevision || 0;};
        if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
      }
    })();
    """#

    // Reports only integer frame paths and a structural role, never contents, URLs, or form data.
    static let discoverFrames = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window) || !document.querySelector('frameset')) return [];
      const panes = [];
      const walk = (win, path, condition) => {
        if (!trusted(win) || path.length > 8 || panes.length >= 12) return;
        let frames = [];
        try {
          frames = Array.from(win.document.querySelectorAll('frame')).filter(frame => frame.contentWindow);
        } catch (_) { return; }
        if (frames.length) {
          for (const element of frames) {
            let index = -1;
            for (let i = 0; i < Math.min(win.frames.length, 64); i++) {
              if (win.frames[i] === element.contentWindow) { index = i; break; }
            }
            if (index < 0) continue;
            // The export service has another port. Recognize its parent-owned FRAME without inspecting it.
            if (/\/dstz210_2\.asp$/i.test(win.location.pathname) && element.name === 'dstz210_2_2') {
              panes.push({ path: path.concat(index), kind: 'export' });
              if (panes.length >= 12) return;
              continue;
            }
            walk(element.contentWindow, path.concat(index), condition || /(?:_1_1|condition|search)$/i.test(element.name));
          }
          return;
        }
        if (!path.length) return;
        try {
          if (/dummy|blank|empty/i.test(win.name)) return;
          const body = win.document.body;
          if (!body || (!body.textContent.trim() && !body.querySelector('form,table,a,input,select,textarea,img'))) return;
          const tableRows = body.querySelectorAll('table tr').length;
          const tableCells = body.querySelectorAll('table td,table th').length;
          const controls = body.querySelector('input:not([type="hidden" i]),select,textarea,button');
          const searchFields = body.querySelector('input[name*="YYYYMMDD" i]:not([type="hidden" i]),input[type="text" i],input[type="date" i],input[type="search" i],textarea');
          const reportLeaf = /\/prtz\d+_(?:[2-9]|[2-9]_[2-9])\.asp$/i.test(win.location.pathname);
          const kind = (searchFields || (condition && controls && body.querySelector('form'))) ? 'condition' :
            (reportLeaf || tableRows >= 5 || tableCells >= 20) ? 'result' : controls ? 'controls' : 'navigation';
          const titles = { 'prtz011_3.asp':'在庫一覧', 'prtz030_2_2.asp':'集計結果', 'prtz030_2_3.asp':'内訳1', 'prtz030_2_4.asp':'内訳2' };
          const title = titles[win.location.pathname.split('/').pop().toLowerCase()];
          panes.push(title ? { path, kind, title } : { path, kind });
        } catch (_) {}
      };
      walk(window, [], false);
      return panes;
    })();
    """#

    // The only argument is a validated integer path or null. Existing frame nodes are retained.
    static let frameFocus = #"""
    (path) => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window) || !document.querySelector('frameset')) return false;
      if (path !== null && (!Array.isArray(path) || !path.length || path.length > 8 ||
          path.some(index => !Number.isInteger(index) || index < 0 || index >= 64))) return false;
      const changes = [];
      let focusedWindow = null;
      if (path !== null) {
        let win = window;
        for (let position = 0; position < path.length; position++) {
          const index = path[position];
          if (index >= win.frames.length) return false;
          const child = win.frames[index];
          // Resolve the FRAME in the trusted parent rather than reading a cross-origin frameElement.
          let branch = Array.from(win.document.querySelectorAll('frame')).find(element => element.contentWindow === child);
          if (!branch || branch.tagName !== 'FRAME' || branch.ownerDocument !== win.document) return false;
          const opaqueExport = position === path.length - 1 && /\/dstz210_2\.asp$/i.test(win.location.pathname) &&
            branch.name === 'dstz210_2_2';
          if (!trusted(child) && !opaqueExport) return false;
          for (let parent = branch.parentElement; parent && parent.tagName === 'FRAMESET'; parent = branch.parentElement) {
            const children = Array.from(parent.children).filter(node => /^(FRAME|FRAMESET)$/.test(node.tagName));
            const selected = children.indexOf(branch);
            if (selected < 0) return false;
            changes.push({ element: parent, count: children.length, selected });
            branch = parent;
          }
          win = child;
        }
        if (trusted(win)) focusedWindow = win;
      }
      const state = window.__y3ClientFrameLayout || { originals: [] };
      for (const saved of state.originals) {
        if (!saved.element.isConnected) continue;
        for (const name of ['rows', 'cols']) {
          if (saved[name] === null) saved.element.removeAttribute(name);
          else saved.element.setAttribute(name, saved[name]);
        }
      }
      state.originals = [];
      const seen = new Set();
      for (const change of changes) {
        const element = change.element;
        if (seen.has(element)) continue;
        seen.add(element);
        state.originals.push({ element, rows: element.getAttribute('rows'), cols: element.getAttribute('cols') });
        for (const name of ['rows', 'cols']) {
          if (!element.hasAttribute(name)) continue;
          element.setAttribute(name, Array.from({ length: change.count }, (_, index) => index === change.selected ? '*' : '0').join(','));
        }
      }
      window.__y3ClientFrameLayout = state;
      if (focusedWindow) requestAnimationFrame(() => {
        if (trusted(focusedWindow)) { try { focusedWindow.dispatchEvent(new Event('resize')); } catch (_) {} }
      });
      return true;
    }
    """#

    static func focusScript(path: [Int]?) -> String {
        let argument: String
        if let path, !path.isEmpty, path.count <= 8, path.allSatisfy({ (0 ..< 64).contains($0) }) {
            argument = "[" + path.map(String.init).joined(separator: ",") + "]"
        } else if path == nil { argument = "null" }
        else { return "false" }
        return "(" + frameFocus + ")(" + argument + ")"
    }

    // Click the site's own link, retaining its onclick handler, frame target, and transition rules.
    static let siteHome = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const path = '/scripts/verona/menu/metz010_1.asp';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window)) return false;
      if (location.pathname === path) return true;
      const find = (win, depth) => {
        if (depth > 8 || !trusted(win)) return null;
        try {
          for (const anchor of win.document.querySelectorAll('a[href]')) {
            const url = new URL(anchor.href, win.location.href);
            if (url.origin === origin && url.pathname === path && !url.username && !url.password &&
                (win === window || anchor.target.toLowerCase() === '_top')) return anchor;
          }
          for (let i = 0; i < Math.min(win.frames.length, 64); i++) {
            const anchor = find(win.frames[i], depth + 1);
            if (anchor) return anchor;
          }
        } catch (_) {}
        return null;
      };
      const anchor = find(window, 0);
      if (!anchor) return false;
      anchor.click();
      return true;
    })();
    """#
}
