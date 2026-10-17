#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo 'This harness requires macOS, Xcode and an iOS Simulator.' >&2; exit 1; }
harness_dir="$(cd "$(dirname "$0")" && pwd)"
app_source="${1:?Usage: run-macos.sh APP_CHECKOUT [OUTPUT_DIRECTORY]}"
output_dir="${2:-${RUNNER_TEMP:-/tmp}/y3-webkit-runtime-result}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}"
[[ "$(xcodebuild -version | sed -n 's/^Xcode //p')" == 16.4 ]] || { echo 'Xcode 16.4 is required.' >&2; exit 1; }
[[ ! -e "$output_dir" ]] || { echo 'Use a new output directory.' >&2; exit 1; }
mkdir -p "$output_dir"
python3 "$harness_dir/make_project.py" --app-source "$app_source" --output "$output_dir/project"
python3 "$harness_dir/serve_fixtures.py" --port 17865 > "$output_dir/fixture-server.log" 2>&1 &
fixture_pid=$!
cleanup() { kill "$fixture_pid" 2>/dev/null || true; }
trap cleanup EXIT
for attempt in $(seq 1 50); do
  if curl --fail --silent 'http://127.0.0.1:17865/health' > /dev/null; then break; fi
  sleep 0.1
done
curl --fail --silent 'http://127.0.0.1:17865/health' > /dev/null
xcrun simctl list devices available --json > "$output_dir/devices.json"
simulator_id="$(python3 - "$output_dir/devices.json" <<'PY'
import json, sys
devices=json.load(open(sys.argv[1]))['devices']
candidates=[]
for runtime, entries in devices.items():
    if '.iOS-' not in runtime:
        continue
    for device in entries:
        if device.get('isAvailable') and device.get('name','').startswith('iPhone'):
            score=(runtime.endswith('iOS-18-5'), device['name']=='iPhone 16 Pro', device.get('state')=='Booted', runtime)
            candidates.append((score, device['udid']))
if not candidates:
    raise SystemExit('No available iPhone simulator')
print(max(candidates)[1])
PY
)"
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project "$output_dir/project/WKRuntimeHarness.xcodeproj" -scheme WKRuntimeHarness \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -derivedDataPath "$output_dir/DerivedData" -resultBundlePath "$output_dir/Runtime.xcresult" \
  CODE_SIGNING_ALLOWED=NO test | tee "$output_dir/xcodebuild.log"
printf 'Real iOS Simulator WKWebView test result: %s\n' "$output_dir/Runtime.xcresult"
