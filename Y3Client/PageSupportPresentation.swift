import Foundation

/// Keeps support attached to source documents that build or replace their HTML after load.
enum PageSupportPresentation {
    static let messageName = "y3PageStructureChanged"

    // Compile the existing renderers into the user script. No eval, remote script, or data bridge.
    static var bootstrap: String {
        template.replacingOccurrences(of: "/*__Y3_RENDER_SOURCES__*/", with: [
            LegacySiteSupport.viewportAndTouch,
            LegacySiteSupport.mobileRedesign,
            LegacySiteSupport.inventoryPresentation,
            ReportPresentation.script
        ].map { "try {\n" + $0 + "\n} catch (_) {}" }.joined(separator: "\n"))
    }

    private static let template = #"""
    (() => {
      if (location.origin !== 'https://adidas-y3.poscmcloud.jp:15505') return;
      if (window.__y3ClientPageSupport) return;
      const generated = '[data-y3client-inventory],[data-y3client-inventory-view],[data-y3client-report-combined],[data-y3client-all-locations-view],[data-y3client-result-tools],#ui-datepicker-div,.ui-datepicker,[role="dialog"],[role="grid"]';
      const ids = new WeakMap(); let nextID = 0, timer = null, last = null, running = false;
      const identity = node => { if (!ids.has(node)) ids.set(node, ++nextID); return ids.get(node); };
      const source = node => !node.closest(generated);
      // Identities, dimensions and populated-cell counts describe readiness without retaining values.
      const structure = () => {
        if (!document.documentElement) return '';
        const tables = Array.from(document.querySelectorAll('table')).filter(source).map(table => {
          const cells = Array.from(table.rows).flatMap(row => Array.from(row.cells));
          return [identity(table), table.rows.length, cells.length, cells.filter(cell => !!cell.textContent.trim()).length].join(':');
        });
        const forms = Array.from(document.forms).filter(source).map(form => identity(form) + ':' + form.elements.length);
        const frames = Array.from(document.querySelectorAll('frame,iframe')).filter(source).map(identity);
        return [identity(document.documentElement), tables.join(','), forms.join(','), frames.join(',')].join('|');
      };
      const restore = () => {
        /*__Y3_RENDER_SOURCES__*/
      };
      const reconcile = () => {
        timer = null;
        if (running || !document.documentElement || document.readyState === 'loading') return;
        const before = structure();
        const body = document.body;
        const missing = body && body.tagName === 'BODY' && (!document.documentElement.hasAttribute('data-y3client-phone') || !document.documentElement.hasAttribute('data-y3client-layout') || !document.getElementById('y3client-touch-style') || !document.getElementById('y3client-layout-base'));
        if (before === last && !missing) return;
        running = true;
        try { restore(); } catch (_) { /* Preserve the original page if a renderer cannot adapt it. */ }
        last = structure();
        running = false;
        try { window.webkit.messageHandlers.y3PageStructureChanged.postMessage(true); } catch (_) {}
      };
      const schedule = () => {
        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(reconcile, 100);
      };
      // Observe Document itself: legacy document.open()/write() can replace its entire HTML root.
      // Source rows/cols/style timers and client-generated views do not restart native discovery.
      const observer = new MutationObserver(records => {
        const relevant = records.some(record => {
          const target = record.target.nodeType === 1 ? record.target : record.target.parentElement;
          if (target?.closest(generated)) return false;
          return Array.from(record.addedNodes).concat(Array.from(record.removedNodes)).some(node =>
            node.nodeType !== 1 || !node.matches(generated));
        });
        if (relevant) schedule();
      });
      observer.observe(document, { childList: true, subtree: true });
      window.__y3ClientPageSupport = { observer };
      document.addEventListener('DOMContentLoaded', schedule);
      window.addEventListener('load', schedule);
      schedule();
    })();
    """#
}
