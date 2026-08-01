#!/bin/bash
# Packages Launcher.app into a drag-to-install Launcher.dmg.
# Rebuilds the app bundle first (via make_app_bundle.sh) so the DMG always
# reflects the current source.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Launcher"
APP_BUNDLE="$APP_NAME.app"
VOL_NAME="Launcher"
DMG_NAME="Launcher.dmg"
STAGING_DIR=".dmg-staging"

echo "==> Building $APP_BUNDLE"
./Scripts/make_app_bundle.sh

echo "==> Staging DMG contents"
rm -rf "$STAGING_DIR" "$DMG_NAME"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_NAME"

rm -rf "$STAGING_DIR"

echo "==> Verifying"
hdiutil verify "$DMG_NAME"

echo "Done: $DMG_NAME"
