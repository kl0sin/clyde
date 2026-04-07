#!/usr/bin/env bash
# Pack the signed + notarized Clyde.app into a distributable DMG.
#
# Output: build/release/Clyde-<version>.dmg
#
# Usage:
#   scripts/release/make-dmg.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/release/Clyde.app"
INFO_PLIST="$PROJECT_ROOT/Clyde/Info.plist"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found"
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_NAME="Clyde-${VERSION}.dmg"
DMG_PATH="$PROJECT_ROOT/build/release/$DMG_NAME"
STAGING="$PROJECT_ROOT/build/release/dmg-staging"

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Layout: Clyde.app + symlink to /Applications so the user can drag it in.
cp -R "$APP_BUNDLE" "$STAGING/Clyde.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "Clyde $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Sign the DMG itself so Gatekeeper accepts the download bundle.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "==> Signing DMG"
    codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
fi

rm -rf "$STAGING"
echo "==> Done: $DMG_PATH"
