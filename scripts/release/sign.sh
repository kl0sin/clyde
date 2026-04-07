#!/usr/bin/env bash
# Code-sign the Clyde.app bundle with a Developer ID Application identity.
#
# Required env vars:
#   DEVELOPER_ID_APPLICATION   — full identity name, e.g.
#       "Developer ID Application: Mateusz Kłosiński (ABCD123456)"
#
# Usage:
#   scripts/release/sign.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/release/Clyde.app"
ENTITLEMENTS="$PROJECT_ROOT/scripts/release/Clyde.entitlements"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found — run build.sh first"
    exit 1
fi

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "ERROR: DEVELOPER_ID_APPLICATION env var not set"
    exit 1
fi

echo "==> Signing nested frameworks (Sparkle + helpers)"
# Sparkle's nested helpers must be signed first, deepest-first, otherwise
# codesign rejects the parent bundle.
find "$APP_BUNDLE/Contents/Frameworks" -type f \( -name '*.dylib' -o -perm +111 \) 2>/dev/null | while read -r f; do
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$f" || true
done

# Sign the Sparkle XPC services and Autoupdate explicitly with hardened
# runtime — they're separate Mach-O bundles and need their own signature.
SPARKLE_DIR="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_DIR" ]]; then
    for helper in \
        "$SPARKLE_DIR/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE_DIR/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE_DIR/Versions/B/Autoupdate" \
        "$SPARKLE_DIR/Versions/B/Updater.app"; do
        if [[ -e "$helper" ]]; then
            echo "  -> $helper"
            codesign --force --options runtime --timestamp \
                --sign "$DEVELOPER_ID_APPLICATION" \
                "$helper"
        fi
    done
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$SPARKLE_DIR"
fi

echo "==> Signing main bundle"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP_BUNDLE"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || true

echo "==> Signed: $APP_BUNDLE"
