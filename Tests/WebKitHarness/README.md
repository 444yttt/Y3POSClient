# Real WKWebView simulator harness

This directory is independent of the shipping app project. It creates an unsigned iOS host application plus an XCTest bundle in a new temporary output directory. It copies the checkout's actual `BrowserModel`, `URLPolicy`, `KeychainStore`, `LegacySiteSupport` and presentation sources into the test host. `source-manifest.json` records the original and fixture-source SHA256 values; routing and script bodies are not duplicated in the tests.

The copied sources substitute the fixed production origin with `http://127.0.0.1:17865`. The test-only `URLPolicy` copy maps its trusted scheme, host and port to that same loopback origin through guarded exact substitutions. This lets a loopback fixture server supply the original paths without contacting the live POS site, installing a certificate or changing DNS. The fixture host alone permits HTTP. Shipping source, ATS, trust policy and signing are unchanged. The native tests instantiate `BrowserModel` without calling `start()`, so they neither restore nor change Keychain login details.

`WebKitRuntimeTests` exercises actual script injection and isolated arguments. `NativeBrowserRuntimeTests` additionally uses the production browser configuration, navigation delegates, discovery scheduling, published pane selection and focus methods. This covers their integration with real frame loads and original form POSTs, rather than calling the discovery script as a substitute for the native controller.

Run on a standard GitHub-hosted `macos-15` runner with Xcode 16.4:

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
bash Tests/WebKitHarness/run-macos.sh "$GITHUB_WORKSPACE" "$RUNNER_TEMP/y3-webkit-runtime"
```

The signed-IPA workflow runs this immediately after checkout, before restoring any signing assets or supplying signing Secrets. It uses `permissions: contents: read` and uploads `$RUNNER_TEMP/y3-webkit-runtime/Runtime.xcresult` as synthetic test evidence even if a test fails. No live POS data is included. The test source and fixture server contain only fictional values.

The matrix is constructed by the fixture's own `window.load` listener. The production bootstrap is registered at `.atDocumentStart`, followed by the four presentation scripts at `.atDocumentEnd`, all with `forMainFrameOnly: false`, in the same order as the app. The tests cover:

- One inventory result pane, with actual leaf paths and API/style markers checked.
- A standalone stock detail document also receives the same size cards, including delayed matrix construction, unit changes, all four metrics/totals, original actions and unsupported-source fallback.
- Receipt conditions with multiple label/value pairs in each source row combine with their original detail document. Both arrival orders, original detail handlers, pager POSTs and data-only pager refreshes are exercised.
- A native unit check covers redirecting a previously selected result header to its unique combined result, preserving explicitly selected controls and avoiding ambiguous redirects.
- The actual native controller submits a daily report from its initially focused condition document, preserves eight-digit dates and hidden POST fields, selects its nested result and switches between all three result documents. Both `rows` and `cols` are present, and the original 200ms condition/calendar resize timer keeps running; viewport assertions wait through multiple ticks. Returning to the full frame view releases focus protection so the source calendar resize works again.
- The actual native controller follows the all-location stock search and original detail POST into their top-level frame sets, selects the data instead of the condition summary, and returns through the original back handler. All six size units retain every source stock cell, the supplied total and the original raw table node.
- The actual native controller skips script-heavy navigation and a standalone pager, retains a read-only report field as output, selects the real dataset, switches to a second aggregate and keeps an explicit no-data message readable at 320px. A three-row metadata table followed by 21 detail rows remains a result even when its final row contains the original back button; table/button identity and its handler stay intact.
- An original frame POST waits 6.5 seconds before the source replaces its entire HTML document, then builds its table 200ms later. After finite native discovery retries have ended, the document-start bootstrap must restore phone/layout support and notify the actual controller to select the pending result. Source table/button identity, original handlers and POST fields are preserved without test-triggered discovery or script replay.
- Metadata never becomes a generic card or numbered result even if merging fails.
- Inventory families 010/015 under print/display, including reversed metadata/matrix frames with arbitrary suffixes, a separate navigation frame, and a delayed page-owned grid constructor.
- Raw fallback styles, source-handler proxying after an identical same-document table replacement, and preservation of the selected table mode.
- Isolated staff arguments filling only the matching main document and never submitting.
- Store-guide mappings for footwear, category-specific apparel, socks and one-size codes; blank US women cells remain unknown. Six footwear unit choices and UK/US women switching preserve every size row and primary/detail stock value.
- Same-product searches wait for both metadata and matrix generations, in either arrival order, including identical-text source replacements.
- Unit switches and the stock filter retain keyboard focus when their controls are rerendered.
- Select/radio-only frame searches have individual accessible names and phone-sized controls, preserve original handlers/hidden fields, and track a real loopback POST and its ready result.
- A generic result containing an original `PgSelect` pager still becomes ready after the search POST and after its own page POST; both submissions retain the result frame role and increment readiness once.
- Frozen table header/body scroll in both directions; a narrower header cannot pull the wider body away from its final columns.
- The shared fictional compound form retains its malformed parser-assigned FORM ownership, every ancestor and duplicate field, aligned dates/five-slot rows, accessible names and unchanged datepicker at 390/320px; helper/selector handlers and all duplicate POST values remain intact.
- Interactive row-action reports scroll in place at 320px, including nested layouts and frozen header variants, while retaining original table/form/control nodes and duplicate-field POSTs.
- The same interactive-report test covers a 24-row checkbox `_8` helper: its report role, row names, bounded width, original five-selection limit, back handler, selected codes and duplicate hidden-token POST values remain intact.

These tests must pass under `xcodebuild test` on an actual iOS Simulator. Linux grammar/project checks or a Chromium run do not count as their execution result. The selected runtime is recorded in `devices.json`; Xcode 16.4 normally runs the iOS 18.5 simulator. Testing an iOS 17 runtime requires installing/selecting that runtime separately.

Xcode 16.4 with the iOS 18.5 runtime has [WebKit bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831): the Swift WebKit overlay may not load from its expected system path. The runner matches the selected device to its `simctl list runtimes --json` bundle, validates that runtime's `System/Cryptexes/OS/usr/lib/swift/libswiftWebKit.dylib`, and passes the containing directory through the generator's optional `--simulator-swift-libraries` argument. The generated LaunchAction sets `DYLD_FALLBACK_LIBRARY_PATH`; TestAction inherits its environment. `runtimes.json` and `selected-runtime.json` record the exact selection. This workaround affects only the generated simulator scheme: the harness and shipping deployment targets remain iOS 17, and no library is copied into the shipping app.
