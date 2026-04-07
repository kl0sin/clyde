#!/usr/bin/env bash
# Build a release-mode universal Clyde.app bundle from the SwiftPM target.
#
# Outputs:
#   build/release/Clyde.app — bundle ready to be signed/notarized.
#
# Usage:
#   scripts/release/build.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build/release"
APP_BUNDLE="$BUILD_DIR/Clyde.app"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building Clyde (release, universal)"
# Build a universal binary so the same .dmg works on both Apple Silicon
# and Intel Macs.
swift build -c release \
    --arch arm64 --arch x86_64 \
    --disable-sandbox

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
EXECUTABLE="$BIN_PATH/Clyde"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "ERROR: built executable not found at $EXECUTABLE"
    exit 1
fi

echo "==> Assembling Clyde.app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Clyde"
cp "$PROJECT_ROOT/Clyde/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/Clyde/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# SwiftPM puts bundled resources in a sibling .bundle directory; copy that
# into the .app so Bundle.module continues to resolve at runtime.
RESOURCE_BUNDLE="$BIN_PATH/Clyde_Clyde.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Sparkle ships its XPC + Autoupdate helpers as a framework. They have to
# live in Contents/Frameworks/Sparkle.framework with the right structure
# or auto-update silently breaks.
SPARKLE_FRAMEWORK="$(find "$PROJECT_ROOT/.build" -type d -name 'Sparkle.framework' -path '*/release/*' | head -n 1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
else
    echo "WARNING: Sparkle.framework not found — auto-updates will not work"
fi

echo "==> Done: $APP_BUNDLE"
