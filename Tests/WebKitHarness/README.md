# Real WKWebView simulator harness

This directory is independent of the shipping app project. It creates an unsigned iOS host application plus an XCTest bundle in a new temporary output directory. The exact checkout's `Y3Client/LegacySiteSupport.swift` and `Y3Client/ReportPresentation.swift` are copied into the test host; no script contents are duplicated in the harness.

The only substitution is the fixed production origin to `http://127.0.0.1:17865` in each script. This lets a loopback fixture server supply the original paths without contacting the live POS site, installing a certificate or changing DNS. The fixture host alone permits HTTP. The shipping app's ATS, trust policy and Keychain are not changed or invoked. Native `BrowserModel` discovery scheduling is not exercised by this target; it tests actual WebKit injection, its all-frame page-world globals, the script's discovery result, and isolated argument passing.

Run on a standard GitHub-hosted `macos-15` runner with Xcode 16.4:

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
bash Tests/WebKitHarness/run-macos.sh "$GITHUB_WORKSPACE" "$RUNNER_TEMP/y3-webkit-runtime"
```

The signed-IPA workflow runs this immediately after checkout, before restoring any signing assets or supplying signing Secrets. It uses `permissions: contents: read` and uploads `$RUNNER_TEMP/y3-webkit-runtime/Runtime.xcresult` as synthetic test evidence even if a test fails. No live POS data is included. The test source and fixture server contain only fictional values.

The matrix is constructed by the fixture's own `window.load` listener. The production scripts are registered on `WKWebViewConfiguration` before the first request with `.atDocumentEnd`, `forMainFrameOnly: false`, in the same order as the app. The tests cover:

- One inventory result pane, with actual leaf paths and API/style markers checked.
- A standalone stock detail document also receives the same size cards, including delayed matrix construction, unit changes, all four metrics/totals, original actions and unsupported-source fallback.
- Receipt conditions with multiple label/value pairs in each source row combine with their original detail document. Both arrival orders, original detail handlers, pager POSTs and data-only pager refreshes are exercised.
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
