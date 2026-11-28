#!/bin/bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS required' >&2; exit 1; }
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bump-library.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$project_dir/output"
xcrun --sdk macosx clang -fobjc-arc -fmodules -fblocks -O2 -mmacosx-version-min=12.0 -Wall -Wextra -Werror -framework Foundation \
 "$project_dir/BLDLibrary.m" "$project_dir/tests/library_harness.m" -o "$test_dir/library-tests"
"$test_dir/library-tests" > "$project_dir/output/library-tests.json"
cat "$project_dir/output/library-tests.json"
