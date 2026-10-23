import XCTest
import UIKit
import WebKit
@testable import WKRuntimeHarness

private let nativeFixtureOrigin = "http://127.0.0.1:17865"

@MainActor
private final class NativeFixtureMessages: NSObject, WKScriptMessageHandler {
    var errors: [String] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? String { errors.append(body) }
    }
}

@MainActor
private final class NativeBrowserSession {
    let browser = BrowserModel()
    let messages = NativeFixtureMessages()
    private let window: UIWindow

    init(path: String, width: CGFloat = 390) {
        // Do not call start(): this fixture never reads or changes saved login
        // details. Native configuration and navigation delegates remain intact.
        let controller = browser.webView.configuration.userContentController
        controller.add(messages, name: "nativeFixtureErrors")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener('error', event => {
              window.webkit.messageHandlers.nativeFixtureErrors.postMessage(location.pathname + ': ' + event.message);
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let root = UIViewController()
        root.view = browser.webView
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        browser.webView.load(URLRequest(url: URL(string: nativeFixtureOrigin + path)!))
    }

    func close() {
        browser.webView.stopLoading()
        browser.webView.navigationDelegate = nil
        browser.webView.uiDelegate = nil
        browser.webView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeFixtureErrors")
        window.isHidden = true
        window.rootViewController = nil
    }
}

final class NativeBrowserRuntimeTests: XCTestCase {
    @MainActor
    private func eventually(_ session: NativeBrowserSession,
                            _ condition: @MainActor () async throws -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        var last = "condition was false"
        for _ in 0 ..< 400 {
            do { if try await condition() { return } }
            catch { last = error.localizedDescription }
            if let failure = session.browser.failure { last = failure.message }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let panes = session.browser.framePanes.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: ",")
        XCTFail("Native BrowserModel condition timed out: \(last); selected=\(session.browser.selectedFramePaneID ?? "nil"); panes=\(panes)", file: file, line: line)
        throw NSError(domain: "NativeBrowserFixture", code: 1)
    }

    @MainActor
    func testNativeAllLocationsSearchAndDetailUseReadableDataAndPreserveStock() async throws {
        let session = NativeBrowserSession(path: "/scripts/verona/print/prtz450_1.asp")
        defer { session.close() }
        try await eventually(session, {
            session.browser.framePanes.first(where: { $0.kind == .condition })?.id == session.browser.selectedFramePaneID
                && session.browser.selectedFramePaneID != nil
        })
        _ = try await session.browser.webView.evaluateJavaScript("""
            (()=>{const doc=frames[1].document;doc.querySelector('input[name=ft_goods_code]').value='MOCK-ALL001';doc.querySelector('input[name=ken]').click();})()
            """)
        try await eventually(session, {
            guard session.browser.webView.url?.path == "/scripts/verona/print/prtz450_2.asp",
                  session.browser.selectedFramePaneID == "2" else { return false }
            return try await session.browser.webView.evaluateJavaScript("""
                (()=>{const win=frames[2];return win.innerHeight>=800&&win.document.getElementById('all-location-products')?.getBoundingClientRect().height>0;})()
                """) as? Bool == true
        })
        let search = try await session.browser.webView.evaluateJavaScript("frames[2].fixtureAllSearchFields") as? [String: [String]] ?? [:]
        XCTAssertEqual(search["unchanged"], ["FICTIONAL-SEARCH-TOKEN"])
        XCTAssertEqual(search["ft_goods_code"], ["MOCK-ALL001"])
        let detailFormUnchanged = try await session.browser.webView.evaluateJavaScript("frames[2].fixtureOriginalDetailForm===frames[2].document.getElementById('all-location-detail')") as? Bool
        XCTAssertEqual(detailFormUnchanged, true)
        _ = try await session.browser.webView.evaluateJavaScript("frames[2].document.querySelector('#all-location-detail input[type=submit]').click()")
        try await eventually(session, {
            guard session.browser.webView.url?.path == "/scripts/verona/print/prtz450_3.asp",
                  session.browser.selectedFramePaneID == "2" else { return false }
            return try await session.browser.webView.evaluateJavaScript("""
                (()=>{const win=frames[2],view=win.document.querySelector('[data-y3client-all-locations-view]');return win.innerHeight>=800&&view?.getBoundingClientRect().height>0;})()
                """) as? Bool == true
        })
        let detail = try await session.browser.webView.evaluateJavaScript("frames[2].fixtureAllDetailFields") as? [String: [String]] ?? [:]
        XCTAssertEqual(detail["unchanged"], ["FICTIONAL-DETAIL-TOKEN"])
        XCTAssertEqual(detail["product"], ["MOCK-ALL001"])
        let source = try await session.browser.webView.evaluateJavaScript("JSON.stringify(frames[2].fixtureStockData())") as? String
        XCTAssertNotNil(source)
        for (unit, expected) in [("JP", "25.5"), ("US", "7.5"), ("USW", "8.5"), ("UK", "7"), ("EU", "40 2/3"), ("CH", "250")] {
            let changed = try await session.browser.webView.evaluateJavaScript("""
                (()=>{const win=frames[2],doc=win.document;doc.querySelector('[data-y3client-all-locations-unit="\(unit)"]').click();
                  const row=doc.querySelector('[data-y3client-all-locations-row][data-y3client-size-code="313"]');
                  return row.cells[0].textContent.includes('\(expected)');})()
                """) as? Bool
            XCTAssertEqual(changed, true, unit)
            let current = try await session.browser.webView.evaluateJavaScript("JSON.stringify(frames[2].fixtureStockData())") as? String
            XCTAssertEqual(current, source, "Switching units preserves every original stock cell")
            let quantities = try await session.browser.webView.evaluateJavaScript("Array.from(frames[2].document.querySelectorAll('[data-y3client-all-locations-quantity]')).map(cell=>cell.textContent)") as? [String]
            XCTAssertEqual(quantities, ["1", "0", "-1", "—"], unit)
            let total = try await session.browser.webView.evaluateJavaScript("frames[2].document.querySelector('[data-y3client-all-locations-total-quantity]').textContent") as? String
            XCTAssertEqual(total, "006", "The original total is preserved, not recalculated")
        }
        _ = try await session.browser.webView.evaluateJavaScript("frames[2].document.querySelector('[data-y3client-all-locations-table-toggle]').click()")
        let originalVisible = try await session.browser.webView.evaluateJavaScript("""
            (()=>{const win=frames[2],table=win.document.getElementById('all-location-stock');return table===win.fixtureOriginalStock&&table.isConnected&&table.getBoundingClientRect().height>0&&table.textContent===win.fixtureOriginalStockText;})()
            """) as? Bool
        XCTAssertEqual(originalVisible, true, "The raw view uses the same original source table")
        _ = try await session.browser.webView.evaluateJavaScript("frames[2].document.querySelector('input[name=back]').click()")
        try await eventually(session, {
            guard session.browser.webView.url?.path == "/scripts/verona/print/prtz450_2.asp",
                  session.browser.selectedFramePaneID == "2" else { return false }
            return try await session.browser.webView.evaluateJavaScript("frames[2].innerHeight>=800&&frames[2].document.getElementById('all-location-products').getBoundingClientRect().height>0") as? Bool == true
        })
        XCTAssertNil(session.browser.failure)
        XCTAssertFalse(session.browser.hasSavedConnection)
        XCTAssertEqual(session.messages.errors, [])
    }

    @MainActor
    func testNativeSearchSelectsReadableDailyResultsAndSwitchesEveryNestedPane() async throws {
        let session = NativeBrowserSession(path: "/scripts/verona/print/prtz030_1.asp?scenario=native-browser")
        defer { session.close() }
        try await eventually(session, {
            session.browser.framePanes.contains { $0.kind == .condition } &&
                session.browser.selectedFramePaneID == session.browser.framePanes.first { $0.kind == .condition }?.id
        })
        let conditionHeight = try await session.browser.webView.evaluateJavaScript("frames[0].innerHeight") as? Double ?? 0
        XCTAssertGreaterThan(conditionHeight, 700, "The actual native controller must first focus the condition document")
        _ = try await session.browser.webView.evaluateJavaScript("frames[0].document.querySelector('input[name=ken]').click()")
        try await eventually(session, {
            guard let selected = session.browser.framePanes.first(where: { $0.id == session.browser.selectedFramePaneID }),
                  selected.kind == .result else { return false }
            return try await session.browser.webView.evaluateJavaScript("""
                (()=>{const result=frames['prtz030_2'];return result?.fixtureNativeRequest?.method==='POST'&&result.frames[0]?.fixtureNativeDataReady===true;})()
                """) as? Bool == true
        })
        let request = try await session.browser.webView.evaluateJavaScript("frames['prtz030_2'].fixtureNativeRequest") as? [String: Any] ?? [:]
        XCTAssertEqual(request["method"] as? String, "POST")
        let fields = request["values"] as? [String: [String]] ?? [:]
        XCTAssertEqual(fields["unchanged"], ["FICTIONAL-NATIVE-SEARCH"])
        XCTAssertEqual(fields["ft_YYYYMMDD_F"], ["20261018"])
        XCTAssertEqual(fields["ft_YYYYMMDD_T"], ["20261018"])
        let results = session.browser.framePanes.filter { $0.kind == .result }
        XCTAssertEqual(results.count, 3, "All three daily report documents remain accessible")
        for pane in results {
            session.browser.focusFramePane(pane)
            let expression = pane.path.reduce("window") { "\($0).frames[\($1)]" }
            try await eventually(session, {
                guard session.browser.selectedFramePaneID == pane.id else { return false }
                return try await session.browser.webView.evaluateJavaScript("""
                    (()=>{const target=\(expression);return target.innerHeight>=800&&target.document.querySelectorAll('[data-fixture-daily] tr').length>=2&&frames[0].frameElement.getBoundingClientRect().height<1;})()
                    """) as? Bool == true
            })
            try await Task.sleep(nanoseconds: 650_000_000)
            let stable = try await session.browser.webView.evaluateJavaScript("""
                (()=>{const target=\(expression);return target.innerHeight>=800&&frames[0].frameElement.getBoundingClientRect().height<1&&frames[0].fixtureNativeResizeTicks>=3;})()
                """) as? Bool
            XCTAssertEqual(stable, true, "The site's repeated frame resize must not hide or shrink the selected result")
        }
        session.browser.focusConditions()
        try await eventually(session, {
            guard session.browser.framePanes.first(where: { $0.kind == .condition })?.id == session.browser.selectedFramePaneID else { return false }
            return try await session.browser.webView.evaluateJavaScript("frames[0].innerHeight>=800") as? Bool == true
        })
        _ = try await session.browser.webView.evaluateJavaScript("frames[0].document.getElementById('ui-datepicker-div').style.display='block'")
        try await Task.sleep(nanoseconds: 650_000_000)
        let calendarFocusStable = try await session.browser.webView.evaluateJavaScript("frames[0].innerHeight>=800") as? Bool
        XCTAssertEqual(calendarFocusStable, true, "The source calendar timer must preserve the native condition pane focus")
        _ = try await session.browser.webView.evaluateJavaScript("frames[0].document.getElementById('ui-datepicker-div').style.display='none'")
        session.browser.focusResults()
        try await eventually(session, {
            guard session.browser.framePanes.first(where: { $0.kind == .result })?.id == session.browser.selectedFramePaneID else { return false }
            return try await session.browser.webView.evaluateJavaScript("frames['prtz030_2'].frames[0].innerHeight>=800") as? Bool == true
        })
        _ = try await session.browser.webView.evaluateJavaScript("frames[0].document.getElementById('ui-datepicker-div').style.display='block'")
        session.browser.focusFramePane(nil)
        try await eventually(session, {
            guard session.browser.selectedFramePaneID == nil else { return false }
            return try await session.browser.webView.evaluateJavaScript("document.getElementById('prtz030_frameset').rows==='350,*'&&frames[0].innerHeight>=300&&frames[0].innerHeight<500") as? Bool == true
        })
        XCTAssertNil(session.browser.failure)
        XCTAssertFalse(session.browser.hasSavedConnection)
        XCTAssertEqual(session.messages.errors, [])
    }

    @MainActor
    func testNativeResultSelectionSkipsNavigationAndPagerAndKeepsReadOnlyOutputReadable() async throws {
        let session = NativeBrowserSession(path: "/scripts/verona/print/prtz094_2.asp?scenario=pane-roles")
        defer { session.close() }
        try await eventually(session, {
            guard session.browser.selectedFramePaneID == "2" else { return false }
            return try await session.browser.webView.evaluateJavaScript("frames[2].innerHeight>=800&&frames[2].document.getElementById('role-real-data').getBoundingClientRect().height>0") as? Bool == true
        })
        XCTAssertEqual(session.browser.framePanes.first(where: { $0.id == "0" })?.kind, .navigation)
        XCTAssertEqual(session.browser.framePanes.first(where: { $0.id == "1" })?.kind, .controls)
        XCTAssertEqual(session.browser.framePanes.first(where: { $0.id == "2" })?.kind, .result)
        XCTAssertEqual(session.browser.framePanes.first(where: { $0.id == "3" })?.kind, .result)
        XCTAssertFalse(session.browser.framePanes.contains { $0.kind == .condition }, "Read-only report output is not a search field")
        let readOnlyOutput = try await session.browser.webView.evaluateJavaScript("frames[2].document.querySelector('input[name=reported_value]').readOnly&&frames[2].document.querySelector('input[name=reported_value]').value==='FICTIONAL'") as? Bool
        XCTAssertEqual(readOnlyOutput, true)
        let aggregate = try XCTUnwrap(session.browser.framePanes.first(where: { $0.id == "3" }))
        session.browser.focusFramePane(aggregate)
        try await eventually(session, {
            guard session.browser.selectedFramePaneID == "3" else { return false }
            return try await session.browser.webView.evaluateJavaScript("frames[3].innerHeight>=800&&frames[3].document.getElementById('role-real-aggregate').rows.length===5") as? Bool == true
        })
        session.browser.focusResults()
        try await eventually(session, { session.browser.selectedFramePaneID == "2" })
        XCTAssertNil(session.browser.failure)
        XCTAssertEqual(session.messages.errors, [])

        let empty = NativeBrowserSession(path: "/scripts/verona/print/prtz094_1.asp?scenario=pane-roles", width: 320)
        defer { empty.close() }
        try await eventually(empty, {
            guard empty.browser.selectedFramePaneID == "1",
                  empty.browser.framePanes.first(where: { $0.id == "1" })?.kind == .result else { return false }
            return try await empty.browser.webView.evaluateJavaScript("frames[1].innerHeight>=800&&frames[1].document.getElementById('role-no-data').getBoundingClientRect().height>0") as? Bool == true
        })
        XCTAssertEqual(empty.browser.framePanes.first(where: { $0.id == "0" })?.kind, .navigation)
        XCTAssertNil(empty.browser.failure)
        XCTAssertEqual(empty.messages.errors, [])

        let action = NativeBrowserSession(path: "/scripts/verona/print/dstz100_3.asp?scenario=pane-roles", width: 320)
        defer { action.close() }
        try await eventually(action, {
            guard action.browser.selectedFramePaneID == "1",
                  action.browser.framePanes.first(where: { $0.id == "1" })?.kind == .result else { return false }
            return try await action.browser.webView.evaluateJavaScript("frames[1].innerHeight>=800&&frames[1].document.getElementById('role-data-with-back').getBoundingClientRect().height>0") as? Bool == true
        })
        let originalAction = try await action.browser.webView.evaluateJavaScript("""
            (()=>{const win=frames[1],doc=win.document,button=doc.getElementById('role-original-back');button.click();
              return win.__y3ClientIsInventoryMetadata()===false&&button===win.fixtureOriginalBack&&
                doc.getElementById('role-data-with-back')===win.fixtureOriginalActionTable&&
                win.fixtureOriginalActionTable.rows.length===21&&win.fixtureOriginalBackCount===1;})()
            """) as? Bool
        XCTAssertEqual(originalAction, true, "A summary plus many data rows stays a result when only its last row contains the original back button")
        XCTAssertNil(action.browser.failure)
        XCTAssertEqual(action.messages.errors, [])
    }

    @MainActor
    func testNativePendingSearchRecoversAfterLateSourceDocumentRewriteWithoutManualInjection() async throws {
        let session = NativeBrowserSession(path: "/scripts/verona/print/prtz030_1.asp?scenario=native-replacement")
        defer { session.close() }
        try await eventually(session, {
            session.browser.selectedFramePaneID == "0" && session.browser.framePanes.first(where: { $0.id == "0" })?.kind == .condition
        })
        _ = try await session.browser.webView.evaluateJavaScript("frames[0].document.querySelector('input[name=ken]').click()")
        try await eventually(session, {
            try await session.browser.webView.evaluateJavaScript("frames[1].fixtureReplacementRequest?.method==='POST'") as? Bool == true
        })
        // The source changes at 6.5 seconds, after all five seconds of native
        // discovery retries. Do not manually discover or replay any renderer.
        try await Task.sleep(nanoseconds: 5_600_000_000)
        let beforeRewrite = try await session.browser.webView.evaluateJavaScript("!frames[1].fixtureReplacementRewritten&&!frames[1].document.getElementById('native-replacement-table')") as? Bool
        XCTAssertEqual(beforeRewrite, true)
        XCTAssertEqual(session.browser.selectedFramePaneID, "0")
        try await eventually(session, {
            guard session.browser.selectedFramePaneID == "1",
                  session.browser.framePanes.first(where: { $0.id == "1" })?.kind == .result else { return false }
            return try await session.browser.webView.evaluateJavaScript("""
                (()=>{const win=frames[1],doc=win.document,table=doc.getElementById('native-replacement-table');
                  return win.fixtureReplacementRewritten===true&&win.innerHeight>=800&&table?.getBoundingClientRect().height>0&&
                    doc.documentElement.hasAttribute('data-y3client-phone')&&doc.documentElement.hasAttribute('data-y3client-layout')&&
                    !!doc.getElementById('y3client-touch-style')&&!!doc.getElementById('y3client-layout-base');})()
                """) as? Bool == true
        })
        let request = try await session.browser.webView.evaluateJavaScript("frames[1].fixtureReplacementRequest") as? [String: Any] ?? [:]
        let fields = request["values"] as? [String: [String]] ?? [:]
        XCTAssertEqual(fields["unchanged"], ["FICTIONAL-REPLACEMENT-TOKEN"])
        XCTAssertEqual(fields["ft_YYYYMMDD_F"], ["20261018"])
        let sourcePreserved = try await session.browser.webView.evaluateJavaScript("""
            (()=>{const win=frames[1],doc=win.document,button=doc.getElementById('native-replacement-action');button.click();
              return doc.getElementById('native-replacement-table')===win.fixtureReplacementTable&&button===win.fixtureReplacementAction&&
                win.fixtureReplacementTable.isConnected&&win.fixtureReplacementActionCount===1&&win.fixtureReplacementTable.rows.length===3;})()
            """) as? Bool
        XCTAssertEqual(sourcePreserved, true, "Support replay preserves the new source nodes and original handlers")
        XCTAssertNil(session.browser.failure)
        XCTAssertFalse(session.browser.hasSavedConnection)
        XCTAssertEqual(session.messages.errors, [])
    }
}
