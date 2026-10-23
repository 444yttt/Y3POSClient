import Foundation

struct FramePane: Identifiable {
    enum Kind: String { case condition, result, controls, navigation, export }
    let path: [Int]
    let title: String
    let kind: Kind
    var id: String { path.map(String.init).joined(separator: ".") }
}

enum LegacySiteSupport {
    // Called only for the saved main-frame login URL, with values passed as WK arguments.
    // No automatic submit, page-world credentials bridge, or credential-bearing source.
    static let staffCredentialAutofill = #"""
    'use strict';
    const origin = 'https://adidas-y3.poscmcloud.jp:15505';
    if (location.origin !== origin || location.href !== documentURL ||
        location.pathname !== '/verona/data/cmtz030.asp' || window.top !== window ||
        typeof staffID !== 'string' || !staffID || typeof password !== 'string' || !password) return false;
    const ids = document.querySelectorAll('input[name="tanto_id"]');
    const passwords = document.querySelectorAll('input[name="tanto_pw"]');
    if (ids.length !== 1 || passwords.length !== 1) return false;
    const id = ids[0], pw = passwords[0], form = id.form;
    if (!form || pw.form !== form || form.method.toLowerCase() !== 'post' ||
        id.type !== 'text' || pw.type !== 'password' ||
        id.disabled || id.readOnly || pw.disabled || pw.readOnly ||
        !id.getClientRects().length || !pw.getClientRects().length) return false;
    const action = new URL(form.action || location.href, document.baseURI);
    if (action.origin !== origin || action.username || action.password) return false;
    if ((id.value && id.value !== staffID) || pw.value) return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(id, staffID);
    setter.call(pw, password);
    return true;
    """#

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
        /^\/dataspider\/trigger\/(?:hanbai|move|sku_stok|hanbai_ruikei)\.asp$/i.test(location.pathname);
      if ((location.origin !== origin && !exportDocument) || !document.documentElement) return;
      // Metadata and inventory roles are structural: the site has multiple report URL families.
      const reportTables = doc => Array.from(doc.querySelectorAll('table')).filter(table =>
        !table.closest('[data-y3client-inventory-view]') && !table.querySelector('table')).slice(0, 64);
      window.__y3ClientHasInventoryMetrics = (doc = document) => {
        try {
          if (doc.defaultView.location.origin !== origin) return false;
          return reportTables(doc).some(table => ['有効在庫','積送在庫','取置在庫','販売実績'].every(label => table.textContent.includes(label)));
        } catch (_) { return false; }
      };
      window.__y3ClientIsInventoryMetadata = (doc = document) => {
        try {
          if (doc.defaultView.location.origin !== origin || window.__y3ClientHasInventoryMetrics(doc) ||
              doc.querySelector('input[type="password" i],input[type="text" i],input[type="date" i],textarea')) return false;
          const tables = reportTables(doc);
          const label = cell => cell.textContent.normalize('NFKC').replace(/[\s:：]/g, '');
          const metadata = tables.filter(table => {
            if (table.rows.length < 2 || table.rows.length > 6) return false;
            const labels = Array.from(table.rows).flatMap(row => Array.from(row.cells).map(label));
            return labels.includes('品番') && labels.some(value => /^(作成日付|作成日時|更新日時|更新日付|更新日)$/.test(value));
          });
          // A detail table can end with an original Back button. Its presence must
          // not turn every preceding product field into pager-only metadata.
          const hasDetailRows = table => {
            if (metadata.includes(table) || table.rows.length <= 3) return false;
            let meaningful = 0;
            for (const row of table.rows) {
              const hasText = Array.from(row.cells).some(cell => {
                const walker = doc.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
                let text;
                while ((text = walker.nextNode())) {
                  if (text.textContent.trim() && !text.parentElement?.closest('input,select,button,textarea,script,style')) return true;
                }
                return false;
              });
              if (hasText && ++meaningful > 3) return true;
            }
            return false;
          };
          return metadata.length > 0 && !tables.some(hasDetailRows);
        } catch (_) { return false; }
      };
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
          html[data-y3client-phone] select:not([multiple]):not([size]),
          html[data-y3client-phone] select:not([multiple])[size='0'],
          html[data-y3client-phone] select:not([multiple])[size='1'],
          html[data-y3client-phone] select:not([multiple])[size=''] {
            height:48px!important; min-height:48px!important; padding-right:40px!important;
            -webkit-appearance:none!important; appearance:none!important; background-color:#fff!important;
            background-image:linear-gradient(45deg,transparent 50%,#65707a 50%),linear-gradient(135deg,#65707a 50%,transparent 50%)!important;
            background-position:calc(100% - 20px) 50%,calc(100% - 15px) 50%!important;
            background-size:5px 5px!important; background-repeat:no-repeat!important;
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
      if (exportDocument || /^\/scripts\/verona\/display\/dstz(?:710|730)_3_2\.asp$/i.test(location.pathname)) {
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
          [data-y3client-form-table] > tbody > tr:not([data-y3client-form-row]):not([data-y3client-action-row]) { display:block!important; width:100%!important; }
          [data-y3client-form-table] > tbody > tr:not([data-y3client-form-row]):not([data-y3client-action-row]) > td { display:block!important; width:auto!important; max-width:100%; min-width:0; white-space:normal!important; overflow-wrap:anywhere; box-sizing:border-box; }
          [data-y3client-form-row] { display:grid!important; grid-template-columns:minmax(0,1fr); gap:7px; width:100%!important; margin:0 0 18px; box-sizing:border-box; }
          [data-y3client-form-row] > td, [data-y3client-action-row] > td { display:block!important; width:auto!important; max-width:100%; border:0!important; padding:0!important; background:transparent!important; white-space:normal!important; box-sizing:border-box; }
          [data-y3client-label-cell] { color:#515b64; text-align:left!important; font:600 12px/1.5 -apple-system,BlinkMacSystemFont,sans-serif!important; }
          [data-y3client-label-cell] * { font:inherit!important; color:inherit!important; }
          [data-y3client-form-row] > td[data-y3client-field-cell], [data-y3client-field-cell] { display:flex!important; flex-wrap:wrap; align-items:center; gap:8px; color:#64707b; }
          [data-y3client-field]:not([type='checkbox' i]):not([type='radio' i]) { display:block; width:100%!important; max-width:100%; min-width:0!important; min-height:48px!important; margin:0; padding:11px 12px!important; border:1px solid #dce1e5!important; border-radius:10px; background:#fff!important; color:#111; font:400 16px/1.4 -apple-system,BlinkMacSystemFont,sans-serif!important; box-sizing:border-box; }
          [data-y3client-field]:focus { outline:2px solid #111; outline-offset:1px; }
          html[data-y3client-layout] [data-y3client-form-row] > td[data-y3client-compound-cell], html[data-y3client-layout] [data-y3client-field-cell][data-y3client-compound-cell] { display:grid!important; grid-template-columns:repeat(10,minmax(0,1fr)); gap:8px 6px!important; align-items:center; }
          [data-y3client-compound-cell] [data-y3client-inline-shell] { display:contents!important; }
          [data-y3client-original-label], [data-y3client-legacy-spacer] { display:none!important; }
          [data-y3client-compound-label] { grid-column:1/-1; margin:10px 0 0; color:#515b64; font:600 12px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-compound-control] { grid-row:var(--y3client-grid-row); grid-column:var(--y3client-grid-column); min-width:0!important; max-width:100%!important; }
          [data-y3client-compound-cell] input[data-y3client-field] { width:100%!important; min-width:0!important; padding-inline:6px!important; }
          [data-y3client-compound-cell] input[data-y3client-code-field] { text-align:center; }
          html[data-y3client-layout] [data-y3client-form-row] > td[data-y3client-date-pair], html[data-y3client-layout] [data-y3client-date-pair] { display:grid!important; grid-template-columns:minmax(0,1fr) auto minmax(0,1fr); align-items:center; gap:6px; }
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
      // Old reports put several labeled groups inside a single cell. Style the original
      // nodes in place: reparenting these parser-associated inputs would reset FORM ownership.
      const adaptCompoundCell = cell => {
        if (cell.hasAttribute('data-y3client-compound-cell') || cell.querySelector('table')) return;
        const fields = Array.from(cell.querySelectorAll('input,select,textarea')).filter(control => control.type !== 'hidden');
        if(fields.some(control=>/^(checkbox|radio)$/.test(control.type)))return;
        const entries = fields.filter(control => control.tagName !== 'INPUT' || !/^(button|submit|reset|checkbox|radio)$/.test(control.type));
        const externalLabel=Array.from(cell.parentElement.cells).find(candidate=>candidate!==cell&&!candidate.querySelector('input,select,textarea,button,table')&&text(candidate));
        if (entries.length < 2 || (cell.parentElement.cells.length !== 1&&!externalLabel)) return;
        const walker = document.createTreeWalker(cell, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        const preceding = new Map(), textNodes = [];
        let pending = '', node;
        while ((node = walker.nextNode())) {
          if (node.nodeType === Node.TEXT_NODE) {
            if (node.parentElement.closest('select,textarea,button,script,style,label')) continue;
            pending += node.textContent;
            textNodes.push(node);
          } else if (fields.includes(node)) { preceding.set(node,pending); pending=''; }
        }
        const labelFrom = value => value.normalize('NFKC').replace(/\s+/g,' ').trim().match(/([^:：〜～]{1,40})[:：]\s*$/)?.[1].trim() || '';
        const date = control => /YYYYMMDD/i.test(control.name || '') || control.type === 'date';
        const groups = [];
        for (const control of fields) {
          const label = labelFrom(preceding.get(control) || '');
          const previous = groups[groups.length-1];
          const button = control.tagName === 'INPUT' && /^(button|submit|reset)$/.test(control.type);
          const joined = previous && !label && ((!button && previous.entries.length &&
            ((date(control) && previous.entries.every(date) && previous.entries.length < 2) ||
             (control.name && previous.entries.every(entry=>entry.name===control.name)))) ||
            (button && control.type === 'button' && /(?:item|brand|hinban).*kensaku/i.test(control.name || '')));
          if (joined) { previous.controls.push(control); if(!button)previous.entries.push(control); }
          else groups.push({label,controls:[control],entries:button?[]:[control]});
        }
        if(externalLabel&&groups.length&&!groups[0].label){groups[0].label=text(externalLabel).normalize('NFKC').replace(/\s*[:：]\s*$/,'').trim();groups[0].externalLabel=true;}
        if (groups.filter(group=>group.label).length < 2) return;
        cell.setAttribute('data-y3client-compound-cell','');
        for (const original of textNodes) if (original.textContent.trim()) {
          const hidden=document.createElement('span');hidden.setAttribute('data-y3client-original-label','');
          original.replaceWith(hidden);hidden.appendChild(original);
        }
        for (const element of Array.from(cell.children)) if (!element.matches('input,select,textarea,button,[data-y3client-original-label]') && !element.querySelector('input,select,textarea,button') && !text(element)) element.setAttribute('data-y3client-legacy-spacer','');
        let gridRow=1;
        const position=(control,column,row)=>{
          control.setAttribute('data-y3client-compound-control','');
          control.style.setProperty('--y3client-grid-row',String(row));control.style.setProperty('--y3client-grid-column',column);
          for(let parent=control.parentElement;parent&&parent!==cell;parent=parent.parentElement)parent.setAttribute('data-y3client-inline-shell','');
        };
        for (const group of groups) {
          if(group.label&&!group.externalLabel){const label=document.createElement('span');label.setAttribute('data-y3client-compound-label','');label.textContent=group.label;label.style.gridRow=String(gridRow++);cell.appendChild(label);}
          const pair=group.entries.length===2&&group.entries.every(date);
          const codes=group.entries.length>1&&group.entries.length<=5&&group.entries.every(entry=>entry.tagName==='INPUT'&&entry.maxLength>0&&entry.maxLength<=4);
          for(let index=0;index<group.entries.length;index++){
            const control=group.entries[index];
            position(control,pair?(index===0?'1 / 6':'6 / 11'):codes?(String(index*2+1)+' / '+String(index*2+3)):'1 / -1',gridRow);
            if(codes)control.setAttribute('data-y3client-code-field','');
            if(!control.hasAttribute('aria-label')&&!control.hasAttribute('aria-labelledby')&&!control.labels?.length&&group.label)control.setAttribute('aria-label',group.label+(pair?(index===0?' 開始日':' 終了日'):codes?' '+(index+1):''));
            if(!pair&&!codes)gridRow++;
          }
          if(pair||codes)gridRow++;
          for(const control of group.controls.filter(control=>!group.entries.includes(control))){position(control,'1 / -1',gridRow++);if(group.label){control.setAttribute('data-y3client-lookup-button','');if(!control.hasAttribute('aria-label'))control.setAttribute('aria-label',group.label+'を検索');}}
        }
      };
      for (const form of Array.from(document.forms)) {
        const owned = Array.from(form.elements);
        const legacyTable = searchPage && form.closest('table');
        if (legacyTable && legacyTable.querySelectorAll('form').length === 1) for(const control of legacyTable.querySelectorAll('input,select,textarea')) if(!control.form&&!owned.includes(control))owned.push(control);
        const controls = owned.filter(control => /^(INPUT|SELECT|TEXTAREA)$/.test(control.tagName) && control.type !== 'hidden' && !frozen(control));
        const passwordForm = controls.some(control => control.type === 'password');
        const entryControls = controls.filter(control => !control.disabled && !control.readOnly && (/^(SELECT|TEXTAREA)$/.test(control.tagName) || (control.tagName === 'INPUT' && /^(text|search|date|password|email|number|tel|checkbox|radio)$/.test(control.type))));
        if (!passwordForm && (!searchPage || !entryControls.length)) continue;
        if (passwordForm) root.setAttribute('data-y3client-login', '');
        form.setAttribute('data-y3client-mobile-form', passwordForm ? 'login' : 'search');
        for(const cell of new Set(controls.map(control=>control.closest('td,th')).filter(Boolean)))adaptCompoundCell(cell);
        const tables = new Set();
        for (const control of controls) {
          const table = control.closest('table');
          if (!table || frozen(table)) continue;
          const ownRows = Array.from(table.rows).filter(row => row.closest('table') === table);
          if (ownRows.length > 18) continue;
          tables.add(table);
          const button = control.tagName === 'INPUT' && /^(submit|reset|button)$/.test(control.type);
          if (button) {
            const primary = control.type === 'submit' || (control.type === 'button' && !control.hasAttribute('data-y3client-lookup-button') && /^(検索|検索開始|検索実行|ログイン|表示|実行|送信)$/.test(control.value.trim()));
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
              if (!/^(checkbox|radio)$/.test(control.type) && !control.hasAttribute('aria-label') && !control.hasAttribute('aria-labelledby') && !(control.labels && control.labels.length)) {
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
            // An option label names a choice; the row heading is only a fallback when none exists.
            if (!control.labels?.length && !control.hasAttribute('aria-label') && !control.hasAttribute('aria-labelledby')) {
              const fallback = row && Array.from(row.cells).find(candidate => candidate.hasAttribute('data-y3client-label-cell'));
              if (fallback) {
                if (!fallback.id) fallback.id = uniqueID('y3client-field-label-');
                control.setAttribute('aria-labelledby', fallback.id);
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
      const inventoryMetadata=!!window.__y3ClientIsInventoryMetadata?.();
      // Legacy Tscroller builds the paired header/body tables in its load handler.
      if (document.readyState !== 'complete') { window.addEventListener('load', adaptResults, { once:true }); return; }
      // Summaries and pagers also occur in inventory metadata documents, where generic
      // record-card conversion must stay disabled. Their original cells/forms stay in place.
      if(!document.getElementById('y3client-report-controls-style')){
        const style=document.createElement('style');style.id='y3client-report-controls-style';style.textContent=`
          table[data-y3client-report-summary], table[data-y3client-report-summary] > tbody { display:block!important; width:100%!important; max-width:100%!important; box-sizing:border-box; }
          [data-y3client-report-summary] > tbody > tr { display:grid!important; grid-template-columns:minmax(0,1fr) minmax(0,2fr); width:100%; }
          [data-y3client-report-summary] > tbody > tr > td { display:block!important; width:auto!important; min-width:0!important; white-space:normal!important; overflow-wrap:anywhere; padding:6px 8px; }
          [data-y3client-report-summary] .selecttitle { font-weight:600; color:#65707a; background:#eef0f2; }
          html[data-y3client-layout] [data-y3client-pager-table], html[data-y3client-layout] [data-y3client-pager-table] > tbody { display:block!important; width:100%!important; max-width:100%!important; box-sizing:border-box; }
          html[data-y3client-layout] [data-y3client-pager-table] > tbody > tr { display:flex!important; flex-wrap:wrap; gap:8px; width:100%!important; margin:0; }
          html[data-y3client-layout] [data-y3client-pager-table] > tbody > tr > td { display:block!important; width:auto!important; max-width:100%!important; min-width:0!important; padding:0!important; white-space:normal!important; overflow-wrap:anywhere; flex:0 1 auto; }
          html[data-y3client-layout] [data-y3client-pager-table] > tbody > tr > td[data-y3client-pager-note] { flex-basis:100%; margin:2px 0 8px; font-size:12px!important; color:#737b82; }
          [data-y3client-page-selector] { min-width:64px!important; min-height:44px!important; padding:8px 10px!important; border:1px solid #dce1e5; border-radius:8px; background:#fff; font-size:16px!important; }
        `;document.head.appendChild(style);
      }
      const visibleControls = element => Array.from(element.querySelectorAll('input,select,textarea,button')).some(control => control.type !== 'hidden');
      for(const table of Array.from(document.querySelectorAll('table'))){
        if(table.rows.length<1||table.rows.length>10||table.querySelector('table')||visibleControls(table)||!table.querySelector('td.selecttitle'))continue;
        if(Array.from(table.rows).every(row=>row.cells.length>=2&&row.cells.length%2===0&&Array.from(row.cells).every((cell,index)=>index%2||cell.classList.contains('selecttitle'))))table.setAttribute('data-y3client-report-summary','');
      }
      for (const select of document.querySelectorAll('select[name="PgSelect" i],select[name*="page" i],select[name*="pageno" i]')) {
        select.setAttribute('data-y3client-page-selector','');
        const generatedName=!select.hasAttribute('aria-labelledby')||(select.getAttribute('aria-labelledby')||'').split(/\s+/).every(id=>/^y3client-field-label-/.test(id));
        if (!select.hasAttribute('aria-label') && !select.labels?.length && generatedName) {select.removeAttribute('aria-labelledby');select.setAttribute('aria-label','ページ');}
        const pager=select.closest('table');
        if(pager&&!pager.querySelector('table')&&pager.rows.length<=3&&!/^D_.*_[HB]$/i.test(pager.parentElement?.id||'')){
          pager.setAttribute('data-y3client-pager-table','');
          for(const cell of pager.querySelectorAll('td'))if(!cell.querySelector('input,select,textarea,button')&&cell.textContent.trim())cell.setAttribute('data-y3client-pager-note','');
        }
      }
      if(inventoryMetadata)return;
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
          table[data-y3client-action-table] { display:block!important; width:100%!important; max-width:100%!important; box-sizing:border-box; overflow-x:auto!important; -webkit-overflow-scrolling:touch; }
          table[data-y3client-selection-table] input[type='checkbox' i], table[data-y3client-selection-table] input[type='radio' i] { min-width:44px; min-height:44px; accent-color:#111; }
          table[data-y3client-selection-table] label { display:inline-flex; align-items:center; min-width:44px; min-height:44px; box-sizing:border-box; }
          html[data-y3client-selection-page] #elements-limit { position:static!important; display:block!important; max-width:100%; margin:4px 0; white-space:normal!important; }
          [data-y3client-action-container] { position:relative!important; left:0!important; top:0!important; width:100%!important; max-width:100%!important; height:auto!important; max-height:none!important; box-sizing:border-box; }
          [data-y3client-action-container][data-y3client-action-header] { height:var(--y3client-action-header-height)!important; overflow-y:hidden!important; }
          [data-y3client-action-redundant-header] { display:none!important; }
          [data-y3client-action-container] > table[data-y3client-action-table] { position:static!important; left:auto!important; top:auto!important; }
          [data-y3client-result-shell], [data-y3client-result-shell] > tbody, [data-y3client-result-shell] > tbody > tr, [data-y3client-result-shell] > tbody > tr > td { display:block!important; width:100%!important; max-width:100%!important; min-width:0!important; float:none!important; box-sizing:border-box; }
          table[data-y3client-natural-columns] { width:max-content!important; min-width:100%; table-layout:auto!important; }
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
      // Report actions and selection grids use parser-owned legacy forms. Bound the existing
      // TABLE itself rather than moving it into a wrapper and losing those associations.
      for(const table of Array.from(document.querySelectorAll('table'))){
        if(table.rows.length<2||table.querySelector('table')||table.closest('[data-y3client-form-table],[data-y3client-search-table],#ui-datepicker-div,.ui-datepicker,[role="dialog"],[role="grid"],[data-y3client-table-scroll]'))continue;
        const controls=Array.from(table.querySelectorAll('input,select,textarea,button')).filter(control=>control.type!=='hidden');
        if(!controls.length||!controls.every(control=>control.tagName==='BUTTON'||(control.tagName==='INPUT'&&/^(button|submit|reset|checkbox|radio)$/.test(control.type))))continue;
        table.setAttribute('data-y3client-action-table','');table.setAttribute('data-y3client-table-scroll','');table.tabIndex=0;if(!table.hasAttribute('aria-label'))table.setAttribute('aria-label','操作付き検索結果の表');
        for(const control of controls.filter(control=>/^(checkbox|radio)$/.test(control.type))){
          table.setAttribute('data-y3client-selection-table','');root.setAttribute('data-y3client-selection-page','');
          if(control.hasAttribute('aria-label')||control.hasAttribute('aria-labelledby')||control.labels?.length)continue;
          const row=control.closest('tr'),description=row&&Array.from(row.cells).filter(cell=>!cell.querySelector('input,select,textarea,button')).slice(0,2).map(cell=>(cell.textContent||'').replace(/\s+/g,' ').trim()).filter(Boolean).join(' ');
          if(description)control.setAttribute('aria-label',description.slice(0,120)+' を選択');
        }
        const parent=table.parentElement;
        if(parent&&/^D_.*_[HB]$/i.test(parent.id)){
          if(/_H$/i.test(parent.id)){parent.style.setProperty('--y3client-action-header-height',Math.max(1,parent.getBoundingClientRect().height)+'px');parent.setAttribute('data-y3client-action-header','');}
          parent.setAttribute('data-y3client-action-container','');
        }
        if(parent&&/^D_.*_B$/i.test(parent.id)){
          const header=document.getElementById(parent.id.replace(/_B$/i,'_H'));
          if(header){
            if(!header.hasAttribute('data-y3client-action-container'))header.style.setProperty('--y3client-action-header-height',Math.max(1,header.getBoundingClientRect().height)+'px');
            header.setAttribute('data-y3client-action-header','');header.setAttribute('data-y3client-action-container','');
            const headerTable=header.querySelector('table'),signature=row=>row&&JSON.stringify(Array.from(row.cells).map(cell=>[(cell.textContent||'').replace(/\s+/g,' ').trim(),cell.colSpan,cell.rowSpan]));
            if(headerTable&&signature(headerTable.rows[0])===signature(table.rows[0]))header.setAttribute('data-y3client-action-redundant-header','');
            table.addEventListener('scroll',()=>{const target=header.querySelector('table[data-y3client-action-table]')||header;target.scrollLeft=table.scrollLeft;},{passive:true});
          }
        }
        if(!parent||!/^D_.*_H$/i.test(parent.id)){const hint=document.createElement('p');hint.setAttribute('data-y3client-result-hint','');hint.textContent='表は左右にスクロールできます';table.parentElement.insertBefore(hint,table);}
      }
      const headerText = cell => {
        const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
        let text='', node;
        while ((node=walker.nextNode())) {
          if (!node.parentElement.closest('select,input,script,style')) text+=' '+node.textContent;
        }
        return text.replace(/\s+/g,' ').trim().slice(0,60);
      };
      const isData = table => !inventoryMetadata && table.rows.length >= 2 && !table.closest('[data-y3client-search-table],[data-y3client-form-table],[data-y3client-menu-table],[data-y3client-inventory],[data-y3client-inventory-view],[data-y3client-report-summary],#ui-datepicker-div,.ui-datepicker,.ui-datepicker-calendar,[role="dialog"],[role="grid"]') && !visibleControls(table) && !table.querySelector('table');
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
            const syncedOffsets = new WeakMap();
            const alignScroll = (source, target) => {
              const expected = syncedOffsets.get(source);
              syncedOffsets.delete(source);
              if (expected === source.scrollLeft) return;
              if (target.scrollLeft !== source.scrollLeft) {
                const before = target.scrollLeft;
                target.scrollLeft = source.scrollLeft;
                // A narrower peer may clamp. Its synthetic scroll must not pull this source back.
                if (target.scrollLeft !== before) syncedOffsets.set(target, target.scrollLeft);
              }
            };
            container.addEventListener('scroll',()=>alignScroll(container,headerContainer),{passive:true});
            headerContainer.addEventListener('scroll',()=>alignScroll(headerContainer,container),{passive:true});
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
      for(const table of Array.from(document.querySelectorAll('table'))){
        const ownRows=Array.from(table.rows).filter(row=>row.closest('table')===table);
        if(!table.hasAttribute('data-y3client-table-scroll')&&ownRows.length<=3&&table.querySelector('[data-y3client-table-scroll]'))table.setAttribute('data-y3client-result-shell','');
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
      const searchForms=readOnlyPage?Array.from(document.forms).filter(form=>!form.querySelector('input[type=password]') && Array.from(form.elements).some(input=>/^(SELECT|TEXTAREA)$/.test(input.tagName) || (input.tagName==='INPUT' && ['text','search','date','checkbox','radio'].includes(input.type)))):[];
      const conditionForms=searchForms.filter(form=>Array.from(form.elements).some(input=>!input.disabled&&!input.readOnly&&(input.tagName==='TEXTAREA'||(input.tagName==='SELECT'&&!/^(PgSelect|Page(?:No|Num)?|PageSelect)$/i.test(input.name||''))||(input.tagName==='INPUT'&&['text','search','date','checkbox','radio'].includes(input.type)))));
      for(const form of searchForms)form.setAttribute('data-y3-form','');
      const mark=form=>{
        if(!form?.hasAttribute('data-y3-form'))return;
        const now=Date.now();
        if(now-(state.lastSubmissionAt || 0)<200)return;
        state.lastSubmissionAt=now;
        state.submissionRevision=Math.min((state.submissionRevision || 0)+1,1000000000);
      };
      if(window.__y3ClientSubmissionDocumentRoot!==document.documentElement){
        window.__y3ClientSubmissionDocumentRoot=document.documentElement;
        document.addEventListener('submit',event=>mark(event.target),true);
      }
      if(!window.__y3ClientSubmissionObserver){
        window.__y3ClientSubmissionObserver=true;
        const original=HTMLFormElement.prototype.submit;
        HTMLFormElement.prototype.submit=function(...args){mark(this);return original.apply(this,args);};
      }
      if(window!==host && readOnlyPage && !window.__y3ClientIsInventoryMetadata?.() && !window.__y3ClientHasInventoryMetrics?.() && !conditionForms.length && (document.querySelector('table') || /\/prtz\d+_(?:[2-9]|[2-9]_[2-9])\.asp$/i.test(path))) {
        const ready=()=>{state.resultSubmissionRevision=state.submissionRevision || 0;};
        if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
      }
    })();
    """#

    // Read-only inventory rendering stays inside the same-origin web documents.
    static let inventoryPresentation = #"""
    (() => {
      'use strict';
      const ORIGIN = 'https://adidas-y3.poscmcloud.jp:15505';
      if (location.origin !== ORIGIN || !/^\/scripts\/verona\/(?:display|dwh|print)\/prtz\d+(?:_\d+)*\.asp$/i.test(location.pathname)) return;
      if (window.__y3InventoryPresentation?.version === 1) return;
      const MAX_ROWS = 512;
      const MAX_COLUMNS = 128;
      const own = (object, key) => Object.prototype.hasOwnProperty.call(object || {}, key);
      const clean = value => String(value ?? '').replace(/\s+/g, ' ').trim();
      const keyText = value => clean(value).normalize('NFKC').replace(/[\s:：]/g, '');
      const metrics = [
        { key: 'available', label: '有効在庫' },
        { key: 'inTransit', label: '積送在庫' },
        { key: 'reserved', label: '取置在庫' },
        { key: 'sales', label: '販売実績' },
      ];
      const metricKey = value => metrics.find(metric => metric.label === keyText(value))?.key || null;
      const catalogs = Object.create(null);
      const containerState = new WeakMap();

      // These two code/category relationships were supplied by the user. Nothing is extrapolated.
      catalogs.footwear = { kind: 'footwear', title: 'シューズ', codes: Object.assign(Object.create(null), { '317': { JP: '27.5' } }) };
      catalogs.apparel = { kind: 'apparel', title: 'ウェア', codes: Object.assign(Object.create(null), { '101': { label: 'XS' } }) };

      const nodeText = element => {
        const document = element.ownerDocument;
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let result = '', node;
        while ((node = walker.nextNode())) {
          if (!node.parentElement?.closest('script,style,select,textarea')) result += ' ' + node.textContent;
        }
        return clean(result);
      };

      const tableRows = table => {
        if (!table || table.tagName !== 'TABLE') return [];
        return Array.from(table.rows).filter(row => row.closest('table') === table);
      };

      function expandTable(table) {
        const rows = tableRows(table);
        if (!rows.length || rows.length > MAX_ROWS) return null;
        const grid = Array.from({ length: rows.length }, () => []);
        for (let r = 0; r < rows.length; r++) {
          let column = 0;
          for (const cell of Array.from(rows[r].cells)) {
            while (grid[r][column]) column++;
            const width = Number(cell.colSpan) || 1;
            const height = cell.rowSpan === 0 ? rows.length - r : (Number(cell.rowSpan) || 1);
            if (width < 1 || height < 1 || column + width > MAX_COLUMNS || r + height > rows.length) return null;
            const record = { text: nodeText(cell), row: r, column, width, height };
            for (let rr = r; rr < r + height; rr++) {
              for (let cc = column; cc < column + width; cc++) {
                if (grid[rr][cc]) return null;
                grid[rr][cc] = record;
              }
            }
            column += width;
          }
        }
        return { rows, grid };
      }

      function parseInventorySummary(source) {
        const summary = { productCode: '', productName: '', updatedAt: '', categoryLabel: '', categoryCode: '' };
        if (!source || !(source.querySelectorAll || source.tagName === 'TABLE')) return summary;
        const tables = source.tagName === 'TABLE' ? [source] : Array.from(source.querySelectorAll('table')).slice(0, 32);
        const fields = {
          '品番': 'productCode', '商品名': 'productName', '作成日付': 'updatedAt', '作成日時': 'updatedAt',
          '更新日時': 'updatedAt', '更新日付': 'updatedAt', '更新日': 'updatedAt', 'カテゴリ': 'categoryLabel',
          'カテゴリー': 'categoryLabel', '商品分類': 'categoryLabel',
          'カテゴリNO': 'categoryCode', 'カテゴリーNO': 'categoryCode', 'カテゴリ番号': 'categoryCode',
          'カテゴリー番号': 'categoryCode', 'カテゴリコード': 'categoryCode', 'カテゴリーコード': 'categoryCode',
        };
        for (const table of tables) {
          const rows = tableRows(table).slice(0, 12);
          for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
            const row = rows[rowIndex];
            const cells = Array.from(row.cells);
            for (let index = 0; index < cells.length; index++) {
              const label = nodeText(cells[index]);
              const key = fields[keyText(label).toUpperCase()];
              if (key && !summary[key]) {
                const beside = cells[index + 1] ? nodeText(cells[index + 1]) : '';
                const below = rows[rowIndex + 1]?.cells[index] ? nodeText(rows[rowIndex + 1].cells[index]) : '';
                if (beside && !fields[keyText(beside).toUpperCase()]) summary[key] = beside;
                else if (below && !fields[keyText(below).toUpperCase()]) summary[key] = below;
              } else {
                const inline = label.normalize('NFKC').match(/^(品番|商品名|作成日付|作成日時|更新日時|更新日付|更新日|カテゴリ(?:No|番号|コード)?|カテゴリー(?:No|番号|コード)?|商品分類)\s*[:：]\s*(.+)$/i);
                if (inline) {
                  const inlineKey = fields[keyText(inline[1]).toUpperCase()];
                  if (inlineKey && !summary[inlineKey]) summary[inlineKey] = clean(inline[2]);
                }
              }
            }
          }
        }
        return summary;
      }

      function parseInventoryTable(table) {
        const expanded = expandTable(table);
        if (!expanded) return null;
        const { grid } = expanded;
        const firstMetricRow = grid.findIndex(row => row.some(cell => cell && metricKey(cell.text)));
        if (firstMetricRow < 0) return null;
        const firstMetric = grid[firstMetricRow].find(cell => cell && metricKey(cell.text));
        const metricColumn = firstMetric.column;
        if (metricColumn < 1) return null;
        const axisColumn = metricColumn - 1;
        let axis = '';
        for (let index = 0; index < firstMetricRow; index++) {
          const label = keyText(grid[index][axisColumn]?.text);
          if (label === 'サイズ' || label === 'カラー') axis = label;
        }
        if (!axis) return null;
        const header = grid[firstMetricRow - 1];
        const totalColumn = header.findIndex((cell, column) => column > metricColumn && cell && /^(合計|総計)$/.test(keyText(cell.text)));
        if (totalColumn <= metricColumn) return null;
        const metricRows = [];
        for (let index = firstMetricRow; index < grid.length; index++) {
          const row = grid[index];
          const metric = row[metricColumn];
          const key = metric && metricKey(metric.text);
          if (!key || metric.row !== index) continue;
          if (!row[axisColumn] || !row[totalColumn]) return null;
          metricRows.push({ row, index, key, label: metric.text, axisCode: clean(row[axisColumn].text) });
        }
        if (!metricRows.length) return null;
        const width = Math.max(header.length, ...metricRows.map(record => record.row.length));
        const crossColumns = [];
        const paddingColumns = [];
        for (let column = totalColumn + 1; column < width; column++) {
          const cell = header[column];
          const code = clean(cell?.text);
          if (!code) {
            if (metricRows.some(record => clean(record.row[column]?.text))) return null;
            paddingColumns.push(column);
            continue;
          }
          if (!cell || cell.width !== 1 || cell.column !== column || /^(サイズ|カラー|合計|総計)$/.test(keyText(code))) return null;
          if (metricRows.some(record => !record.row[column])) return null;
          crossColumns.push({ column, code });
        }
        if (!crossColumns.length || new Set(crossColumns.map(record => record.code)).size !== crossColumns.length) return null;
        const groups = [];
        const seen = new Set();
        let current = null;
        for (const record of metricRows) {
          if (!record.axisCode) return null;
          if (!current || current.code !== record.axisCode) {
            if (seen.has(record.axisCode)) return null;
            seen.add(record.axisCode);
            current = { code: record.axisCode, isTotal: /^(総計|合計|全体|全カラー)$/.test(keyText(record.axisCode)), metrics: Object.create(null) };
            groups.push(current);
          }
          if (own(current.metrics, record.key)) return null;
          current.metrics[record.key] = { label: record.label, total: record.row[totalColumn].text, values: crossColumns.map(column => record.row[column.column].text) };
        }
        let sizeCodes, colors;
        if (axis === 'カラー') {
          sizeCodes = crossColumns.map(record => record.code);
          colors = groups.map(group => ({ color: group.code, isTotal: group.isTotal, metrics: group.metrics }));
        } else {
          const sizeGroups = groups.filter(group => !group.isTotal);
          const totalGroups = groups.filter(group => group.isTotal);
          if (!sizeGroups.length || totalGroups.length > 1) return null;
          const overall = totalGroups[0];
          sizeCodes = sizeGroups.map(group => group.code);
          colors = crossColumns.map((column, columnIndex) => {
            const color = { color: column.code, isTotal: false, metrics: Object.create(null) };
            for (const definition of metrics) {
              if (!groups.some(group => own(group.metrics, definition.key))) continue;
              color.metrics[definition.key] = {
                label: groups.find(group => own(group.metrics, definition.key)).metrics[definition.key].label,
                total: overall?.metrics[definition.key]?.values[columnIndex] ?? null,
                values: sizeGroups.map(group => group.metrics[definition.key]?.values[columnIndex] ?? null),
              };
            }
            return color;
          });
          const aggregate = { color: overall?.code || '総計', isTotal: true, metrics: Object.create(null) };
          for (const definition of metrics) {
            if (!groups.some(group => own(group.metrics, definition.key))) continue;
            aggregate.metrics[definition.key] = {
              label: groups.find(group => own(group.metrics, definition.key)).metrics[definition.key].label,
              total: overall?.metrics[definition.key]?.total ?? null,
              values: sizeGroups.map(group => group.metrics[definition.key]?.total ?? null),
            };
          }
          colors.push(aggregate);
        }
        if (!colors.length || !colors.some(color => own(color.metrics, 'available'))) return null;
        return { schemaVersion: 1, orientation: axis === 'サイズ' ? 'sizes-down' : 'colors-down', ignoredPaddingColumns: paddingColumns.length, product: parseInventorySummary(table), sizeCodes, colors };
      }

      function resolveCategory(summary, matrix) {
        const product = matrix?.product || {};
        const categories = { '1':'apparelWomen', APW:'apparelWomen', '2':'apparelMen', APM:'apparelMen',
          '3':'accessories', ACC:'accessories', '4':'footwear', FTW:'footwear', '5':'apparelUnisex', APU:'apparelUnisex' };
        const oneSizeHint = value => /ワンサイズ|フリーサイズ|ノーサイズ|\b(?:OSFA|ONE[\s_-]*SIZE)\b/.test(clean(value).normalize('NFKC').toUpperCase());
        const detailHint = value => {
          const text = clean(value).normalize('NFKC').toUpperCase();
          const hints = [];
          if (/ソックス|\bSOCKS?\b/.test(text)) hints.push('socks');
          if (/帽子|キャップ|ハット|ビーニー|\b(?:CAP|HAT|BEANIE)\b/.test(text)) hints.push('headwear');
          if (hints.length) return hints.length === 1 ? hints[0] : '';
          return oneSizeHint(text) ? 'oneSize' : '';
        };
        const explicitHint = value => {
          const text = clean(value).normalize('NFKC').toUpperCase();
          if (!text) return '';
          if (own(categories, text)) return categories[text];
          const token = text.match(/(?:^|[^A-Z])(APW|APM|ACC|FTW|APU)(?:[^A-Z]|$)/)?.[1];
          if (token) return token === 'ACC' ? (detailHint(text) || categories[token]) : categories[token];
          if (/フットウェア|シューズ|\b(?:FOOTWEAR|SHOES?)\b/.test(text)) return 'footwear';
          const detail = detailHint(text);
          if (detail) return detail;
          if (/ウーマン|ウィメン|レディース|女性|\bWOM[AE]N\b/.test(text)) return 'apparelWomen';
          if (/ユニセックス|\bUNISEX\b/.test(text)) return 'apparelUnisex';
          if (/メンズ|男性|\bM[AE]N\b/.test(text)) return 'apparelMen';
          if (/アクセサリ|\bACCESSOR(?:Y|IES)\b/.test(text)) return 'accessories';
          if (/アパレル|ウェア|シャツ|パーカー|スウェット|ジャケット|パンツ|\b(?:APPAREL|CLOTHING)\b/.test(text)) return 'apparel';
          return '';
        };
        const fields = [summary?.categoryCode, summary?.categoryLabel, product.categoryCode, product.categoryLabel].map(clean).filter(Boolean);
        const hints = fields.map(explicitHint).filter(Boolean);
        let category = '';
        for (const hint of hints) {
          if (!category || category === hint) { category = hint; continue; }
          if (category === 'apparel' && /^apparel(?:Women|Men|Unisex)$/.test(hint)) { category = hint; continue; }
          if (hint === 'apparel' && /^apparel(?:Women|Men|Unisex)$/.test(category)) continue;
          if (category === 'accessories' && ['socks','headwear','oneSize'].includes(hint)) { category = hint; continue; }
          if (hint === 'accessories' && ['socks','headwear','oneSize'].includes(category)) continue;
          return ''; // Conflicting explicit categories never borrow another category's size table.
        }
        const names = [summary?.productName, product.productName].filter(Boolean).join(' ');
        const nameHint = detailHint(names);
        const codes = (matrix?.sizeCodes || []).map(clean);
        const onlyNS = codes.length > 0 && codes.every(code => code === '601');
        const explicitOneSize = codes.length > 0 && codes.every(code => ['601','608'].includes(code)) && oneSizeHint([names,...fields].join(' '));
        const refine = key => key === 'headwear' && (onlyNS || explicitOneSize) ? 'oneSize' : key;
        if (category === 'accessories') return refine(nameHint) || (onlyNS ? 'oneSize' : '');
        if (category) {
          if (explicitOneSize && category !== 'footwear' && category !== 'socks') return 'oneSize';
          if (onlyNS && category !== 'footwear' && category !== 'socks') return 'oneSize';
          return category;
        }
        if (fields.length) return '';
        if (nameHint) return refine(nameHint);
        if (codes.length && codes.every(code => /^(?:30[6-9]|31\d|32[0-4])$/.test(code))) return 'footwear';
        if (codes.length && codes.every(code => /^10[0-6]$/.test(code))) return 'apparel';
        return '';
      }

      function configureSizeMappings(definitions) {
        if (!definitions || typeof definitions !== 'object' || Array.isArray(definitions)) return;
        for (const categoryKey of Object.keys(definitions).slice(0, 32)) {
          if (!/^[A-Za-z0-9_.-]{1,64}$/.test(categoryKey) || ['__proto__', 'constructor', 'prototype'].includes(categoryKey)) continue;
          const definition = definitions[categoryKey];
          if (!definition || !['footwear', 'apparel', 'other'].includes(definition.kind)) continue;
          const category = { kind: definition.kind, title: clean(definition.title).slice(0, 80), codes: Object.create(null) };
          for (const code of Object.keys(definition.codes || {}).slice(0, 256)) {
            if (!/^[A-Za-z0-9_.-]{1,32}$/.test(code) || ['__proto__', 'constructor', 'prototype'].includes(code)) continue;
            const definitionEntry = definition.codes[code];
            if (!definitionEntry || typeof definitionEntry !== 'object') continue;
            const entry = Object.create(null);
            for (const unit of ['label', 'measurement', 'JP', 'US', 'USW', 'UK', 'EU', 'CH']) {
              if (typeof definitionEntry[unit] === 'string' || typeof definitionEntry[unit] === 'number') entry[unit] = clean(definitionEntry[unit]).slice(0, 80);
            }
            category.codes[code] = entry;
          }
          catalogs[categoryKey] = category;
        }
      }

      function formatSize(code, categoryKey, unit = 'JP') {
        const originalCode = clean(code);
        const category = own(catalogs, categoryKey) ? catalogs[categoryKey] : null;
        const entry = category && own(category.codes, originalCode) ? category.codes[originalCode] : null;
        if (category?.kind === 'footwear') {
          const selected = ['JP', 'US', 'USW', 'UK', 'EU', 'CH'].includes(unit) ? unit : 'JP';
          if (entry && own(entry, selected) && entry[selected] !== '') return { text: entry[selected], unit: selected, code: originalCode, confirmed: true };
          return { text: '—', unit: selected, code: originalCode, confirmed: false };
        }
        if (entry && own(entry, 'label') && entry.label !== '') return { text: entry.label, unit: '', code: originalCode, confirmed: true,
          ...(entry.measurement ? { measurement: entry.measurement } : {}) };
        return { text: originalCode, unit: '', code: originalCode, confirmed: false };
      }

      function addStyles(document) {
        if (document.getElementById('y3client-inventory-presentation-style')) return;
        const style = document.createElement('style');
        style.id = 'y3client-inventory-presentation-style';
        style.textContent = `
          [data-y3client-inventory] { color:#15171a; font:14px/1.45 -apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif; max-width:100%; box-sizing:border-box; }
          [data-y3client-inventory] * { box-sizing:border-box; }
          [data-y3client-inventory-header] { margin:0 0 16px; }
          [data-y3client-inventory-title] { margin:0; font-size:21px; line-height:1.3; letter-spacing:-.035em; overflow-wrap:anywhere; }
          [data-y3client-inventory-name] { margin:6px 0; font-size:15px; line-height:1.45; overflow-wrap:anywhere; }
          [data-y3client-inventory-updated] { margin:5px 0 0; color:#717984; font-size:11px; overflow-wrap:anywhere; }
          [data-y3client-inventory-toolbar] { display:flex; align-items:center; justify-content:space-between; gap:10px; margin:0 0 12px; }
          [data-y3client-inventory-toolbar] p { margin:0; font-size:12px; color:#717984; }
          [data-y3client-inventory-table-button] { min-height:44px; padding:9px 12px; border:1px solid #dce1e5; border-radius:10px; background:#fff; color:#15171a; font:600 12px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; white-space:nowrap; }
          [data-y3client-size-selector] { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:3px; margin:0 0 6px; padding:4px; background:#e9ecef; border-radius:11px; }
          [data-y3client-size-unit] { min-width:0; min-height:44px; padding:8px 4px; border:0; border-radius:8px; background:transparent; color:#59626c; font:600 13px/1.2 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-size-unit][aria-pressed='true'] { background:#111; color:#fff; }
          [data-y3client-inventory-size-note] { margin:0 0 14px; font-size:11px; color:#717984; }
          [data-y3client-size-measurement] { display:block;margin-top:2px;color:#59626c;font-size:11px;line-height:1.35; }
          [data-y3client-inventory-filter] { margin:0 0 14px; }
          [data-y3client-inventory-filter-label] { display:flex; align-items:center; gap:9px; min-height:44px; color:#303841; font-size:13px; }
          [data-y3client-inventory-stock-filter] { width:20px!important; height:20px!important; min-width:20px!important; min-height:20px!important; margin:0; padding:0!important; accent-color:#111; }
          [data-y3client-inventory-filter-note] { margin:0; color:#717984; font-size:11px; }
          [data-y3client-inventory-empty] { margin:14px 0 5px; color:#717984; font-size:12px; }
          [data-y3client-inventory-color] { margin:0 0 14px; padding:15px; border:1px solid #dfe4e8; border-radius:14px; background:#fff; }
          [data-y3client-inventory-color-title] { display:flex; align-items:center; justify-content:space-between; gap:8px; margin:0 0 12px; font-size:14px; line-height:1.4; overflow-wrap:anywhere; }
          [data-y3client-inventory-color-title] span { font-size:11px; font-weight:400; color:#717984; }
          [data-y3client-inventory-totals] { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:5px; margin:0 0 13px; padding:10px 0; border-top:1px solid #edf0f2; border-bottom:1px solid #edf0f2; }
          [data-y3client-inventory-total] { min-width:0; }
          [data-y3client-inventory-total] dt { color:#717984; font-size:10px; white-space:normal; }
          [data-y3client-inventory-total] dd { margin:3px 0 0; color:#15171a; font-size:18px; font-weight:650; font-variant-numeric:tabular-nums; overflow-wrap:anywhere; }
          [data-y3client-inventory-grid] { width:100%; border-collapse:collapse; table-layout:fixed; font:13px/1.35 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-inventory-grid] th { padding:7px 4px; color:#717984; font-size:10px; font-weight:500; text-align:right; border:0; border-bottom:1px solid #edf0f2; white-space:normal; }
          [data-y3client-inventory-grid] th:first-child { width:38%; text-align:left; }
          [data-y3client-inventory-grid] td { padding:10px 4px; border:0; border-bottom:1px solid #f0f2f4; vertical-align:middle; text-align:right; white-space:normal; overflow-wrap:anywhere; color:#15171a; font-size:16px; font-weight:550; font-variant-numeric:tabular-nums; }
          [data-y3client-inventory-grid] td:first-child { text-align:left; font-size:14px; }
          [data-y3client-inventory-grid] tr:last-child td { border-bottom:0; }
          [data-y3client-inventory-size-code] { display:block; margin-top:3px; color:#8a929b; font-size:10px; font-weight:400; }
          [data-y3client-inventory-details] { margin-top:7px; border-top:1px solid #edf0f2; }
          [data-y3client-inventory-details] > summary { display:list-item; min-height:44px; padding:13px 0 8px; color:#59626c; font-size:12px; cursor:pointer; }
          [data-y3client-inventory] button:focus-visible, [data-y3client-inventory] summary:focus-visible { outline:2px solid #111; outline-offset:2px; }
          @media (max-width:340px) { [data-y3client-inventory-color] { padding:12px; } [data-y3client-inventory-total] dt { font-size:9px; } }
        `;
        (document.head || document.documentElement).appendChild(style);
      }

      function renderInventory(summary, matrix, container) {
        if (!container || container.nodeType !== Node.ELEMENT_NODE || !matrix || !Array.isArray(matrix.sizeCodes) || !Array.isArray(matrix.colors) || matrix.sizeCodes.length > 64 || matrix.colors.length > 128) return false;
        if (clean(summary?.productCode) && clean(matrix.product?.productCode) && clean(summary.productCode) !== clean(matrix.product.productCode)) return false;
        const document = container.ownerDocument;
        if (document.location.origin !== ORIGIN) return false;
        addStyles(document);
        // Only restore focus owned by this result; a background refresh must not steal it.
        const active = document.activeElement;
        const ownedFocus = active && container.contains(active);
        const focusedUnit = ownedFocus ? active.getAttribute('data-y3client-size-unit') : null;
        const focusedFilter = ownedFocus && active.hasAttribute('data-y3client-inventory-stock-filter');
        const focusedTableButton = ownedFocus && active.hasAttribute('data-y3client-inventory-table-button');
        const focusedDetail = ownedFocus && active.tagName === 'SUMMARY' ? active.closest('[data-y3client-color-code]') : null;
        const focusedColor = focusedDetail?.getAttribute('data-y3client-color-code');
        const focusedTotal = focusedDetail?.hasAttribute('data-y3client-inventory-overall-total');
        const state = containerState.get(container) || { unit: 'JP', onlyStock: false, openColors: new Set() };
        containerState.set(container, state);
        const metadata = {};
        for (const key of ['productCode', 'productName', 'updatedAt', 'categoryKey', 'categoryLabel', 'categoryCode']) metadata[key] = clean(summary?.[key] || matrix.product?.[key]);
        const category = own(catalogs, metadata.categoryKey) ? catalogs[metadata.categoryKey] : null;
        const element = (tag, attribute, value) => {
          const node = document.createElement(tag);
          if (attribute) node.setAttribute(attribute, '');
          if (value !== undefined) node.textContent = String(value);
          return node;
        };
        const displayValue = value => value === undefined || value === null ? '—' : (String(value) === '' ? '\u00a0' : String(value));
        const section = element('section', 'data-y3client-inventory');
        section.setAttribute('aria-label', '在庫照会結果');
        const header = element('header', 'data-y3client-inventory-header');
        header.appendChild(element('h1', 'data-y3client-inventory-title', metadata.productCode || '在庫照会結果'));
        if (metadata.productName) header.appendChild(element('p', 'data-y3client-inventory-name', metadata.productName));
        if (metadata.updatedAt) header.appendChild(element('p', 'data-y3client-inventory-updated', '作成日時 ' + metadata.updatedAt));
        section.appendChild(header);
        const toolbar = element('div', 'data-y3client-inventory-toolbar');
        const colors = matrix.colors.filter(color => color && typeof color.color === 'string' && color.metrics && typeof color.metrics === 'object');
        toolbar.appendChild(element('p', '', colors.filter(color => !color.isTotal).length + 'カラー・' + matrix.sizeCodes.length + 'サイズ'));
        const fallback = element('button', 'data-y3client-inventory-table-button', '表で表示');
        fallback.type = 'button';
        fallback.addEventListener('click', () => {
          container.dispatchEvent(new CustomEvent('y3client:inventory-show-table', { bubbles: true }));
          if (typeof api.onShowTable === 'function') api.onShowTable(container);
        });
        toolbar.appendChild(fallback);
        section.appendChild(toolbar);
        if (category?.kind === 'footwear') {
          const selector = element('div', 'data-y3client-size-selector');
          selector.setAttribute('role', 'group');
          selector.setAttribute('aria-label', 'シューズのサイズ表記');
          const units = ['JP', 'US', 'USW', 'UK', 'EU', 'CH'].filter(unit => ['JP','US','EU','CH'].includes(unit) ||
            Object.values(category.codes).some(entry => own(entry, unit)));
          if (units.length > 4) selector.style.gridTemplateColumns = 'repeat(3,minmax(0,1fr))';
          for (const unit of units) {
            const button = element('button', '', unit === 'USW' ? 'US W' : unit === 'US' ? 'US M' : unit);
            button.type = 'button';
            button.setAttribute('aria-label', unit === 'USW' ? 'US ウィメンズ' : unit === 'US' ? 'US メンズ' : unit);
            button.setAttribute('data-y3client-size-unit', unit);
            button.setAttribute('aria-pressed', state.unit === unit ? 'true' : 'false');
            button.addEventListener('click', () => { state.unit = unit; renderInventory(summary, matrix, container); });
            selector.appendChild(button);
          }
          section.appendChild(selector);
          section.appendChild(element('p', 'data-y3client-inventory-size-note', 'US Mはメンズ、US Wはウィメンズ。CHは中国（CHN）の参考換算です。空欄・未確認のサイズは換算しません。'));
        } else if (!category) {
          section.appendChild(element('p', 'data-y3client-inventory-size-note', '商品カテゴリを確認できないため、サイズコードを表示しています。'));
        }
        const filter = element('div', 'data-y3client-inventory-filter');
        const filterLabel = element('label', 'data-y3client-inventory-filter-label');
        const filterCheckbox = element('input', 'data-y3client-inventory-stock-filter');
        filterCheckbox.type = 'checkbox';
        filterCheckbox.checked = state.onlyStock;
        filterCheckbox.addEventListener('change', () => { state.onlyStock = filterCheckbox.checked; renderInventory(summary, matrix, container); });
        filterLabel.append(filterCheckbox, document.createTextNode('在庫ありのみ'));
        filter.appendChild(filterLabel);
        filter.appendChild(element('p', 'data-y3client-inventory-filter-note', '有効在庫が0のサイズを非表示。未確認・マイナスは表示します。'));
        section.appendChild(filter);
        const isExplicitZero = value => typeof value === 'string' || typeof value === 'number' ? /^0+(?:\.0+)?$/.test(clean(value)) : false;
        const makeGrid = (color, definitions, detail, visibleIndices) => {
          const table = element('table', 'data-y3client-inventory-grid');
          table.setAttribute('aria-label', (color.isTotal ? color.color : 'カラー ' + color.color) + (detail ? ' 積送・取置在庫' : ' サイズ別在庫・販売実績'));
          const head = document.createElement('thead');
          const heading = document.createElement('tr');
          for (const label of ['サイズ', ...definitions.map(metric => metric.label)]) {
            const cell = element('th', '', label);
            cell.scope = 'col';
            heading.appendChild(cell);
          }
          head.appendChild(heading);
          table.appendChild(head);
          const body = document.createElement('tbody');
          for (const index of visibleIndices) {
            const code = clean(matrix.sizeCodes[index]);
            const formatted = formatSize(code, metadata.categoryKey, state.unit);
            const row = element('tr', detail ? 'data-y3client-inventory-detail-row' : 'data-y3client-inventory-size-row');
            row.setAttribute('data-y3client-size-code', code);
            const sizeCell = element('td');
            const unitLabel = formatted.unit === 'USW' ? 'US W' : formatted.unit === 'US' ? 'US M' : formatted.unit;
            sizeCell.appendChild(document.createTextNode((unitLabel && formatted.confirmed ? unitLabel + ' ' : '') + formatted.text));
            if (formatted.measurement) sizeCell.appendChild(element('span', 'data-y3client-size-measurement', formatted.measurement));
            sizeCell.appendChild(element('span', 'data-y3client-inventory-size-code', formatted.confirmed ? 'コード ' + code : (formatted.unit ? '未確認 · ' + code : 'サイズコード')));
            row.appendChild(sizeCell);
            for (const definition of definitions) row.appendChild(element('td', '', displayValue(color.metrics[definition.key]?.values?.[index])));
            body.appendChild(row);
          }
          table.appendChild(body);
          return table;
        };
        for (const color of colors) {
          const card = element('article', 'data-y3client-inventory-color');
          card.setAttribute('data-y3client-color-code', color.color);
          if (color.isTotal) card.setAttribute('data-y3client-inventory-overall-total', '');
          const title = element('h2', 'data-y3client-inventory-color-title', color.isTotal ? color.color : 'カラー ' + color.color);
          title.appendChild(element('span', '', '元データの合計'));
          card.appendChild(title);
          const totals = element('dl', 'data-y3client-inventory-totals');
          for (const definition of metrics) {
            const total = element('div', 'data-y3client-inventory-total');
            total.setAttribute('data-y3client-metric', definition.key);
            total.append(element('dt', '', definition.label), element('dd', '', displayValue(color.metrics[definition.key]?.total)));
            totals.appendChild(total);
          }
          card.appendChild(totals);
          const visibleIndices = matrix.sizeCodes.map((_, index) => index).filter(index => !state.onlyStock || !isExplicitZero(color.metrics.available?.values?.[index]));
          if (!visibleIndices.length) {
            card.appendChild(element('p', 'data-y3client-inventory-empty', '該当するサイズはありません'));
            section.appendChild(card);
            continue;
          }
          card.appendChild(makeGrid(color, [metrics[0], metrics[3]], false, visibleIndices));
          const detail = element('details', 'data-y3client-inventory-details');
          const colorKey = (color.isTotal ? 'total:' : 'color:') + color.color;
          detail.open = state.openColors.has(colorKey);
          detail.addEventListener('toggle', () => {
            if (detail.open) state.openColors.add(colorKey);
            else state.openColors.delete(colorKey);
          });
          detail.appendChild(element('summary', '', '積送在庫・取置在庫を見る'));
          detail.appendChild(makeGrid(color, [metrics[1], metrics[2]], true, visibleIndices));
          card.appendChild(detail);
          section.appendChild(card);
        }
        container.replaceChildren(section);
        if (ownedFocus) {
          let replacement = null;
          if (focusedUnit) replacement = Array.from(section.querySelectorAll('[data-y3client-size-unit]')).find(button => button.getAttribute('data-y3client-size-unit') === focusedUnit);
          else if (focusedFilter) replacement = section.querySelector('[data-y3client-inventory-stock-filter]');
          else if (focusedTableButton) replacement = section.querySelector('[data-y3client-inventory-table-button]');
          else if (focusedColor !== undefined) replacement = Array.from(section.querySelectorAll('[data-y3client-color-code]')).find(card => card.getAttribute('data-y3client-color-code') === focusedColor && card.hasAttribute('data-y3client-inventory-overall-total') === focusedTotal)?.querySelector('summary');
          replacement?.focus({ preventScroll: true });
        }
        return true;
      }

      const api = { version: 1, parseInventoryTable, parseInventorySummary, resolveCategory, configureSizeMappings, formatSize, renderInventory, onShowTable: null };
      window.__y3InventoryPresentation = api;
      document.addEventListener('y3client:inventory-update', event => {
        const detail = event.detail;
        if (detail && typeof detail === 'object' && detail.container) renderInventory(detail.summary, detail.matrix, detail.container);
      });
    })();

    (() => {
      if(location.origin!=='https://adidas-y3.poscmcloud.jp:15505'||!/^\/scripts\/verona\/(?:print|dwh|display)\/prtz\d+(?:_\d+)*\.asp$/i.test(location.pathname))return;
      // User-supplied store guide, 2026-10-17. Preserve its blank cells and category boundaries.
      // Headwear code labels were confirmed earlier; the guide adds S/M/L measurements.
      // CH is absent from this guide: keep only the previously documented reference conversions.
      const catalog={
      "footwear": {
        "kind": "footwear",
        "title": "シューズ",
        "codes": {
          "306": {
            "JP": "22",
            "UK": "3.5",
            "US": "4",
            "EU": "36",
            "USW": "5"
          },
          "307": {
            "JP": "22.5",
            "UK": "4",
            "US": "4.5",
            "EU": "36 2/3",
            "USW": "5.5"
          },
          "308": {
            "JP": "23",
            "UK": "4.5",
            "US": "5",
            "EU": "37 1/3",
            "USW": "6"
          },
          "309": {
            "JP": "23.5",
            "UK": "5",
            "US": "5.5",
            "EU": "38",
            "USW": "6.5"
          },
          "310": {
            "JP": "24",
            "UK": "5.5",
            "US": "6",
            "EU": "38 2/3",
            "USW": "7"
          },
          "311": {
            "JP": "24.5",
            "UK": "6",
            "US": "6.5",
            "EU": "39 1/3",
            "USW": "7.5"
          },
          "312": {
            "JP": "25",
            "UK": "6.5",
            "US": "7",
            "EU": "40",
            "USW": "8"
          },
          "313": {
            "JP": "25.5",
            "UK": "7",
            "US": "7.5",
            "EU": "40 2/3",
            "USW": "8.5",
            "CH": "250"
          },
          "314": {
            "JP": "26",
            "UK": "7.5",
            "US": "8",
            "EU": "41 1/3",
            "USW": "9",
            "CH": "255"
          },
          "315": {
            "JP": "26.5",
            "UK": "8",
            "US": "8.5",
            "EU": "42",
            "USW": "9.5",
            "CH": "260"
          },
          "316": {
            "JP": "27",
            "UK": "8.5",
            "US": "9",
            "EU": "42 2/3",
            "USW": "10",
            "CH": "265"
          },
          "317": {
            "JP": "27.5",
            "UK": "9",
            "US": "9.5",
            "EU": "43 1/3",
            "USW": "10.5",
            "CH": "265"
          },
          "318": {
            "JP": "28",
            "UK": "9.5",
            "US": "10",
            "EU": "44",
            "USW": "11",
            "CH": "270"
          },
          "319": {
            "JP": "28.5",
            "UK": "10",
            "US": "10.5",
            "EU": "44 2/3",
            "USW": "11.5"
          },
          "320": {
            "JP": "29",
            "UK": "10.5",
            "US": "11",
            "EU": "45 1/3",
            "USW": "12"
          },
          "321": {
            "JP": "29.5",
            "UK": "11",
            "US": "11.5",
            "EU": "46",
            "USW": "12.5"
          },
          "322": {
            "JP": "30",
            "UK": "11.5",
            "US": "12",
            "EU": "46 2/3",
            "USW": "13"
          },
          "323": {
            "JP": "30.5",
            "UK": "12",
            "US": "12.5",
            "EU": "47 1/3"
          },
          "324": {
            "JP": "31",
            "UK": "12.5",
            "US": "13",
            "EU": "48"
          }
        }
      },
      "apparel": {
        "kind": "apparel",
        "title": "ウェア",
        "codes": {
          "100": {
            "label": "2XS"
          },
          "101": {
            "label": "XS"
          },
          "102": {
            "label": "S"
          },
          "103": {
            "label": "M"
          },
          "104": {
            "label": "L"
          },
          "105": {
            "label": "XL"
          },
          "106": {
            "label": "2XL"
          }
        }
      },
      "apparelWomen": {
        "kind": "apparel",
        "title": "ウィメンズ",
        "codes": {
          "100": {
            "label": "2XS"
          },
          "101": {
            "label": "XS"
          },
          "102": {
            "label": "S"
          },
          "103": {
            "label": "M"
          },
          "104": {
            "label": "L"
          }
        }
      },
      "apparelMen": {
        "kind": "apparel",
        "title": "メンズ",
        "codes": {
          "101": {
            "label": "XS"
          },
          "102": {
            "label": "S"
          },
          "103": {
            "label": "M"
          },
          "104": {
            "label": "L"
          },
          "105": {
            "label": "XL"
          },
          "106": {
            "label": "2XL"
          }
        }
      },
      "apparelUnisex": {
        "kind": "apparel",
        "title": "ユニセックス",
        "codes": {
          "100": {
            "label": "2XS"
          },
          "101": {
            "label": "XS"
          },
          "102": {
            "label": "S"
          },
          "103": {
            "label": "M"
          },
          "104": {
            "label": "L"
          },
          "105": {
            "label": "XL"
          },
          "106": {
            "label": "2XL"
          }
        }
      },
      "headwear": {
        "kind": "apparel",
        "title": "帽子",
        "codes": {
          "100": {
            "label": "2XS"
          },
          "101": {
            "label": "XS"
          },
          "102": {
            "label": "S",
            "measurement": "頭囲 56cm"
          },
          "103": {
            "label": "M",
            "measurement": "頭囲 58cm"
          },
          "104": {
            "label": "L",
            "measurement": "頭囲 60cm"
          },
          "105": {
            "label": "XL"
          }
        }
      },
      "socks": {
        "kind": "other",
        "title": "ソックス",
        "codes": {
          "605": {
            "label": "21–22cm",
            "measurement": "EU 34–36"
          },
          "606": {
            "label": "22–24cm",
            "measurement": "EU 37–39"
          },
          "607": {
            "label": "24–26cm",
            "measurement": "EU 40–42"
          },
          "608": {
            "label": "26–28cm",
            "measurement": "EU 43–45"
          }
        }
      },
      "oneSize": {
        "kind": "other",
        "title": "ワンサイズ",
        "codes": {
          "601": {
            "label": "NS"
          },
          "608": {
            "label": "OSFA"
          }
        }
      }
    };
      window.__y3InventoryPresentation?.configureSizeMappings(catalog);
      try{if(window.top.location.origin===location.origin)window.top.__y3InventorySizeCatalog=catalog;}catch(_){}
    })();

    // Automatic document presentation and cross-frame coordination.
    (() => {
      'use strict';
      const ORIGIN='https://adidas-y3.poscmcloud.jp:15505';
      const rootPath=/^\/scripts\/verona\/(?:print|dwh|display)\/(prtz\d+)(?:_\d+)*\.asp$/i;
      const trusted=win=>{try{return win.location.origin===ORIGIN;}catch(_){return false;}};
      let host;
      try {host=window.top;if(!trusted(host)||!rootPath.test(host.location.pathname))return;}catch(_){return;}
      if(host.__y3ClientInventoryMerge){host.__y3ClientInventoryMerge.reconcile();return;}
      const state={primary:null,secondary:null,view:null,mount:null,signature:'',mode:'cards',merged:false,raw:null,sourceTable:null,readySubmission:0};
      // Keep the last accepted source across invalidation. SKU equality alone cannot
      // distinguish a new same-product search from its old, still-complete data frame.
      let lastReadySource=null;
      const listening=new WeakSet();
      const clean=value=>String(value??'').replace(/\s+/g,' ').trim();
      const keyText=value=>clean(value).normalize('NFKC').replace(/[\s:：]/g,'');
      const metricKeys=['available','inTransit','reserved','sales'];
      const metricLabels=new Set(['有効在庫','積送在庫','取置在庫','販売実績']);
      const generated='[data-y3client-inventory],[data-y3client-inventory-view]';
      const currentDocument=frame=>{try{return trusted(frame.win)&&frame.win.document===frame.doc;}catch(_){return false;}};
      let running=false;
      const invalidate=()=>{
        const navigation=host.__y3ClientNavigation;
        const accepted=state.merged?state.readySubmission:lastReadySource?.submission;
        // A generic load observer may have marked the new revision ready while
        // one inventory response still belongs to the preceding search.
        if(navigation&&accepted!==undefined&&(navigation.resultSubmissionRevision===accepted||
          (navigation.submissionRevision>accepted&&navigation.resultSubmissionRevision===navigation.submissionRevision)))navigation.resultSubmissionRevision=0;
        if(state.primary)state.primary.documentElement.removeAttribute('data-y3client-inventory-primary');
        if(state.secondary)state.secondary.documentElement.removeAttribute('data-y3client-inventory-secondary');
        state.view?.remove();state.primary=null;state.secondary=null;state.view=null;state.mount=null;state.signature='';state.sourceTable=null;state.raw=null;state.merged=false;state.readySubmission=0;
      };
      const leafFrames=()=>{
        const result=[];
        let visited=0;
        const walk=(win,depth)=>{
          if(depth>6||!trusted(win))return;
          for(const element of win.document.querySelectorAll('frame')){
            if(++visited>128)return;
            const child=element.contentWindow;
            if(!child||!trusted(child))continue;
            if(!listening.has(element)){
              listening.add(element);
              element.addEventListener('load',()=>{reconcile();host.setTimeout(reconcile,0);});
            }
            if(child.document.querySelector('frameset'))walk(child,depth+1);
            else result.push({win:child,doc:child.document,path:child.location.pathname});
          }
        };
        if(!host.document.querySelector('frameset')&&host.document.body?.tagName==='BODY')result.push({win:host,doc:host.document,path:host.location.pathname});
        else walk(host,0);
        return result;
      };
      const originalTables=doc=>Array.from(doc.querySelectorAll('table')).filter(table=>!table.closest(generated)).slice(0,64);
      const hasAllMetrics=matrix=>matrix&&Array.isArray(matrix.colors)&&matrix.colors.length>0&&
        matrix.colors.every(color=>metricKeys.every(key=>Object.prototype.hasOwnProperty.call(color.metrics||{},key)));
      const analyzeFrame=frame=>{
        if(frame.doc.readyState!=='complete'||!currentDocument(frame))return null;
        const api=frame.win.__y3InventoryPresentation;
        if(!api?.parseInventoryTable||!api.parseInventorySummary)return null;
        const tables=originalTables(frame.doc);
        const sourceOrder=tables.slice().sort((a,b)=>(b.id.endsWith('_H')?1:0)-(a.id.endsWith('_H')?1:0));
        const matrices=new Map();
        let containsMetricCells=false;
        for(const table of sourceOrder){
          if(!containsMetricCells)containsMetricCells=Array.from(table.querySelectorAll('th,td')).some(cell=>
            cell.closest('table')===table&&metricLabels.has(keyText(cell.textContent)));
          const matrix=api.parseInventoryTable(table);
          if(!hasAllMetrics(matrix)||!clean(matrix.product?.productCode))continue;
          const signature=JSON.stringify(matrix);
          if(!matrices.has(signature))matrices.set(signature,{frame,matrix,sourceTable:table});
        }
        // Paired frozen header/body copies represent one document, not two result candidates.
        if(matrices.size===1)return {matrix:Array.from(matrices.values())[0],metadata:null};
        if(matrices.size>1||containsMetricCells)return null;
        const originalControls=Array.from(frame.doc.querySelectorAll('input,textarea')).filter(control=>!control.closest(generated));
        if(originalControls.some(control=>control.tagName==='TEXTAREA'||['text','search','date','password'].includes(control.type)))return null;
        const summary={productCode:'',productName:'',updatedAt:'',categoryLabel:'',categoryCode:''};
        const summaryTables=[];
        for(const table of tables){
          const fields=api.parseInventorySummary(table);
          if(fields.productCode||fields.updatedAt)summaryTables.push(table);
          for(const key of Object.keys(summary))if(!summary[key]&&fields[key])summary[key]=fields[key];
        }
        if(!clean(summary.productCode)||!clean(summary.updatedAt))return null;
        const pager=Array.from(frame.doc.querySelectorAll('select[name="PgSelect"]')).find(control=>!control.closest(generated));
        return {matrix:null,metadata:{frame,summary,sourceTables:summaryTables,hasPager:!!pager}};
      };
      const inventoryPair=frames=>{
        const family=rootPath.exec(host.location.pathname)?.[1].toLowerCase();
        const relevant=frames.filter(frame=>rootPath.exec(frame.path)?.[1].toLowerCase()===family);
        // A loading counterpart cannot be replaced by an old already-complete result.
        if(relevant.some(frame=>frame.doc.readyState!=='complete'))return null;
        const analyses=relevant.map(analyzeFrame).filter(Boolean);
        const matrices=analyses.map(record=>record.matrix).filter(Boolean);
        const metadata=analyses.map(record=>record.metadata).filter(Boolean);
        // Product links can open a complete stock detail document without a frameset
        // or a separate metadata frame. The same confident four-metric parser must
        // drive that screen too, rather than leaving the raw size-code matrix visible.
        if(!host.document.querySelector('frameset')&&matrices.length===1){
          const secondary=matrices[0],frame=secondary.frame;
          const api=frame.win.__y3InventoryPresentation;
          const summary={...secondary.matrix.product};
          const summaryTables=[];
          for(const table of originalTables(frame.doc)){
            const fields=api.parseInventorySummary(table);
            if(fields.productCode&&clean(fields.productCode)!==clean(summary.productCode))return null;
            if(fields.productCode||fields.updatedAt)summaryTables.push(table);
            for(const key of Object.keys(fields))if(!summary[key]&&fields[key])summary[key]=fields[key];
          }
          if(!clean(summary.productCode))return null;
          return {primary:frame,secondary:frame,summary,summaryTables,matrix:secondary.matrix,sourceTable:secondary.sourceTable,standalone:true};
        }
        const pairs=[];
        for(const secondary of matrices){
          const matching=metadata.filter(primary=>primary.frame.doc!==secondary.frame.doc&&
            clean(primary.summary.productCode)===clean(secondary.matrix.product.productCode));
          const paged=matching.filter(primary=>primary.hasPager);
          const preferred=paged.length?paged:matching;
          for(const primary of preferred)pairs.push({primary:primary.frame,secondary:secondary.frame,summary:primary.summary,summaryTables:primary.sourceTables,matrix:secondary.matrix,sourceTable:secondary.sourceTable});
        }
        return pairs.length===1?pairs[0]:null;
      };
      const installStyle=doc=>{
        if(doc.getElementById('y3client-inventory-merge-style'))return;
        const style=doc.createElement('style');style.id='y3client-inventory-merge-style';
        style.textContent=`
          html[data-y3client-inventory-primary] { background:#f4f5f6; }
          html[data-y3client-inventory-primary] body { margin:0!important;padding:18px 16px 24px!important;background:transparent!important;max-width:100%;box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,sans-serif; }
          html[data-y3client-inventory-primary] body > :not([data-y3client-inventory-view]):not(script):not(style) { display:none!important; }
          [data-y3client-inventory-view] { width:100%;max-width:100%;box-sizing:border-box; }
          [data-y3client-inventory-pages] { display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:8px 0 18px;color:#59626c;font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-inventory-pages] button,[data-y3client-inventory-pages] select { min-width:44px;min-height:44px;max-width:100%;border:1px solid #dce1e5;border-radius:9px;background:#fff;color:#17191d;padding:8px 12px;font:14px/1.3 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-inventory-pages] button:disabled { opacity:.4; }
          [data-y3client-inventory-pages] label { display:flex;align-items:center;gap:8px; }
          [data-y3client-inventory-back] { width:100%;min-height:44px;margin:4px 0 8px;padding:10px 12px;border:1px solid #dce1e5;border-radius:9px;background:#fff;font-size:14px;color:#17191d; }
          [data-y3client-inventory-raw-scroll] { max-width:100%;width:100%;overflow-x:auto;background:#fff;border-radius:12px; }
          [data-y3client-inventory-raw-scroll] table { position:static!important;left:auto!important;top:auto!important;border-collapse:collapse;width:max-content!important;min-width:100%; }
          [data-y3client-inventory-raw-scroll] th,[data-y3client-inventory-raw-scroll] td { border:1px solid #e3e5e8;padding:9px 12px;white-space:nowrap;font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-inventory-view] [hidden] { display:none!important; }
        `;
        (doc.head||doc.documentElement).appendChild(style);
      };
      const showTable=()=>{
        if(!state.merged||!state.raw||!state.mount)return;
        const transfer=state.mount.contains(state.primary.activeElement);
        state.mode='table';state.mount.hidden=true;state.raw.hidden=false;
        if(transfer)state.raw.querySelector('[data-y3client-inventory-back]')?.focus({preventScroll:true});
      };
      const createRawView=(doc,source,summary)=>{
        const panel=doc.createElement('section');panel.setAttribute('data-y3client-inventory-raw','');
        const title=doc.createElement('h1');title.textContent=summary.productCode;panel.appendChild(title);
        const caption=doc.createElement('p');caption.textContent=[summary.productName,summary.updatedAt].filter(Boolean).join(' · ');panel.appendChild(caption);
        const back=doc.createElement('button');back.type='button';back.setAttribute('data-y3client-inventory-back','');back.textContent='サイズ別一覧に戻る';
        back.addEventListener('click',()=>{const transfer=panel.contains(doc.activeElement);state.mode='cards';panel.hidden=true;state.mount.hidden=false;if(transfer)state.mount.querySelector('[data-y3client-inventory-table-button]')?.focus({preventScroll:true});});panel.appendChild(back);
        const hint=doc.createElement('p');hint.textContent='元のサイズコードで表示しています。表は左右にスクロールできます。';hint.style.cssText='font-size:12px;color:#737b82;';panel.appendChild(hint);
        const scroll=doc.createElement('div');scroll.setAttribute('data-y3client-inventory-raw-scroll','');scroll.setAttribute('role','region');scroll.setAttribute('aria-label','元の在庫表');scroll.tabIndex=0;
        const copy=source.cloneNode(true), originals=[source,...source.querySelectorAll('*')], copies=[copy,...copy.querySelectorAll('*')];
        for(let index=0;index<copies.length;index++){
          const node=copies[index];
          for(const attribute of Array.from(node.attributes))if(/^on/i.test(attribute.name)||['id','name','style'].includes(attribute.name))node.removeAttribute(attribute.name);
          if(node.tagName==='A')node.addEventListener('click',event=>{event.preventDefault();if(originals[index]?.isConnected)originals[index].click();});
        }
        scroll.appendChild(copy);panel.appendChild(scroll);return panel;
      };
      const addPager=(primary,view)=>{
        const doc=primary.doc;
        const original=doc.querySelector('select[name="PgSelect"]');
        if(original){
          const section=doc.createElement('div');section.setAttribute('data-y3client-inventory-pages','');
          const label=doc.createElement('label');label.textContent='ページ';
          const select=doc.createElement('select');select.setAttribute('aria-label','在庫結果のページ');
          for(const option of Array.from(original.options)){const copy=doc.createElement('option');copy.value=option.value;copy.textContent=option.text;copy.disabled=option.disabled;select.appendChild(copy);}
          select.value=original.value;label.appendChild(select);section.appendChild(label);
          const max=doc.querySelector('input[name="PgMax"]');
          if(max&&/^\d{1,6}$/.test(max.value)){const count=doc.createElement('span');count.textContent='/ '+max.value;section.appendChild(count);}
          for(const [name,text] of [['hyouzi','表示'],['Front','前へ'],['Back','次へ']]){
            const control=doc.querySelector('input[name="'+name+'"]');if(!control)continue;
            const button=doc.createElement('button');button.type='button';button.textContent=text;button.disabled=control.disabled;button.setAttribute('aria-label','在庫結果 '+text);
            button.addEventListener('click',()=>{
              if(!currentDocument(primary)||!control.isConnected||control.disabled)return;
              original.value=select.value;
              // Mark before delegation; the generic observer's debounce avoids counting twice.
              const navigation=host.__y3ClientNavigation||(host.__y3ClientNavigation={submissionRevision:0,resultSubmissionRevision:0});
              navigation.lastSubmissionAt=Date.now();navigation.submissionRevision=Math.min((navigation.submissionRevision||0)+1,1000000000);
              control.click();
            });section.appendChild(button);
          }
          view.appendChild(section);
        }
        const family=rootPath.exec(host.location.pathname)?.[1].toLowerCase();
        let search=null,navigation=null;
        for(const frame of leafFrames()){
          if(!currentDocument(frame)||rootPath.exec(frame.path)?.[1].toLowerCase()!==family)continue;
          const anchor=Array.from(frame.doc.querySelectorAll('a[href]')).find(anchor=>{
            if(anchor.closest(generated)||!/検索指定|検索条件|検索/.test(clean(anchor.textContent)))return false;
            try{const url=new URL(anchor.href,frame.win.location.href);const match=rootPath.exec(url.pathname);
              return url.origin===ORIGIN&&!url.username&&!url.password&&match?.[1].toLowerCase()===family&&
                new RegExp('/'+family+'_1\\.asp$','i').test(url.pathname);
            }catch(_){return false;}
          });
          if(anchor){search=anchor;navigation=frame;break;}
        }
        if(search){const button=doc.createElement('button');button.type='button';button.setAttribute('data-y3client-inventory-back','');button.textContent='検索条件を変更';button.addEventListener('click',()=>{if(currentDocument(navigation)&&search.isConnected)search.click();});view.appendChild(button);}
        // Keep the original detail-page return action and its page-world handler.
        // Its form/control stays in place, including parser-owned form associations.
        if(!host.document.querySelector('frameset')){
          const original=Array.from(doc.querySelectorAll('input[type="button" i],input[type="submit" i],button,a[href]')).find(control=>
            !control.closest(generated)&&/^戻る$/.test(clean(control.value||control.textContent)));
          if(original){const button=doc.createElement('button');button.type='button';button.setAttribute('data-y3client-inventory-back','');button.textContent='戻る';button.addEventListener('click',()=>{if(currentDocument(primary)&&original.isConnected&&!original.disabled)original.click();});view.appendChild(button);}
        }
      };
      function reconcile(){
        if(running)return state.merged;
        if(!trusted(host)||!rootPath.test(host.location.pathname)||(!host.document.querySelector('frameset')&&host.document.body?.tagName!=='BODY')){invalidate();return false;}
        running=true;
        try{
          const frames=leafFrames();
          const pair=inventoryPair(frames);
          if(!pair){invalidate();return false;}
          const {primary,secondary,matrix,sourceTable}=pair;
          const submission=host.__y3ClientNavigation?.submissionRevision||0;
          const matrixSignature=JSON.stringify(matrix);
          const summarySignature=JSON.stringify(pair.summary);
          if(lastReadySource&&submission>lastReadySource.submission){
            const matrixFresh=secondary.doc!==lastReadySource.document||sourceTable!==lastReadySource.table||matrixSignature!==lastReadySource.signature;
            const summaryFresh=primary.doc!==lastReadySource.primaryDocument||summarySignature!==lastReadySource.summarySignature||pair.summaryTables.length!==lastReadySource.summaryTables.length||pair.summaryTables.some((table,index)=>table!==lastReadySource.summaryTables[index]);
            if(!matrixFresh||(!pair.standalone&&!summaryFresh)){invalidate();return false;}
          }
          const api=primary.win.__y3InventoryPresentation;
          if(!api){invalidate();return false;}
          const summary={...pair.summary};
          summary.categoryKey=api.resolveCategory(summary,matrix);
          const catalog=host.__y3InventorySizeCatalog;
          if(catalog)api.configureSizeMappings(catalog);
          const signature=JSON.stringify([summary,matrix]);
          if(state.primary===primary.doc&&state.secondary===secondary.doc&&state.signature===signature&&state.sourceTable===sourceTable&&state.view?.isConnected){return true;}
          const samePrimary=state.primary===primary.doc;
          if(!samePrimary){invalidate();state.mode='cards';}
          if(!state.view){state.view=primary.doc.createElement('div');state.view.setAttribute('data-y3client-inventory-view','');state.mount=primary.doc.createElement('div');state.view.appendChild(state.mount);}
          const active=primary.doc.activeElement;
          const rawBackFocused=state.raw?.contains(active)&&active.hasAttribute('data-y3client-inventory-back');
          const rawLinkIndex=state.raw?.contains(active)&&active.tagName==='A'?Array.from(state.raw.querySelectorAll('a')).indexOf(active):-1;
          const pagerFocused=active?.closest('[data-y3client-inventory-pages]');
          const pagerLabel=pagerFocused?active.getAttribute('aria-label'):null;
          const searchFocused=active?.parentElement===state.view&&active.hasAttribute('data-y3client-inventory-back');
          if(!api.renderInventory(summary,matrix,state.mount)){invalidate();return false;}
          for(const child of Array.from(state.view.children))if(child!==state.mount)child.remove();
          state.raw=createRawView(primary.doc,sourceTable,{...summary,productName:matrix.product.productName});state.raw.hidden=state.mode!=='table';state.mount.hidden=state.mode==='table';state.view.appendChild(state.raw);
          addPager(primary,state.view);
          installStyle(primary.doc);
          primary.doc.documentElement.setAttribute('data-y3client-inventory-primary','');
          secondary.doc.documentElement.setAttribute('data-y3client-inventory-secondary','');
          if(!state.view.isConnected)primary.doc.body.prepend(state.view);
          state.primary=primary.doc;state.secondary=secondary.doc;state.signature=signature;state.sourceTable=sourceTable;state.merged=true;
          if(rawBackFocused)state.raw.querySelector('[data-y3client-inventory-back]')?.focus({preventScroll:true});
          else if(rawLinkIndex>=0)state.raw.querySelectorAll('a')[rawLinkIndex]?.focus({preventScroll:true});
          else if(pagerLabel)Array.from(state.view.querySelectorAll('[data-y3client-inventory-pages] [aria-label]')).find(control=>control.getAttribute('aria-label')===pagerLabel)?.focus({preventScroll:true});
          else if(searchFocused)Array.from(state.view.children).find(control=>control.hasAttribute('data-y3client-inventory-back'))?.focus({preventScroll:true});
          if(!state.view.__y3TableHandler){state.view.__y3TableHandler=true;state.view.addEventListener('y3client:inventory-show-table',showTable);}
          const navigation=host.__y3ClientNavigation||(host.__y3ClientNavigation={submissionRevision:0,resultSubmissionRevision:0});
          navigation.resultSubmissionRevision=navigation.submissionRevision||0;
          state.readySubmission=navigation.resultSubmissionRevision;
          lastReadySource={submission:state.readySubmission,document:secondary.doc,table:sourceTable,signature:matrixSignature,primaryDocument:primary.doc,summaryTables:pair.summaryTables,summarySignature};
          return true;
        }catch(_){invalidate();return false;}finally{running=false;}
      }
      host.__y3ClientInventoryMerge={version:1,reconcile,showTable};
      reconcile();
      if(!host.document.querySelector('frameset')&&host.document.body){
        let pending=false;
        const observer=new host.MutationObserver(changes=>{
          if(pending||!changes.some(change=>!(change.target.nodeType===1?change.target:change.target.parentElement)?.closest(generated)))return;
          pending=true;host.setTimeout(()=>{pending=false;reconcile();},0);
        });
        observer.observe(host.document.body,{childList:true,subtree:true,characterData:true});
      }
      if(document.readyState!=='complete')window.addEventListener('load',()=>{reconcile();host.setTimeout(reconcile,0);},{once:true});
    })();
    (() => {
      'use strict';
      if(location.origin!=='https://adidas-y3.poscmcloud.jp:15505'||!/^\/scripts\/verona\/(?:print|display|dwh)\/prtz450_3_2\.asp$/i.test(location.pathname)||document.body?.tagName!=='BODY')return;
      if(window.__y3ClientAllLocations){window.__y3ClientAllLocations.reconcile();return;}
      const generated='[data-y3client-all-locations-view]';
      const clean=value=>String(value??'').replace(/\s+/g,' ').trim();
      const key=value=>clean(value).normalize('NFKC').replace(/[\s:：]/g,'');
      const node=(tag,attribute,text)=>{const result=document.createElement(tag);if(attribute)result.setAttribute(attribute,'');if(text!==undefined)result.textContent=text;return result;};
      let state={table:null,source:null,hint:null,view:null,signature:'',unit:'JP',raw:false},running=false,pending=false;
      const clear=()=>{state.view?.remove();state.source?.removeAttribute('data-y3client-all-locations-source');state.hint?.removeAttribute('data-y3client-all-locations-hint');state.hint=null;document.documentElement.removeAttribute('data-y3client-all-locations-cards');state.table=null;state.source=null;state.view=null;state.signature='';};
      const read=()=>{
        const matches=[];
        for(const table of document.querySelectorAll('table')){
          if(table.closest(generated)||table.querySelector('table')||table.rows.length<2)continue;
          const headers=Array.from(table.rows[0].cells).map(cell=>key(cell.textContent));
          if(headers.join('|')!=='品番|カラー|サイズ|商品コード|商品名|地区|店舗|TEL|上代|有効在庫数')continue;
          if(table.querySelector('input,select,button,a,textarea'))continue;
          const rows=[],totals=[];
          let valid=true,totalStarted=false;
          for(const row of Array.from(table.rows).slice(1)){
            const cells=Array.from(row.cells);
            if(cells.length===10&&cells.every(cell=>cell.colSpan===1&&cell.rowSpan===1)&&!totalStarted){rows.push(cells.map(cell=>clean(cell.textContent)));continue;}
            if(cells.length===2&&cells[0].colSpan===9&&cells[1].colSpan===1&&cells.every(cell=>cell.rowSpan===1)&&/^(合計|総計|総合計)$/.test(key(cells[0].textContent))){totalStarted=true;totals.push(cells.map(cell=>clean(cell.textContent)));continue;}
            valid=false;break;
          }
          if(valid&&rows.length)matches.push({table,headers,rows,totals});
        }
        return matches.length===1?matches[0]:null;
      };
      const style=()=>{
        if(document.getElementById('y3client-all-locations-style'))return;
        const element=node('style');element.id='y3client-all-locations-style';element.textContent=`
          [data-y3client-all-locations-view] { max-width:100%; color:#17191d; font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-all-locations-view] * { box-sizing:border-box; }
          [data-y3client-all-locations-toolbar] { display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:10px; margin:10px 0; }
          [data-y3client-all-locations-toolbar] p { margin:0; color:#68727d; font-size:12px; }
          [data-y3client-all-locations-view] button { min-height:44px; padding:8px 12px; border:1px solid #dce1e5; border-radius:9px; background:#fff; color:#17191d; font:600 12px -apple-system,BlinkMacSystemFont,sans-serif; }
          [data-y3client-all-locations-units] { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:4px; margin:12px 0; padding:4px; border-radius:11px; background:#e9ecef; }
          [data-y3client-all-locations-units] button { min-width:0; padding:8px 2px; border:0; background:transparent; }
          [data-y3client-all-locations-units] button[aria-pressed='true'] { background:#17191d; color:#fff; }
          [data-y3client-all-locations-card] { margin:12px 0; padding:16px; border:1px solid #e0e4e8; border-radius:13px; background:#fff; }
          [data-y3client-all-locations-card] h2 { margin:0 0 6px; font-size:17px; overflow-wrap:anywhere; }
          [data-y3client-all-locations-card] p { margin:3px 0; color:#69737d; font-size:12px; overflow-wrap:anywhere; }
          [data-y3client-all-locations-grid] { width:100%; table-layout:fixed; border-collapse:collapse; margin:10px 0 0; }
          [data-y3client-all-locations-grid] th,[data-y3client-all-locations-grid] td { padding:10px 4px; border:0; border-bottom:1px solid #edf0f2; background:transparent; white-space:normal; overflow-wrap:anywhere; text-align:right; }
          [data-y3client-all-locations-grid] th:first-child,[data-y3client-all-locations-grid] td:first-child { width:65%; text-align:left; }
          [data-y3client-all-locations-grid] th { color:#727b85; font-size:11px; font-weight:500; }
          [data-y3client-all-locations-grid] td:last-child { font-size:18px; font-weight:650; font-variant-numeric:tabular-nums; }
          [data-y3client-all-locations-grid] small { display:block; color:#858d96; font-size:10px; }
          [data-y3client-all-locations-card] details { margin:8px 0 0; }
          [data-y3client-all-locations-card] summary { min-height:44px; padding:12px 0; color:#63707b; font-size:12px; }
          [data-y3client-all-locations-fields] { margin:0; }
          [data-y3client-all-locations-fields] div { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,2fr); gap:8px; padding:5px 0; }
          [data-y3client-all-locations-fields] dt { color:#7b838c; font-size:11px; }
          [data-y3client-all-locations-fields] dd { margin:0; font-size:12px; overflow-wrap:anywhere; }
          [data-y3client-all-locations-total] { display:flex; justify-content:space-between; gap:8px; margin:12px 0; padding:15px; border:1px solid #dce1e5; border-radius:11px; background:#fff; font-weight:650; }
          html[data-y3client-all-locations-cards] [data-y3client-all-locations-source] { display:none!important; }
          html[data-y3client-all-locations-cards] [data-y3client-all-locations-hint] { display:none!important; }
        `;(document.head||document.documentElement).appendChild(element);
      };
      function render(data){
        const focused=document.activeElement?.closest(generated)?document.activeElement.getAttribute('data-y3client-all-locations-unit'):null;
        const api=window.__y3InventoryPresentation;
        const groups=new Map();
        for(const values of data.rows){const groupKey=JSON.stringify([values[0],values[1],values[4],values[5],values[6],values[7],values[8]]);if(!groups.has(groupKey))groups.set(groupKey,{values,rows:[]});groups.get(groupKey).rows.push(values);}
        const view=node('section','data-y3client-all-locations-view');view.setAttribute('data-y3client-inventory-view','');
        const toolbar=node('div','data-y3client-all-locations-toolbar');toolbar.appendChild(node('p',null,groups.size+'拠点・カラー / '+data.rows.length+'件'));
        const toggle=node('button','data-y3client-all-locations-table-toggle',state.raw?'サイズ別に表示':'原表で表示');toggle.type='button';toggle.addEventListener('click',()=>{state.raw=!state.raw;render(data);});toolbar.appendChild(toggle);view.appendChild(toolbar);
        const category=api.resolveCategory({}, {sizeCodes:data.rows.map(row=>row[2]),product:{productName:data.rows[0][4]}});
        if(category==='footwear'&&!state.raw){const units=node('div','data-y3client-all-locations-units');units.setAttribute('aria-label','靴サイズの単位');for(const [unit,label] of [['JP','JP'],['US','US M'],['USW','US W'],['UK','UK'],['EU','EU'],['CH','CH']]){const button=node('button',null,label);button.type='button';button.setAttribute('data-y3client-all-locations-unit',unit);button.setAttribute('aria-pressed',String(state.unit===unit));button.addEventListener('click',()=>{state.unit=unit;render(data);});units.appendChild(button);}view.appendChild(units);}
        if(!state.raw){
          for(const group of groups.values()){
            const card=node('article','data-y3client-all-locations-card');card.appendChild(node('h2',null,group.values[6]||'拠点名未設定'));
            card.appendChild(node('p',null,[group.values[5],group.values[0],group.values[4],'カラー '+group.values[1]].filter(Boolean).join(' / ')));
            const grid=node('table','data-y3client-all-locations-grid');const head=node('tr');head.append(node('th',null,'サイズ'),node('th',null,'有効在庫'));const thead=node('thead');thead.appendChild(head);grid.appendChild(thead);const body=node('tbody');
            for(const values of group.rows){const row=node('tr','data-y3client-all-locations-row');row.setAttribute('data-y3client-size-code',values[2]);row.setAttribute('data-y3client-stock-source-row',String(data.rows.indexOf(values)));const size=node('td');const formatted=api.formatSize(values[2],category,state.unit);size.appendChild(node('span',null,(formatted.unit?({'US':'US M','USW':'US W'}[formatted.unit]||formatted.unit)+' ':'')+formatted.text));size.appendChild(node('small',null,'コード '+values[2]));row.append(size,node('td','data-y3client-all-locations-quantity',values[9]||'—'));body.appendChild(row);}grid.appendChild(body);card.appendChild(grid);
            const details=node('details');details.appendChild(node('summary',null,'商品情報・連絡先を見る'));const fields=node('dl','data-y3client-all-locations-fields');
            for(const values of group.rows){for(let index=0;index<data.headers.length;index++){const line=node('div');line.append(node('dt',null,data.headers[index]),node('dd',null,values[index]));fields.appendChild(line);}}details.appendChild(fields);card.appendChild(details);view.appendChild(card);
          }
          for(const values of data.totals){const total=node('div','data-y3client-all-locations-total');total.append(node('span',null,values[0]),node('span','data-y3client-all-locations-total-quantity',values[1]||'—'));view.appendChild(total);}
        }
        state.view?.replaceWith(view);if(!view.isConnected)state.source.parentElement.insertBefore(view,state.source);state.view=view;
        document.documentElement.toggleAttribute('data-y3client-all-locations-cards',!state.raw);
        if(focused)view.querySelector('[data-y3client-all-locations-unit="'+focused+'"]')?.focus({preventScroll:true});
      }
      function reconcile(){
        if(running)return !!state.view;running=true;
        try{
          const data=read();if(!data||!window.__y3InventoryPresentation){clear();return false;}
          const signature=JSON.stringify([data.headers,data.rows,data.totals]);
          if(state.table===data.table&&state.signature===signature&&state.view?.isConnected)return true;
          if(state.table!==data.table){clear();state.raw=false;}
          state.table=data.table;state.signature=signature;state.source=data.table.closest('[data-y3client-table-scroll]')||data.table;
          state.source.setAttribute('data-y3client-all-locations-source','');if(state.source.previousElementSibling?.hasAttribute('data-y3client-result-hint')){state.hint=state.source.previousElementSibling;state.hint.setAttribute('data-y3client-all-locations-hint','');}style();render(data);return true;
        }catch(_){clear();return false;}finally{running=false;}
      }
      window.__y3ClientAllLocations={reconcile};reconcile();
      const observer=new MutationObserver(changes=>{if(pending||!changes.some(change=>!(change.target.nodeType===1?change.target:change.target.parentElement)?.closest(generated)))return;pending=true;setTimeout(()=>{pending=false;reconcile();},0);});observer.observe(document.body,{childList:true,subtree:true,characterData:true});
      if(document.readyState!=='complete')addEventListener('load',()=>{reconcile();setTimeout(reconcile,0);},{once:true});
    })();
    """#

    // Reports only integer frame paths and a structural role, never contents, URLs, or form data.
    static let discoverFrames = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window) || !document.querySelector('frameset')) return [];
      try { window.__y3ClientInventoryMerge?.reconcile(); } catch (_) {}
      try { window.__y3ClientReportMerge?.reconcile(); } catch (_) {}
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
            const exportFamily = /\/dstz(210|240|280|300|710|730)_2\.asp$/i.exec(win.location.pathname)?.[1];
            const exportSuffix = /^(710|730)$/.test(exportFamily || '') ? '_3_2' : '_2_2';
            if (exportFamily && element.name === 'dstz' + exportFamily + exportSuffix) {
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
          const body = win.document.body;
          if (!body || (!body.textContent.trim() && !body.querySelector('form,table,a,input,select,textarea,img'))) return;
          if (win.document.documentElement.hasAttribute('data-y3client-inventory-primary')) {
            panes.push({path,kind:'result',title:'在庫一覧'}); return;
          }
          if (win.document.documentElement.hasAttribute('data-y3client-inventory-secondary')) {
            panes.push({path,kind:'controls',title:'元の在庫表'}); return;
          }
          if (win.document.documentElement.hasAttribute('data-y3client-report-primary')) {
            panes.push({path,kind:'result',title:'検索結果'}); return;
          }
          if (win.document.documentElement.hasAttribute('data-y3client-report-secondary')) {
            panes.push({path,kind:'controls',title:'検索内容とページ操作'}); return;
          }
          if (win.__y3ClientIsInventoryMetadata?.()) {
            panes.push({path,kind:'controls',title:'ページ操作'}); return;
          }
          if (window.__y3ClientReportMerge?.classify?.(win) === 'metadata') {
            panes.push({path,kind:'controls',title:'検索内容とページ操作'}); return;
          }
          const controls = body.querySelector('input:not([type="hidden" i]),select,textarea,button');
          const pagerName = /^(?:PgSelect|PgMax|Page(?:No|Num|Select)?|submit[123])$/i;
          const entryFields = Array.from(body.querySelectorAll('input:not([type="hidden" i]),select,textarea')).filter(field =>
            !field.disabled && !field.readOnly && !pagerName.test(field.name || ''));
          const searchFields = entryFields.some(field => field.tagName === 'TEXTAREA' ||
            (field.tagName === 'INPUT' && /^(text|date|search|password)$/.test(field.type)));
          const conditionLeaf = condition || /\/(?:prtz|dstz)\d+_1(?:_\d+)?\.asp$/i.test(win.location.pathname);
          const generated = '[data-y3client-inventory],[data-y3client-inventory-view],[data-y3client-report-combined],[data-y3client-all-locations-view]';
          const tables = Array.from(body.querySelectorAll('table')).filter(table => !table.querySelector('table') &&
            !table.closest(generated + ',[data-y3client-menu-table],[data-y3client-search-table],[data-y3client-form-table],[data-y3client-report-summary],[data-y3client-pager-table],#ui-datepicker-div,.ui-datepicker'));
          const hasData = tables.some(table => {
            const rows = Array.from(table.rows);
            const cells = rows.flatMap(row => Array.from(row.cells));
            if (!cells.length) return false;
            if (table.hasAttribute('data-y3client-result-list') || table.hasAttribute('data-y3client-action-table')) return rows.length >= 2;
            const fields = Array.from(table.querySelectorAll('input,select,button,textarea'));
            if (fields.length && fields.every(field => pagerName.test(field.name || '') || /^(button|submit|hidden)$/.test(field.type || ''))) {
              if (rows.length <= 1) return false;
            }
            if (rows.length >= 2 && rows.some(row => row.cells.length >= 2)) return true;
            return cells.length >= 2 && (table.querySelector('input[readonly],textarea[readonly]') || /売上|在庫|合計|実績|金額|客数/.test(table.textContent));
          });
          // Report-shaped URLs also serve navigation and pager-only documents.
          // Script/style text and a URL suffix alone are never evidence of data.
          const textWalker = win.document.createTreeWalker(body, 4);
          let visibleText = '', textNode;
          while ((textNode = textWalker.nextNode()) && visibleText.length < 4000) {
            if (!textNode.parentElement?.closest('script,style,noscript,' + generated)) visibleText += ' ' + textNode.textContent;
          }
          const explicitMessage = /該当(?:する)?データ|対象(?:となる|の)?データ|データがありません|日付が不正|入力.*(?:不正|誤り)|エラー|不正操作|マスター?.*設定.*(?:ください|下さい)/.test(visibleText);
          const kind = (searchFields || (conditionLeaf && entryFields.length && body.querySelector('form'))) ? 'condition' :
            (hasData || explicitMessage) ? 'result' : controls ? 'controls' : 'navigation';
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
          const exportFamily = /\/dstz(210|240|280|300)_2\.asp$/i.exec(win.location.pathname)?.[1];
          const opaqueExport = position === path.length - 1 && exportFamily &&
            branch.name === 'dstz' + exportFamily + '_2_2';
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
      state.observer?.disconnect();
      state.observer = null;
      const revision = state.revision = (state.revision || 0) + 1;
      for (const saved of state.originals) {
        if (!saved.element.isConnected) continue;
        for (const name of ['rows', 'cols']) {
          if (saved[name] === null) saved.element.removeAttribute(name);
          else saved.element.setAttribute(name, saved[name]);
        }
      }
      state.originals = [];
      const seen = new Set();
      const focusedLayouts = [];
      for (const change of changes) {
        const element = change.element;
        if (seen.has(element)) continue;
        seen.add(element);
        state.originals.push({ element, rows: element.getAttribute('rows'), cols: element.getAttribute('cols') });
        // A FRAMESET can have both attributes: rows="115,*" cols="*" is a
        // two-row, one-column layout. Expanding both axes to the child count
        // puts the second frame in a zero-height grid cell. Preserve each
        // axis's dimensions and focus the selected child's actual grid cell.
        const dimensions = name => Math.max(1, (element.getAttribute(name) || '*').split(',').length);
        const columns = dimensions('cols');
        const rows = Math.max(dimensions('rows'), Math.ceil(change.count / columns));
        const selectedRow = Math.floor(change.selected / columns);
        const selectedColumn = change.selected % columns;
        const sizes = (count, selected) => Array.from({ length: count }, (_, index) => index === selected ? '*' : '0').join(',');
        focusedLayouts.push({ element, rows: sizes(rows, selectedRow), cols: sizes(columns, selectedColumn) });
      }
      window.__y3ClientFrameLayout = state;
      const enforce = () => {
        for (const layout of focusedLayouts) {
          if (!layout.element.isConnected) continue;
          for (const name of ['rows', 'cols']) {
            if (layout.element.getAttribute(name) !== layout[name]) layout.element.setAttribute(name, layout[name]);
          }
        }
      };
      enforce();
      if (focusedLayouts.length) {
        // Some condition pages reset their parent's rows every 200 ms for the
        // datepicker. Keep native pane focus through those writes. Disconnect
        // around our own changes, and release the guard for "show all" above.
        const observer = new MutationObserver(() => {
          if (window.__y3ClientFrameLayout !== state || state.revision !== revision) return;
          observer.disconnect();
          enforce();
          watch();
        });
        const watch = () => {
          for (const layout of focusedLayouts) if (layout.element.isConnected) {
            observer.observe(layout.element, { attributes: true, attributeFilter: ['rows', 'cols'] });
          }
        };
        state.observer = observer;
        watch();
      }
      if (focusedWindow) requestAnimationFrame(() => {
        if (window.__y3ClientFrameLayout !== state || state.revision !== revision) return;
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
