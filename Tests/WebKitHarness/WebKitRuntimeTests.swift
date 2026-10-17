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

    init(path: String) {
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
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.navigationDelegate = observer
        let controllerView = UIViewController()
        controllerView.view = view
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        var lastError = "condition was false"
        for _ in 0 ..< 400 {
            do {
                if (try await view.evaluateJavaScript(expression) as? Bool) == true { return }
            } catch { lastError = error.localizedDescription }
            try await Task.sleep(nanoseconds: 50_000_000)
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
