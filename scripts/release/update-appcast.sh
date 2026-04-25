#!/usr/bin/env bash
# Append a new entry to site/appcast.xml for the freshly built DMG.
#
# Required env vars:
#   SPARKLE_PRIVATE_KEY      — base64 EdDSA private key (from Sparkle's
#                              `generate_keys` tool, kept in GitHub Secrets)
#   GITHUB_REPO              — e.g. "yourname/clyde" (used to build URL)
#
# Usage:
#   scripts/release/update-appcast.sh path/to/Clyde-0.1.0.dmg
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INFO_PLIST="$PROJECT_ROOT/Clyde/Info.plist"
APPCAST="$PROJECT_ROOT/site/appcast.xml"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    echo "Usage: $0 path/to/Clyde-x.y.z.dmg"
    exit 1
fi

if [[ -z "${GITHUB_REPO:-}" ]]; then
    echo "ERROR: GITHUB_REPO env var not set (e.g. yourname/clyde)"
    exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "ERROR: SPARKLE_PRIVATE_KEY env var not set"
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_NAME="$(basename "$DMG")"
DMG_SIZE="$(stat -f%z "$DMG")"
PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${DMG_NAME}"

# Sign the DMG with Sparkle's signing tool. The tool expects the private
# key on disk; we materialise it from the env var into a tempfile.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

# `sign_update` ships with Sparkle and lives next to the framework.
SIGN_TOOL="$(find "$PROJECT_ROOT/.build" -type f -name 'sign_update' | head -n 1)"
if [[ -z "$SIGN_TOOL" ]]; then
    echo "ERROR: sign_update tool not found — build the project first so SPM fetches Sparkle"
    exit 1
fi

SIGNATURE="$("$SIGN_TOOL" --ed-key-file "$KEY_FILE" "$DMG" | awk -F'"' '/sparkle:edSignature/ {print $2}')"
if [[ -z "$SIGNATURE" ]]; then
    echo "ERROR: failed to produce EdDSA signature for $DMG"
    exit 1
fi

# Pull the latest section out of CHANGELOG.md as the release notes payload.
RELEASE_NOTES="$(awk -v version="## $VERSION" '
    $0 ~ "^## " { if (printing) exit; if (index($0, version)==1) { printing=1; next } }
    printing { print }
' "$CHANGELOG" || echo "")"

if [[ -z "$RELEASE_NOTES" ]]; then
    RELEASE_NOTES="See the changelog for details."
fi

# Build the new <item> XML chunk.
NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
${RELEASE_NOTES}
            ]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${DMG_SIZE}"
                type="application/octet-stream"
                sparkle:edSignature="${SIGNATURE}" />
        </item>
EOF
)

# Insert the new item right after the <language> line of the channel.
# We pass NEW_ITEM via the environment instead of `awk -v` because BSD
# awk (the macOS default) rejects newlines in -v values, and the item
# block is multi-line.
TMP="$(mktemp)"
NEW_ITEM="$NEW_ITEM" awk '
    /<language>/ && !inserted { print; print ENVIRON["NEW_ITEM"]; inserted=1; next }
    { print }
' "$APPCAST" > "$TMP"
mv "$TMP" "$APPCAST"

echo "==> Appcast updated with version ${VERSION}"
