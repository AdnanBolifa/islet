#!/bin/bash
# Builds a universal, hardened-runtime, ad-hoc signed Islet.app into build/.
# For release, sign with your Developer ID instead of "-" and notarize (see README).
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
if [ -n "${VERSION:-}" ]; then # set by CI from the git tag, e.g. 0.2.0
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
fi
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" --entitlements Resources/Islet.entitlements "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
