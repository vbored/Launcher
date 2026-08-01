#!/bin/bash
# Builds a Universal 2 (arm64 + x86_64) release binary via SwiftPM and wraps
# it into a minimal double-clickable Launcher.app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Launcher"
APP_BUNDLE="$APP_NAME.app"

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH=".build/apple/Products/Release/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> Verifying architectures"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $APP_BUNDLE"
