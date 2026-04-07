#!/usr/bin/env bash
# Submit Clyde.app to Apple's notary service and staple the ticket back.
#
# Required env vars:
#   APPLE_ID                 — Apple ID email used for the Developer Program
#   APPLE_TEAM_ID            — 10-character team identifier
#   APPLE_APP_PASSWORD       — app-specific password from appleid.apple.com
#
# Usage:
#   scripts/release/notarize.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/release/Clyde.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found — run build.sh + sign.sh first"
    exit 1
fi

for var in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var env var not set"
        exit 1
    fi
done

# Notary service requires the .app to be inside a zip or DMG.
ZIP_PATH="$PROJECT_ROOT/build/release/Clyde-notarize.zip"
echo "==> Creating zip for notarization submission"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

echo "==> Stapling ticket onto the .app"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

rm -f "$ZIP_PATH"
echo "==> Notarized: $APP_BUNDLE"
