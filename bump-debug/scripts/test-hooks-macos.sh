#!/bin/bash
set -euo pipefail
umask 077

[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required for the hook harness' >&2; exit 1; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bump-hooks.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
result_path="${1:-$project_dir/output/hook-tests.json}"
mkdir -p "$(dirname "$result_path")"

xcrun --sdk macosx clang -fobjc-arc -fmodules -fblocks -O2 \
    -mmacosx-version-min=12.0 -Wall -Wextra -Werror -DBLD_TEST_HOST \
    -framework Foundation -framework CoreFoundation -framework CoreLocation \
    "$project_dir/BLDLocationHooks.m" "$project_dir/BLDRoute.c" \
    "$project_dir/tests/hook_harness.m" -o "$test_dir/hook-tests"
"$test_dir/hook-tests" > "$result_path"
cat "$result_path"
