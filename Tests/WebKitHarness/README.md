# Real WKWebView simulator harness

This directory is independent of the shipping app project. It creates an unsigned iOS host application plus an XCTest bundle in a new temporary output directory. The exact checkout's `Y3Client/LegacySiteSupport.swift` is copied into the test host; no script contents are duplicated in the harness.

The only substitution is the fixed production origin to `http://127.0.0.1:17865` in each script. This lets a loopback fixture server supply the original paths without contacting the live POS site, installing a certificate or changing DNS. The fixture host alone permits HTTP. The shipping app's ATS, trust policy and Keychain are not changed or invoked. Native `BrowserModel` discovery scheduling is not exercised by this target; it tests actual WebKit injection, its all-frame page-world globals, the script's discovery result, and isolated argument passing.

Run on a standard GitHub-hosted `macos-15` runner with Xcode 16.4:

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
bash Tests/WebKitHarness/run-macos.sh "$GITHUB_WORKSPACE" "$RUNNER_TEMP/y3-webkit-runtime"
```

The signed-IPA workflow runs this immediately after checkout, before restoring any signing assets or supplying signing Secrets. It uses `permissions: contents: read` and uploads `$RUNNER_TEMP/y3-webkit-runtime/Runtime.xcresult` as synthetic test evidence even if a test fails. No live POS data is included. The test source and fixture server contain only fictional values.

The matrix is constructed by the fixture's own `window.load` listener. The production scripts are registered on `WKWebViewConfiguration` before the first request with `.atDocumentEnd`, `forMainFrameOnly: false`, in the same order as the app. The tests cover:

- One inventory result pane, with actual leaf paths and API/style markers checked.
- Metadata never becomes a generic card or numbered result even if merging fails.
- Inventory families 010/015 under print/display, including reversed metadata/matrix frames with arbitrary suffixes, a separate navigation frame, and a delayed page-owned grid constructor.
- Raw fallback styles, source-handler proxying after an identical same-document table replacement, and preservation of the selected table mode.
- Isolated staff arguments filling only the matching main document and never submitting.

These tests must pass under `xcodebuild test` on an actual iOS Simulator. Linux grammar/project checks or a Chromium run do not count as their execution result. The selected runtime is recorded in `devices.json`; Xcode 16.4 normally runs the iOS 18.5 simulator. Testing an iOS 17 runtime requires installing/selecting that runtime separately.
