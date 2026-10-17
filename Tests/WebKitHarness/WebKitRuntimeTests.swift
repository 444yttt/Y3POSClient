import XCTest
import UIKit
import WebKit
@testable import WKRuntimeHarness

private let fixtureOrigin = "http://127.0.0.1:17865"

/// Test-only substitution. Paths, script bodies, order, injection timing and worlds stay unchanged.
private func localScript(_ source: String) -> String {
    source.replacingOccurrences(of: "https://adidas-y3.poscmcloud.jp:15505", with: fixtureOrigin)
}

@MainActor
private final class FixtureObserver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var finished = false
    var failures: [String] = []
    var scriptErrors: [String] = []

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 17865 else {
            failures.append("Rejected non-fixture navigation")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failures.append(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failures.append(error.localizedDescription)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String { scriptErrors.append(body) }
    }
}

@MainActor
private final class FixtureSession {
    let view: WKWebView
    let observer = FixtureObserver()
    private let window: UIWindow

    init(path: String, width: CGFloat = 390) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.add(observer, name: "fixtureErrors")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener('error', event => {
              window.webkit.messageHandlers.fixtureErrors.postMessage(location.pathname + ': ' + event.message);
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // The production configure() sequence: install BEFORE the first request, in page world.
        for source in [LegacySiteSupport.viewportAndTouch,
                       LegacySiteSupport.mobileRedesign,
                       LegacySiteSupport.inventoryPresentation] {
            controller.addUserScript(WKUserScript(source: localScript(source),
                injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 844), configuration: configuration)
        view.navigationDelegate = observer
        let controllerView = UIViewController()
        controllerView.view = view
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = controllerView
        window.makeKeyAndVisible()
        view.load(URLRequest(url: URL(string: fixtureOrigin + path)!))
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureErrors")
        window.isHidden = true
        window.rootViewController = nil
    }

    func waitForLoad() async throws {
        for _ in 0 ..< 400 {
            if observer.finished { return }
            if !observer.failures.isEmpty {
                throw NSError(domain: "WKFixtureNavigation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: observer.failures.joined(separator: "; ")])
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "WKFixtureNavigation", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Main-frame didFinish callback timed out"])
    }
}

final class WebKitRuntimeTests: XCTestCase {
    @MainActor
    private func eventually(_ view: WKWebView, _ expression: String,
                            diagnostics: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        var lastError = "condition was false"
        for _ in 0 ..< 400 {
            do {
                if (try await view.evaluateJavaScript(expression) as? Bool) == true { return }
            } catch { lastError = error.localizedDescription }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let diagnostics {
            if let details = try? await view.evaluateJavaScript(diagnostics) as? String {
                lastError += "; " + details
            }
        }
        XCTFail("WK condition timed out: \(lastError)", file: file, line: line)
        throw NSError(domain: "WKFixtureTimeout", code: 1)
    }

    @MainActor
    private func panes(_ view: WKWebView) async throws -> [[String: Any]] {
        try await view.evaluateJavaScript(localScript(LegacySiteSupport.discoverFrames)) as? [[String: Any]] ?? []
    }

    @MainActor
    func testDocumentEndInjectionMergesOneInventoryResultInRealWebKit() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, """
            (() => {
              const primary=frames[0]?.document, secondary=frames[1]?.document;
              return document.readyState==='complete' &&
                window.__y3ClientInventoryMerge?.version===1 &&
                primary?.documentElement.hasAttribute('data-y3client-inventory-primary') &&
                secondary?.documentElement.hasAttribute('data-y3client-inventory-secondary');
            })()
            """)
        let resultPanes = try await panes(session.view).filter { ($0["kind"] as? String) == "result" }
        XCTAssertEqual(resultPanes.count, 1, "WK must not expose metadata as another numbered result")
        XCTAssertEqual(resultPanes.first?["title"] as? String, "在庫一覧")
        let focused = try await session.view.evaluateJavaScript("(" + localScript(LegacySiteSupport.frameFocus) + ")([0])") as? Bool
        XCTAssertEqual(focused, true)
        let diagnostics = try await session.view.evaluateJavaScript("""
            (() => {
              const win=frames[0], doc=win.document, matrix=frames[1].document;
              return {
                pathname:win.location.pathname,
                cards:doc.querySelectorAll('[data-y3client-inventory]').length,
                genericCards:doc.querySelectorAll('[data-y3client-result-list]').length,
                genericStyle:!!doc.getElementById('y3client-results-style'),
                scriptAPI:win.__y3InventoryPresentation?.version,
                originalMatrix:!!matrix.getElementById('T01_H'),
                builtAtLoad:!!frames[1].fixtureGridBuilt,
                lateGrid:!!matrix.querySelector('#T01_H a'),
                width:doc.documentElement.scrollWidth,
                viewport:win.innerWidth
              };
            })()
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(diagnostics["pathname"] as? String, "/scripts/verona/print/prtz011_2_3.asp")
        XCTAssertEqual(diagnostics["cards"] as? Int, 1)
        XCTAssertEqual(diagnostics["genericCards"] as? Int, 0)
        XCTAssertEqual(diagnostics["genericStyle"] as? Bool, false)
        XCTAssertEqual(diagnostics["scriptAPI"] as? Int, 1)
        XCTAssertEqual(diagnostics["builtAtLoad"] as? Bool, true)
        XCTAssertEqual(diagnostics["originalMatrix"] as? Bool, true)
        XCTAssertEqual(diagnostics["lateGrid"] as? Bool, true)
        XCTAssertLessThanOrEqual(diagnostics["width"] as? Int ?? Int.max,
                                 (diagnostics["viewport"] as? Int ?? 0) + 1)
        XCTAssertTrue(session.observer.finished)
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            session.view.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: NSError(domain: "WKFixtureSnapshot", code: 1)) }
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Real WKWebView synthetic inventory"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFailedMergeNeverTurnsMetadataIntoGenericCardsOrNumberedResult() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp?scenario=unsupported")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, """
            document.readyState==='complete' && frames.length===2 &&
            frames[0].document.readyState==='complete' && frames[1].document.readyState==='complete' &&
            frames[0].__y3InventoryPresentation?.version===1 && frames[1].fixtureGridBuilt===true
            """)
        let records = try await panes(session.view)
        let metadata = records.first { ($0["path"] as? [Int]) == [0] }
        XCTAssertEqual(metadata?["kind"] as? String, "controls")
        XCTAssertEqual(metadata?["title"] as? String, "ページ操作")
        let forbidden = try await session.view.evaluateJavaScript("""
            frames[0].document.querySelectorAll('[data-y3client-result-list],#y3client-results-style,[data-y3client-inventory]').length
            """) as? Int
        XCTAssertEqual(forbidden, 0)
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testReportFamiliesAndReversedStructuralRolesInRealWebKit() async throws {
        for path in ["/scripts/verona/print/prtz010_2.asp",
                     "/scripts/verona/print/prtz015_2.asp",
                     "/scripts/verona/display/prtz015_2.asp",
                     "/scripts/verona/display/prtz015_2.asp?scenario=structural"] {
            let session = FixtureSession(path: path)
            defer { session.close() }
            try await session.waitForLoad()
            // The last fixture builds its grid 180ms after window.load. Wait for the actual site
            // constructor, then invoke the production discovery script just as native discovery does.
            try await eventually(session.view, """
                document.readyState==='complete' &&
                Array.from(window.frames).some(win=>win.fixtureGridBuilt===true)
                """)
            let records = try await panes(session.view)
            let results = records.filter { ($0["kind"] as? String) == "result" }
            XCTAssertEqual(results.count, 1, "Expected one structurally merged result for \(path)")
            XCTAssertEqual(results.first?["title"] as? String, "在庫一覧", path)
            let diagnostics = try await session.view.evaluateJavaScript("""
                (()=>{
                  const primary=Array.from(window.frames).find(win=>win.document.documentElement.hasAttribute('data-y3client-inventory-primary'));
                  const secondary=Array.from(window.frames).find(win=>win.document.documentElement.hasAttribute('data-y3client-inventory-secondary'));
                  if(!primary||!secondary)return {};
                  return { primaryPath:primary.location.pathname, secondaryPath:secondary.location.pathname,
                    cards:primary.document.querySelectorAll('[data-y3client-inventory]').length,
                    genericCards:primary.document.querySelectorAll('[data-y3client-result-list]').length,
                    genericStyle:!!primary.document.getElementById('y3client-results-style'),
                    api:primary.__y3InventoryPresentation?.version,
                    primaryWidth:primary.document.documentElement.scrollWidth,viewport:primary.innerWidth };
                })()
                """) as? [String: Any] ?? [:]
            let structural = path.contains("scenario=structural")
            XCTAssertTrue((diagnostics["primaryPath"] as? String)?.hasSuffix(structural ? "_2_5.asp" : "_2_3.asp") == true, path)
            XCTAssertTrue((diagnostics["secondaryPath"] as? String)?.hasSuffix(structural ? "_2_7.asp" : "_2_2.asp") == true, path)
            XCTAssertEqual(diagnostics["cards"] as? Int, 1, path)
            XCTAssertEqual(diagnostics["genericCards"] as? Int, 0, path)
            XCTAssertEqual(diagnostics["genericStyle"] as? Bool, false, path)
            XCTAssertEqual(diagnostics["api"] as? Int, 1, path)
            XCTAssertLessThanOrEqual(diagnostics["primaryWidth"] as? Int ?? Int.max,
                                     (diagnostics["viewport"] as? Int ?? 0) + 1, path)
            XCTAssertEqual(session.observer.failures, [], path)
            XCTAssertEqual(session.observer.scriptErrors, [], path)
        }
    }

    @MainActor
    func testRawViewRetainsModeAndUsesCurrentOriginalHandlersAfterTableReplacement() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "!!frames[0]?.document.querySelector('[data-y3client-inventory]')")
        let diagnostics = try await session.view.evaluateJavaScript("""
            (() => {
              const primary=frames[0].document, secondary=frames[1].document;
              primary.querySelector('[data-y3client-inventory-table-button]').click();
              primary.querySelector('[data-y3client-inventory-raw] a').click();
              const old=secondary.getElementById('T01_H'); old.replaceWith(old.cloneNode(true));
              window.__y3ClientInventoryMerge.reconcile();
              const raw=primary.querySelector('[data-y3client-inventory-raw]');
              raw.querySelector('a').click();
              const result={clicks:frames[1].fixtureLinkClicks, tableMode:!raw.hidden,
                originalStyle:secondary.getElementById('T01_H').style.position,
                copyStyle:frames[0].getComputedStyle(raw.querySelector('table')).position};
              raw.querySelector('[data-y3client-inventory-back]').click();
              result.backToCards=!primary.querySelector('[data-y3client-inventory]').closest('[hidden]');
              return result;
            })()
            """) as? [String: Any] ?? [:]
        XCTAssertEqual(diagnostics["clicks"] as? Int, 2)
        XCTAssertEqual(diagnostics["tableMode"] as? Bool, true)
        XCTAssertEqual(diagnostics["originalStyle"] as? String, "absolute")
        XCTAssertEqual(diagnostics["copyStyle"] as? String, "static")
        XCTAssertEqual(diagnostics["backToCards"] as? Bool, true)
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testPhotoGuideSizeMappingsAndUnitSwitchesPreserveMergedInventory() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "!!frames[0]?.document.querySelector('[data-y3client-inventory]')")
        let mappingsMatchGuide = try await session.view.evaluateJavaScript("""
            (() => {
              const api=frames[0].__y3InventoryPresentation;
              if(!api)return false;
              const matches=(code,category,unit,text)=>{
                const value=api.formatSize(code,category,unit);
                return value.confirmed===true && value.code===code && value.text===text;
              };
              const unconfirmed=(code,category,unit)=>{
                const value=api.formatSize(code,category,unit);
                return value.confirmed===false && value.code===code;
              };
              if(!matches('306','footwear','JP','22') || !matches('306','footwear','UK','3.5') ||
                 !matches('306','footwear','US','4') || !matches('306','footwear','USW','5') ||
                 !matches('306','footwear','EU','36'))return false;
              if(!matches('324','footwear','JP','31') || !matches('324','footwear','UK','12.5') ||
                 !matches('324','footwear','US','13') || !matches('324','footwear','EU','48') ||
                 !unconfirmed('323','footwear','USW') || !unconfirmed('324','footwear','USW'))return false;
              if(!matches('317','footwear','JP','27.5') || !matches('317','footwear','UK','9') ||
                 !matches('317','footwear','US','9.5') || !matches('317','footwear','USW','10.5'))return false;
              if(!unconfirmed('105','apparelWomen','JP') || !unconfirmed('100','apparelMen','JP') ||
                 !matches('106','apparelMen','JP','2XL') || !matches('106','apparelUnisex','JP','2XL'))return false;
              const sock=api.formatSize('608','socks');
              if(!sock.confirmed || sock.text!=='26–28cm' || sock.measurement!=='EU 43–45' ||
                 !matches('608','oneSize','JP','OSFA'))return false;
              const matrix={product:{},sizeCodes:['608']};
              return api.resolveCategory({categoryCode:'ACC',productName:'SOCKS'},matrix)==='socks' &&
                api.resolveCategory({categoryCode:'ACC',productName:'ONE SIZE'},matrix)==='oneSize' &&
                api.resolveCategory({categoryCode:'ACC',productName:'UNKNOWN'},matrix)==='' &&
                api.resolveCategory({productName:'UNKNOWN'},matrix)==='';
            })()
            """) as? Bool
        XCTAssertEqual(mappingsMatchGuide, true, "Photo guide mappings must preserve category boundaries and blank cells")
        let unitsPreserveInventory = try await session.view.evaluateJavaScript("""
            (() => {
              const doc=frames[0].document;
              const units=Array.from(doc.querySelectorAll('[data-y3client-size-unit]')).map(button=>button.getAttribute('data-y3client-size-unit'));
              if(JSON.stringify(units)!==JSON.stringify(['JP','US','USW','UK','EU','CH']))return false;
              const rows=()=>Array.from(doc.querySelectorAll('[data-y3client-inventory-size-row],[data-y3client-inventory-detail-row]'));
              const quantities=()=>JSON.stringify(rows().map(row=>[
                row.getAttribute('data-y3client-size-code'),
                ...Array.from(row.cells).slice(1).map(cell=>cell.textContent)
              ]));
              const primaryCount=doc.querySelectorAll('[data-y3client-inventory-size-row]').length;
              const detailCount=doc.querySelectorAll('[data-y3client-inventory-detail-row]').length;
              if(primaryCount!==12 || detailCount!==12)return false;
              const before=quantities();
              for(const unit of ['UK','USW']){
                doc.querySelector('[data-y3client-size-unit="'+unit+'"]').click();
                if(doc.querySelector('[data-y3client-size-unit="'+unit+'"]').getAttribute('aria-pressed')!=='true' ||
                   doc.querySelectorAll('[data-y3client-inventory-size-row]').length!==primaryCount ||
                   doc.querySelectorAll('[data-y3client-inventory-detail-row]').length!==detailCount ||
                   quantities()!==before)return false;
                const size=doc.querySelector('[data-y3client-color-code="-4-"] [data-y3client-inventory-size-row][data-y3client-size-code="317"] td');
                if(size?.firstChild?.textContent.trim()!==(unit==='UK'?'UK 9':'US W 10.5'))return false;
              }
              return true;
            })()
            """) as? Bool
        XCTAssertEqual(unitsPreserveInventory, true, "Six unit choices must preserve size rows and primary/detail quantities")
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testSameProductSubmissionWaitsForBothFrameGenerationsInEitherOrder() async throws {
        for metadataFirst in [true, false] {
            let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp")
            defer { session.close() }
            try await session.waitForLoad()
            try await eventually(session.view, "!!frames[0]?.document.querySelector('[data-y3client-inventory]')")
            let valid = try await session.view.evaluateJavaScript("""
                (()=>{
                  const primary=frames[0].document, secondary=frames[1].document;
                  const coordinator=window.__y3ClientInventoryMerge;
                  const navigation=window.__y3ClientNavigation;
                  const next=(navigation.submissionRevision||0)+1;
                  navigation.submissionRevision=next;
                  const pending=()=>coordinator.reconcile()===false &&
                    navigation.resultSubmissionRevision!==next &&
                    !primary.querySelector('[data-y3client-inventory]');
                  if(!pending())return false;
                  const replaceSummary=()=>{
                    const source=primary.getElementById('inventory-summary');
                    source.replaceWith(source.cloneNode(true));
                  };
                  const replaceMatrix=()=>{
                    const source=secondary.getElementById('T01_H');
                    source.replaceWith(source.cloneNode(true));
                  };
                  if(\(metadataFirst))replaceSummary();else replaceMatrix();
                  if(!pending())return false;
                  if(\(metadataFirst))replaceMatrix();else replaceSummary();
                  return coordinator.reconcile()===true && navigation.resultSubmissionRevision===next &&
                    primary.querySelectorAll('[data-y3client-inventory]').length===1 &&
                    primary.querySelectorAll('[data-y3client-inventory-size-row]').length===12;
                })()
                """) as? Bool
            XCTAssertEqual(valid, true, "Same-SKU identical clones must wait for both generations; metadata first: \(metadataFirst)")
            XCTAssertEqual(session.observer.failures, [])
            XCTAssertEqual(session.observer.scriptErrors, [])
        }
    }

    @MainActor
    func testInventoryUnitAndStockFilterKeepKeyboardFocusAcrossRenders() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz011_2.asp")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "!!frames[0]?.document.querySelector('[data-y3client-inventory]')")
        let focused = try await session.view.evaluateJavaScript("(" + localScript(LegacySiteSupport.frameFocus) + ")([0])") as? Bool
        XCTAssertEqual(focused, true)
        let valid = try await session.view.evaluateJavaScript("""
            (()=>{
              const doc=frames[0].document;
              const unit=doc.querySelector('[data-y3client-size-unit="UK"]');
              unit.focus();if(doc.activeElement!==unit)return false;unit.click();
              if(doc.activeElement?.getAttribute('data-y3client-size-unit')!=='UK' ||
                 doc.activeElement.getAttribute('aria-pressed')!=='true')return false;
              const filter=doc.querySelector('[data-y3client-inventory-stock-filter]');
              filter.focus();if(doc.activeElement!==filter)return false;filter.click();
              const currentFilter=doc.querySelector('[data-y3client-inventory-stock-filter]');
              if(doc.activeElement!==currentFilter || !currentFilter.checked)return false;
              const snapshot=()=>JSON.stringify(Array.from(doc.querySelectorAll('[data-y3client-inventory-size-row],[data-y3client-inventory-detail-row]')).map(row=>[
                row.getAttribute('data-y3client-size-code'),...Array.from(row.cells).slice(1).map(cell=>cell.textContent)]));
              const before=snapshot();
              const next=doc.querySelector('[data-y3client-size-unit="USW"]');next.focus();next.click();
              return doc.activeElement?.getAttribute('data-y3client-size-unit')==='USW' &&
                doc.activeElement.getAttribute('aria-pressed')==='true' &&
                doc.querySelector('[data-y3client-inventory-stock-filter]').checked &&
                doc.querySelectorAll('[data-y3client-inventory-size-row]').length===10 &&
                doc.querySelectorAll('[data-y3client-inventory-detail-row]').length===10 && snapshot()===before;
            })()
            """) as? Bool
        XCTAssertEqual(valid, true, "Rerendered unit/filter controls must retain DOM keyboard focus and filtered quantities")
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testSelectAndRadioOnlyFrameSearchIsAccessibleAndTracksRealPost() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz030_1.asp?scenario=select-radio")
        defer { session.close() }
        try await session.waitForLoad()
        let focused = try await session.view.evaluateJavaScript("(" + localScript(LegacySiteSupport.frameFocus) + ")([0])") as? Bool
        XCTAssertEqual(focused, true)
        let prepared = try await session.view.evaluateJavaScript("""
            (()=>{
              const win=frames[0], doc=win.document, form=doc.getElementById('select-radio-search');
              const store=doc.getElementById('search-store'), radio=doc.getElementById('group-product');
              const name=control=>{
                if(control.getAttribute('aria-label')?.trim())return control.getAttribute('aria-label').trim();
                const ids=(control.getAttribute('aria-labelledby')||'').split(/ +/).filter(Boolean);
                if(ids.length)return ids.map(id=>doc.getElementById(id)?.textContent.trim()||'').join(' ').trim();
                return Array.from(control.labels||[]).map(label=>label.textContent.trim()).join(' ').trim();
              };
              const describe=node=>{const rect=node.getBoundingClientRect(),style=win.getComputedStyle(node);return{
                id:node.id,tag:node.tagName,name:node.matches('input,select')?name(node):node.textContent.trim(),
                left:rect.left,right:rect.right,top:rect.top,height:rect.height,width:rect.width,
                minHeight:style.minHeight,display:style.display,form:node.form?.id};};
              window.fixtureSearchDiagnostics=JSON.stringify({viewport:win.innerWidth,frameHeight:win.innerHeight,
                documentWidth:doc.documentElement.scrollWidth,form:{id:form?.id,target:form?.target,method:form?.method},
                controls:Array.from(doc.querySelectorAll('input:not([type="hidden"]),select,label')).map(describe),
                labels:{store:name(store),product:name(radio),group:name(doc.getElementById('group-store'))}});
              if(!form || store.form!==form || radio.form!==form || form.target!=='prtz030_2' ||
                 form.method.toLowerCase()!=='post' || name(store)!=='店舗' || name(radio)!=='商品別' ||
                 name(doc.getElementById('group-store'))!=='店舗別')return false;
              return true;
            })()
            """) as? Bool
        let searchDiagnostics = (try await session.view.evaluateJavaScript("window.fixtureSearchDiagnostics || 'diagnostics unavailable'")) as? String ?? "diagnostics unavailable"
        XCTAssertEqual(prepared, true, "Select/radio ownership and accessible names must survive: \(searchDiagnostics)")
        do {
            try await eventually(session.view, """
                (()=>{
                  const win=frames[0],doc=win.document;
                  const targets=[doc.getElementById('search-store'),doc.getElementById('search-submit'),...Array.from(doc.querySelectorAll('label')).filter(label=>label.control?.type==='radio')];
                  const bounds=targets.map(node=>{const rect=node.getBoundingClientRect();return{id:node.id,left:rect.left,right:rect.right,top:rect.top,height:rect.height};});
                  window.fixtureSearchLastGeometry=JSON.stringify({viewport:win.innerWidth,frameHeight:win.innerHeight,documentWidth:doc.documentElement.scrollWidth,bounds});
                  return targets.length>=4 && bounds.every(rect=>rect.left>=0 && rect.right<=win.innerWidth+1 && rect.height>=44) && doc.documentElement.scrollWidth<=win.innerWidth+1;
                })()
                """, diagnostics: "JSON.stringify({first:window.fixtureSearchDiagnostics,last:window.fixtureSearchLastGeometry})")
        } catch { /* The recorded geometry failure must not prevent the independent original POST check. */ }
        let activated = try await session.view.evaluateJavaScript("""
            (()=>{
              const win=frames[0],doc=win.document,store=doc.getElementById('search-store'),radio=doc.getElementById('group-product');
              store.value='west';store.dispatchEvent(new win.Event('change',{bubbles:true}));radio.click();
              doc.getElementById('search-submit').click();
              return win.fixtureSelectChanges===1 && win.fixtureRadioClicks===1 && win.fixtureSearchSubmissions===1 && radio.checked;
            })()
            """) as? Bool
        XCTAssertEqual(activated, true, "Original select, radio and submit handlers must run")
        try await eventually(session.view, """
            frames[1]?.fixtureRequestMethod==='POST' && window.__y3ClientNavigation?.submissionRevision===1 &&
            window.__y3ClientNavigation?.resultSubmissionRevision===1
            """)
        let submitted = try await session.view.evaluateJavaScript("""
            frames[1].fixtureSubmittedQuery.shop_code==='west' &&
            frames[1].fixtureSubmittedQuery.group_by==='product' &&
            frames[1].fixtureSubmittedQuery.unchanged==='FICTIONAL-SEARCH-TOKEN'
            """) as? Bool
        XCTAssertEqual(submitted, true, "Original frame target, hidden query and successful POST must remain intact")
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testFrozenTableScrollsBothWaysWithoutClampingAwayFinalColumns() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz030_2_2.asp?scenario=frozen-widths")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "!!document.querySelector('#D_FIXTURE_H[data-y3client-frozen-header]') && !!document.querySelector('#D_FIXTURE_B[data-y3client-frozen-body]')")
        _ = try await session.view.evaluateJavaScript("document.getElementById('D_FIXTURE_H').scrollLeft=120; true")
        try await eventually(session.view, "document.getElementById('D_FIXTURE_B').scrollLeft===120")
        _ = try await session.view.evaluateJavaScript("document.getElementById('D_FIXTURE_B').scrollLeft=240; true")
        try await eventually(session.view, "document.getElementById('D_FIXTURE_H').scrollLeft===240")
        _ = try await session.view.evaluateJavaScript("const body=document.getElementById('D_FIXTURE_B'); body.scrollLeft=body.scrollWidth-body.clientWidth; true")
        try await eventually(session.view, """
            (()=>{const state=window.fixtureFrozenMetrics();return state.B.max>state.H.max &&
              state.B.left===state.B.max && state.H.left===state.H.max;})()
            """)
        try await Task.sleep(nanoseconds: 200_000_000)
        let preserved = try await session.view.evaluateJavaScript("""
            (()=>{
              const state=window.fixtureFrozenMetrics();
              const link=document.getElementById('frozen-product');link.click();
              return state.B.left===state.B.max &&
                window.fixtureFrozenOriginals.header===document.getElementById('FIXTURE_H') &&
                window.fixtureFrozenOriginals.body===document.getElementById('FIXTURE_B') &&
                link===window.fixtureFrozenOriginals.link && link.onclick===window.fixtureFrozenLinkHandler &&
                window.fixtureFrozenLinkClicks===1;
            })()
            """) as? Bool
        XCTAssertEqual(preserved, true, "Unequal scroll ranges must preserve the body's final columns and original nodes/handlers")
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testGenericResultPagerRemainsReadyAfterSearchAndItsOwnFramePost() async throws {
        let session = FixtureSession(path: "/scripts/verona/print/prtz030_1.asp?scenario=result-pager")
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "!!frames[1]?.document.getElementById('result-pager')")
        let searched = try await session.view.evaluateJavaScript("""
            (()=>{
              const doc=frames[0].document;
              const store=doc.getElementById('search-store');store.value='west';
              store.dispatchEvent(new frames[0].Event('change',{bubbles:true}));
              doc.getElementById('group-product').click();doc.getElementById('search-submit').click();
              return frames[0].fixtureSearchSubmissions===1;
            })()
            """) as? Bool
        XCTAssertEqual(searched, true)
        try await eventually(session.view, """
            frames[1]?.fixtureRequestMethod==='POST' && frames[1].fixtureSubmittedQuery.shop_code==='west' &&
            window.__y3ClientNavigation?.submissionRevision===1 &&
            window.__y3ClientNavigation?.resultSubmissionRevision===1
            """)
        let firstPanes = try await panes(session.view)
        XCTAssertEqual(firstPanes.first { ($0["path"] as? [Int]) == [1] }?["kind"] as? String, "result")
        // Treat the second action as a distinct user action outside the submission debounce window.
        try await Task.sleep(nanoseconds: 250_000_000)
        let paged = try await session.view.evaluateJavaScript("""
            (()=>{
              const win=frames[1], doc=win.document, form=doc.getElementById('result-pager');
              const select=doc.getElementById('result-page');
              if(select.form!==form || select.name!=='PgSelect' || form.target!=='prtz030_2' ||
                 form.method.toLowerCase()!=='post')return false;
              select.value='2';select.dispatchEvent(new win.Event('change',{bubbles:true}));
              doc.getElementById('result-page-submit').click();
              return win.fixturePagerSubmissions===1;
            })()
            """) as? Bool
        XCTAssertEqual(paged, true)
        try await eventually(session.view, """
            frames[1]?.fixtureRequestMethod==='POST' && frames[1].fixtureSubmittedQuery.PgSelect==='2' &&
            frames[1].fixtureSubmittedQuery.unchanged==='FICTIONAL-PAGER-TOKEN' &&
            window.__y3ClientNavigation?.submissionRevision===2 &&
            window.__y3ClientNavigation?.resultSubmissionRevision===2
            """)
        let result = try await session.view.evaluateJavaScript("""
            frames[1].document.getElementById('result-page').value==='2' &&
            frames[1].document.getElementById('result-page').form===frames[1].document.getElementById('result-pager')
            """) as? Bool
        XCTAssertEqual(result, true)
        let secondPanes = try await panes(session.view)
        XCTAssertEqual(secondPanes.first { ($0["path"] as? [Int]) == [1] }?["kind"] as? String, "result")
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }

    @MainActor
    func testMalformedCompoundFormKeepsParserOwnershipLayoutAndDuplicatePostValues() async throws {
        for width in [390, 320] {
            let session = FixtureSession(path: "/scripts/verona/print/prtz098_1_1.asp", width: CGFloat(width))
            defer { session.close() }
            try await session.waitForLoad()
            try await eventually(session.view, "document.querySelectorAll('[data-y3client-compound-cell]').length===2")
            let preserved = try await session.view.evaluateJavaScript("""
                (()=>{
                  const original=window.fixtureCompound, current=Array.from(original.form.elements);
                  const rect=node=>{const box=node.getBoundingClientRect(),style=getComputedStyle(node);return{
                    id:node.id,name:node.name,type:node.type,left:box.left,right:box.right,top:box.top,
                    width:box.width,height:box.height,minHeight:style.minHeight,display:style.display,
                    label:node.getAttribute('aria-label'),labelledBy:node.getAttribute('aria-labelledby')};};
                  window.fixtureCompoundDiagnostics=JSON.stringify({viewport:innerWidth,documentWidth:document.documentElement.scrollWidth,
                    nonAncestral:original.nonAncestral,currentCount:current.length,originalCount:original.controls.length,
                    methodMatch:original.form.method===original.method,targetMatch:original.form.target===original.target,actionMatch:original.form.action===original.action,
                    fields:current.map((control,index)=>{const field=original.fields[index];let parent=control.parentElement,ancestors=true;
                      for(const ancestor of original.ancestors[index]||[]){if(parent!==ancestor)ancestors=false;parent=parent?.parentElement;}
                      return{id:control.id,node:control===original.controls[index],owner:control.form===field?.form,
                        name:control.name===field?.name,type:control.type===field?.type,value:control.value===field?.value,
                        click:control.onclick===field?.onclick,change:control.onchange===field?.onchange,ancestors};}),
                    labels:document.querySelectorAll('[data-y3client-compound-label]').length,
                    controls:current.filter(control=>control.type!=='hidden').map(rect),
                    calendarMatch:original.calendar===document.getElementById('ui-datepicker-div')&&original.calendar.outerHTML===original.calendarHTML});
                  if(!original.nonAncestral || current.length!==24 || current.length!==original.controls.length ||
                     original.form.method!==original.method || original.form.target!==original.target ||
                     original.form.action!==original.action)return false;
                  if(!current.every((control,index)=>{
                    const field=original.fields[index];
                    if(control!==original.controls[index] || control!==field.field || control.form!==field.form ||
                       control.name!==field.name || control.type!==field.type || control.value!==field.value ||
                       control.onclick!==field.onclick || control.onchange!==field.onchange)return false;
                    let parent=control.parentElement;
                    for(const ancestor of original.ancestors[index]){if(parent!==ancestor)return false;parent=parent.parentElement;}
                    return true;
                  }))return false;
                  const label=id=>{
                    const control=document.getElementById(id);
                    return control.getAttribute('aria-label') || (control.getAttribute('aria-labelledby')||'').split(' ').filter(Boolean).map(key=>document.getElementById(key)?.textContent.trim()||'').join(' ');
                  };
                  if(label('fixture-date-start')!=='架空期間 開始日' || label('fixture-date-end')!=='架空期間 終了日' ||
                     label('fixture-code-3')!=='架空分類 3' || document.querySelectorAll('[data-y3client-compound-label]').length!==6)return false;
                  return original.calendar===document.getElementById('ui-datepicker-div') &&
                    original.calendar.outerHTML===original.calendarHTML &&
                    !original.calendar.querySelector('[data-y3client-result-list],[data-y3client-result-tools],[data-y3client-table-scroll]');
                })()
                """) as? Bool
            let compoundDiagnostics = (try await session.view.evaluateJavaScript("window.fixtureCompoundDiagnostics || 'diagnostics unavailable'")) as? String ?? "diagnostics unavailable"
            XCTAssertEqual(preserved, true, "Malformed FORM ownership, names, values and calendar must survive at \(width)px: \(compoundDiagnostics)")
            do {
                try await eventually(session.view, """
                    (()=>{
                      const box=node=>node.getBoundingClientRect();
                      const controls=Array.from(document.querySelectorAll('#fixture-compound-table input:not([type="hidden"]),#fixture-compound-table select'));
                      const bounds=controls.map(node=>{const rect=box(node);return{id:node.id,name:node.name,left:rect.left,right:rect.right,top:rect.top,height:rect.height};});
                      window.fixtureCompoundLastGeometry=JSON.stringify({viewport:innerWidth,documentWidth:document.documentElement.scrollWidth,bounds});
                      const dates=['fixture-date-start','fixture-date-end'].map(id=>box(document.getElementById(id)));
                      if(Math.abs(dates[0].top-dates[1].top)>1 || dates[0].right>dates[1].left)return false;
                      for(const name of ['fixtureSub','fixtureCode']){
                        const boxes=Array.from(document.querySelectorAll('input[name="'+name+'"]')).map(box);
                        if(boxes.length!==5 || boxes.some(rect=>Math.abs(rect.top-boxes[0].top)>1))return false;
                      }
                      return bounds.every(rect=>rect.left>=0 && rect.right<=innerWidth+1 && rect.height>=44) && document.documentElement.scrollWidth<=innerWidth+1;
                    })()
                    """, diagnostics: "JSON.stringify({first:window.fixtureCompoundDiagnostics,last:window.fixtureCompoundLastGeometry})")
            } catch { /* The recorded geometry failure must not prevent the independent original POST check. */ }
            let submitted = try await session.view.evaluateJavaScript("""
                (()=>{
                  for(const id of ['fixture-brand-help','fixture-sub-help','fixture-code-help'])document.getElementById(id).click();
                  const season=document.getElementById('fixture-season');season.value='fictional-b';
                  season.dispatchEvent(new Event('change',{bubbles:true}));
                  document.getElementById('fixture-sub-3').value='B3';document.getElementById('fixture-code-3').value='Z3';
                  if(JSON.stringify(window.fixtureHelperCalls)!==JSON.stringify(['brand','sub','code']) ||
                     window.fixtureSeasonChanges!==1 || !season.options[2].disabled)return false;
                  document.getElementById('fixture-search').click();
                  return window.fixtureSubmitCalls===1 && document.forms.fixtureSearch.target==='fixtureResult';
                })()
                """) as? Bool
            XCTAssertEqual(submitted, true)
            try await eventually(session.view, "frames[0]?.fixtureRequestMethod==='POST'")
            let posted = try await session.view.evaluateJavaScript("""
                (()=>{
                  const arrays=frames[0].fixtureSubmittedArrays, values=frames[0].fixtureSubmittedQuery;
                  return JSON.stringify(arrays.fixtureSub)===JSON.stringify(['A1','A2','B3','A4','A5']) &&
                    JSON.stringify(arrays.fixtureCode)===JSON.stringify(['Q1','Q2','Z3','Q4','Q5']) &&
                    values.fixture_token==='fictional-unchanged' && values.fixture_brand_state==='synthetic-brand' &&
                    values.fixture_sub_state==='synthetic-sub' && values.fixture_code_state==='synthetic-code' &&
                    values.fixtureYYYYMMDD_F==='20261001' && values.fixtureYYYYMMDD_T==='20261003' &&
                    values.fixtureSeason==='fictional-b';
                })()
                """) as? Bool
            XCTAssertEqual(posted, true, "Every original slot and hidden value must reach the original frame POST at \(width)px")
            XCTAssertEqual(session.observer.failures, [])
            XCTAssertEqual(session.observer.scriptErrors, [])
        }
    }

    @MainActor
    func testInteractiveReportsScrollInPlaceWithoutBreakingRowFormPosts() async throws {
        for (scenario, buttonID) in [("", "basic-button-a"), ("nested", "nested-button-a"),
                                      ("frozen-clone", "action-body-button-a"), ("frozen-header", "plain-body-button-a")] {
            let path = "/scripts/verona/print/prtz098_4.asp" + (scenario.isEmpty ? "" : "?scenario=" + scenario)
            let session = FixtureSession(path: path, width: 320)
            defer { session.close() }
            try await session.waitForLoad()
            try await eventually(session.view, "!!document.querySelector('table[data-y3client-action-table][data-y3client-table-scroll]')")
            let preserved = try await session.view.evaluateJavaScript("""
                (()=>{
                  const original=window.fixtureAction, tables=Array.from(document.querySelectorAll('table'));
                  const forms=Array.from(document.forms), controls=Array.from(document.querySelectorAll('input,select,textarea,button'));
                  if(tables.length!==original.tables.length || !tables.every((node,index)=>node===original.tables[index]) ||
                     forms.length!==original.forms.length || !forms.every((node,index)=>node===original.forms[index]) ||
                     controls.length!==original.controls.length)return false;
                  if(!controls.every((control,index)=>{
                    const field=original.fields[index];
                    if(control!==original.controls[index] || control.form!==field.form || control.name!==field.name ||
                       control.type!==field.type || control.value!==field.value || control.onclick!==field.onclick ||
                       control.onchange!==field.onchange)return false;
                    let parent=control.parentElement;
                    for(const ancestor of original.ancestors[index]){if(parent!==ancestor)return false;parent=parent.parentElement;}
                    return true;
                  }))return false;
                  const button=document.getElementById('\(buttonID)'), table=button.closest('table');
                  const rect=table.getBoundingClientRect(), style=getComputedStyle(table);
                  if(!table.hasAttribute('data-y3client-action-table') || !table.hasAttribute('data-y3client-table-scroll') ||
                     !['auto','scroll'].includes(style.overflowX) || table.scrollWidth<=table.clientWidth ||
                     rect.left<0 || rect.right>innerWidth+1 || document.documentElement.scrollWidth>innerWidth+1 ||
                     !button.form || button.form.target!=='sink' || button.form.method.toLowerCase()!=='post')return false;
                  table.scrollLeft=table.scrollWidth-table.clientWidth;
                  if(table.scrollLeft<=0)return false;
                  button.click();return window.fixtureClicks===1;
                })()
                """) as? Bool
            XCTAssertEqual(preserved, true, "Interactive report must scroll without moving its row-form nodes: \(scenario)")
            try await eventually(session.view, "frames[0]?.fixtureRequestMethod==='POST'")
            let posted = try await session.view.evaluateJavaScript("""
                JSON.stringify(frames[0].fixtureSubmittedArrays.fx_repeat)===JSON.stringify(['fictional-a1','fictional-a2'])
                """) as? Bool
            XCTAssertEqual(posted, true, "Original row form must POST both duplicate fields: \(scenario)")
            XCTAssertEqual(session.observer.failures, [])
            XCTAssertEqual(session.observer.scriptErrors, [])
        }
        let picker = FixtureSession(path: "/scripts/verona/print/prtz098_7.asp?scenario=checkbox-picker", width: 320)
        defer { picker.close() }
        try await picker.waitForLoad()
        try await eventually(picker.view, "!!frames[0]?.document.querySelector('table[data-y3client-selection-table][data-y3client-action-table]')")
        let pickerPanes = try await panes(picker.view)
        XCTAssertEqual(pickerPanes.first { ($0["path"] as? [Int]) == [0] }?["kind"] as? String, "result")
        let selected = try await picker.view.evaluateJavaScript("""
            (()=>{
              const win=frames[0], doc=win.document, original=win.fixtureAction;
              const table=doc.getElementById('fixture-selection-table'), form=doc.getElementById('fixture-selection-form');
              const controls=Array.from(doc.querySelectorAll('input,select,textarea,button'));
              if(controls.length!==original.controls.length || !controls.every((control,index)=>{
                const field=original.fields[index];
                if(control!==original.controls[index] || control.form!==field.form || control.name!==field.name ||
                   control.value!==field.value || control.onclick!==field.onclick || control.onchange!==field.onchange)return false;
                let parent=control.parentElement;
                for(const ancestor of original.ancestors[index]){if(parent!==ancestor)return false;parent=parent.parentElement;}
                return true;
              }))return false;
              const rect=table.getBoundingClientRect(), style=win.getComputedStyle(table);
              if(!['auto','scroll'].includes(style.overflowX) || table.scrollWidth<=table.clientWidth ||
                 rect.left<0 || rect.right>win.innerWidth+1 || doc.documentElement.scrollWidth>win.innerWidth+1 ||
                 win.getComputedStyle(doc.getElementById('elements-limit')).position!=='static')return false;
              const choices=Array.from(doc.querySelectorAll('input[name="fixture_codes"]'));
              if(choices.length!==24 || choices.some(control=>{
                const label=control.getAttribute('aria-label') || Array.from(control.labels||[]).map(node=>node.textContent.trim()).join(' ');
                return control.form!==form || !label.includes(control.value) || control.getBoundingClientRect().height<44;
              }))return false;
              for(const choice of choices.slice(0,6))choice.click();
              doc.getElementById('fixture-picker-register').click();
              if(win.fixtureSelectionChanges!==6 || win.fixtureSubmitAttempts!==1 || win.fixtureLimitRejections!==1 ||
                 (win.fixtureAcceptedSubmissions||0)!==0 || !doc.getElementById('fixture-selection-status').textContent.includes('5件まで'))return false;
              choices[5].click();doc.getElementById('fixture-picker-back').click();
              if(win.fixtureBackCalls!==1 || doc.getElementById('fixture-remaining').textContent!=='0')return false;
              doc.getElementById('fixture-picker-register').click();
              return win.fixtureAcceptedSubmissions===1 && win.fixtureSubmitAttempts===2 &&
                form.target==='fixtureSelectionResult';
            })()
            """) as? Bool
        XCTAssertEqual(selected, true, "The _8 checkbox picker must retain row labels, bounded layout and its original five-item limit")
        try await eventually(picker.view, "frames[0]?.frames[0]?.fixtureRequestMethod==='POST'")
        let pickerPosted = try await picker.view.evaluateJavaScript("""
            JSON.stringify(frames[0].frames[0].fixtureSubmittedArrays.fixture_codes)===JSON.stringify(['FX01','FX02','FX03','FX04','FX05']) &&
            JSON.stringify(frames[0].frames[0].fixtureSubmittedArrays.fixture_token)===JSON.stringify(['fictional-picker-token-a','fictional-picker-token-b'])
            """) as? Bool
        XCTAssertEqual(pickerPosted, true, "The original picker target must receive all five selections and both hidden tokens")
        XCTAssertEqual(picker.observer.failures, [])
        XCTAssertEqual(picker.observer.scriptErrors, [])
    }

    @MainActor
    func testIsolatedStaffArgumentsStayInMatchingMainDocumentWithoutSubmit() async throws {
        let path = "/verona/data/cmtz030.asp?r_shop_code=FICTIONAL&r_shop_pw=FICTIONAL&r_pos_no=0"
        let session = FixtureSession(path: path)
        defer { session.close() }
        try await session.waitForLoad()
        try await eventually(session.view, "document.readyState==='complete' && !!document.forms.namedItem('login')")
        let filled = try await session.view.callAsyncJavaScript(localScript(LegacySiteSupport.staffCredentialAutofill),
            arguments: ["staffID": "FICTIONAL-STAFF", "password": "FICTIONAL-PASSWORD", "documentURL": fixtureOrigin + path],
            in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(filled, true)
        let valid = try await session.view.evaluateJavaScript("""
            document.querySelector('[name=tanto_id]').value==='FICTIONAL-STAFF' &&
            document.querySelector('[name=tanto_pw]').value==='FICTIONAL-PASSWORD' &&
            window.fixtureLoginPosts===0
            """) as? Bool
        XCTAssertEqual(valid, true)
        XCTAssertEqual(session.observer.failures, [])
        XCTAssertEqual(session.observer.scriptErrors, [])
    }
}
