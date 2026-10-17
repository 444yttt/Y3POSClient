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
xcrun simctl list devices available --json > "$output_dir/devices.json"
xcrun simctl list runtimes --json > "$output_dir/runtimes.json"
python3 - "$output_dir/devices.json" "$output_dir/runtimes.json" "$output_dir/selected-runtime.json" <<'PY'
import json, subprocess, sys
from pathlib import Path
devices=json.load(open(sys.argv[1]))['devices']
runtimes={runtime['identifier']:runtime for runtime in json.load(open(sys.argv[2]))['runtimes']
          if runtime.get('isAvailable')}
candidates=[]
for runtime, entries in devices.items():
    if '.iOS-' not in runtime or runtime not in runtimes:
        continue
    for device in entries:
        if device.get('isAvailable') and device.get('name','').startswith('iPhone'):
            score=(runtime.endswith('iOS-18-5'), device['name']=='iPhone 16 Pro', device.get('state')=='Booted', runtime)
            candidates.append((score, device['udid']))
if not candidates:
    raise SystemExit('No available iPhone simulator')
simulator_id=max(candidates)[1]
runtime_id=next(runtime for runtime, entries in devices.items()
                if any(device.get('udid')==simulator_id for device in entries))
runtime=runtimes[runtime_id]
# Boot first so the selected runtime's mounted Cryptex is available for validation.
subprocess.run(['xcrun','simctl','bootstatus',simulator_id,'-b'],check=True)
bundle=Path(runtime.get('bundlePath',''))
if not bundle.is_absolute() or not bundle.is_dir():
    raise SystemExit('The selected simulator runtime bundle is unavailable')
libraries=bundle/'Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift'
has_overlay=(libraries/'libswiftWebKit.dylib').is_file()
if runtime.get('version')=='18.5' and not has_overlay:
    raise SystemExit('The iOS 18.5 runtime Cryptex libswiftWebKit.dylib workaround is unavailable')
selection={'simulatorId':simulator_id,'runtimeIdentifier':runtime_id,
           'runtimeVersion':runtime.get('version',''),'runtimeBundle':str(bundle),
           'simulatorSwiftLibraries':str(libraries.resolve()) if has_overlay else ''}
Path(sys.argv[3]).write_text(json.dumps(selection,indent=2)+'\n')
PY
simulator_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["simulatorId"])' "$output_dir/selected-runtime.json")"
simulator_swift_libraries="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["simulatorSwiftLibraries"])' "$output_dir/selected-runtime.json")"
generator_arguments=(--app-source "$app_source" --output "$output_dir/project")
if [[ -n "$simulator_swift_libraries" ]]; then
  generator_arguments+=(--simulator-swift-libraries "$simulator_swift_libraries")
fi
python3 "$harness_dir/make_project.py" "${generator_arguments[@]}"
python3 "$harness_dir/serve_fixtures.py" --port 17865 > "$output_dir/fixture-server.log" 2>&1 &
fixture_pid=$!
cleanup() { kill "$fixture_pid" 2>/dev/null || true; }
trap cleanup EXIT
for attempt in $(seq 1 50); do
  if curl --fail --silent 'http://127.0.0.1:17865/health' > /dev/null; then break; fi
  sleep 0.1
done
curl --fail --silent 'http://127.0.0.1:17865/health' > /dev/null
xcodebuild -project "$output_dir/project/WKRuntimeHarness.xcodeproj" -scheme WKRuntimeHarness \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -derivedDataPath "$output_dir/DerivedData" -resultBundlePath "$output_dir/Runtime.xcresult" \
  CODE_SIGNING_ALLOWED=NO test | tee "$output_dir/xcodebuild.log"
printf 'Real iOS Simulator WKWebView test result: %s\n' "$output_dir/Runtime.xcresult"
