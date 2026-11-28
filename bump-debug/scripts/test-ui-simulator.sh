#!/bin/bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS required for UIKit regression host' >&2; exit 1; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bump-ui.XXXXXX")"
device_id=""
cleanup() {
  if [[ -n "$device_id" ]]; then
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -p "$project_dir/output"
xcrun simctl list runtimes --json > "$test_dir/runtimes.json"
xcrun simctl list devicetypes --json > "$test_dir/types.json"
python3 - "$test_dir" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
r=[r for r in json.loads((p/'runtimes.json').read_text())['runtimes'] if r.get('isAvailable') and '.iOS-' in r['identifier']]
assert r,'No available iOS simulator runtime'
r.sort(key=lambda v:tuple(int(n) for n in v['version'].split('.')))
t=json.loads((p/'types.json').read_text())['devicetypes']
choices=[x for x in t if x['identifier'] in ('com.apple.CoreSimulator.SimDeviceType.iPhone-16','com.apple.CoreSimulator.SimDeviceType.iPhone-15')]
assert choices,'No supported iPhone simulator type'
(p/'runtime').write_text(r[-1]['identifier']);(p/'type').write_text(choices[0]['identifier'])
PY
device_id="$(xcrun simctl create BumpUIRegression "$(cat "$test_dir/type")" "$(cat "$test_dir/runtime")")"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
app="$test_dir/BLDUIHost.app"
mkdir -p "$app"
python3 - "$app/Info.plist" <<'PY'
import plistlib,sys
p={'CFBundleIdentifier':'com.ayato.bumpdebug.uitests','CFBundleExecutable':'BLDUIHost','CFBundleName':'Bump UI Regression','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','CFBundleSupportedPlatforms':['iPhoneSimulator'],'MinimumOSVersion':'16.0','UIDeviceFamily':[1,2],'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Tests','UISceneDelegateClassName':'BLDTestScene'}]}}}
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios16.0-simulator" -isysroot "$sdk" \
  -fobjc-arc -fmodules -O1 -Wall -Wextra -Werror -framework UIKit -framework Foundation \
  "$project_dir/BLDDebugUI.m" "$project_dir/tests/ui_host.m" -o "$app/BLDUIHost"
codesign --force --sign - --timestamp=none "$app"
xcrun simctl install "$device_id" "$app"
xcrun simctl launch "$device_id" com.ayato.bumpdebug.uitests
container="$(xcrun simctl get_app_container "$device_id" com.ayato.bumpdebug.uitests data)"
for i in $(seq 1 60); do
  if [[ -f "$container/Documents/ui-tests.json" ]]; then break; fi
  sleep 1
done
[[ -f "$container/Documents/ui-tests.json" ]] || { echo 'UIKit host did not produce its result' >&2; exit 1; }
cp "$container/Documents/ui-tests.json" "$project_dir/output/ui-tests.json"
cat "$project_dir/output/ui-tests.json"
xcrun simctl io "$device_id" screenshot "$project_dir/output/ui-host.png"
python3 - "$project_dir/output/ui-tests.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['status']=='passed',r
PY
