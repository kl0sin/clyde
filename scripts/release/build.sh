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
#
# SPM extracts Sparkle as an XCFramework under
# .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/. We pick the
# universal macos-arm64_x86_64 slice which matches our universal binary.
SPARKLE_FRAMEWORK="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "==> Embedded Sparkle.framework from XCFramework"

    # SPM links the binary with rpath @executable_path/../lib only.
    # Apple's convention puts frameworks in Contents/Frameworks, so we
    # add a second rpath pointing there. Without this dyld can't find
    # Sparkle at launch.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/Clyde" 2>/dev/null || true
    echo "==> Added @executable_path/../Frameworks to runtime search path"
else
    echo "ERROR: Sparkle.framework not found at $SPARKLE_FRAMEWORK"
    echo "       Run 'swift build' first so SPM extracts the XCFramework."
    exit 1
fi

echo "==> Done: $APP_BUNDLE"
