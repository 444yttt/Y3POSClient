#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 1; }
mkdir -p output
xcodebuild -version
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk_path" \
  -miphoneos-version-min=16.0 -std=c11 -O2 -Wall -Wextra \
  -c BLDRoute.c -o output/BLDRoute.o
xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$sdk_path" \
  -miphoneos-version-min=16.0 -fobjc-arc -fmodules -O2 -Wall -Wextra \
  -framework Foundation -framework UIKit -framework CoreLocation -framework UniformTypeIdentifiers \
  -install_name '@executable_path/Frameworks/BumpLocationDebug.dylib' \
  BLDLocationHooks.m BLDDebugUI.m BLDLibrary.m output/BLDRoute.o -o output/BumpLocationDebug.dylib
xcrun otool -L output/BumpLocationDebug.dylib
shasum -a 256 output/BumpLocationDebug.dylib > output/SHA256SUMS
