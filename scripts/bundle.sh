#!/bin/bash
# Builds a universal, sandboxed, ad-hoc signed Islet.app into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP=build/Islet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Islet" "$APP/Contents/MacOS/Islet"
strip -x "$APP/Contents/MacOS/Islet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Islet.entitlements "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
