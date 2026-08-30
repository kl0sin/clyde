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

# Stamp the identifier this build should carry. On CI that is the
# shipped one; on a development machine it is the dev identifier, so the
# bundle left in build/release/ cannot take the installed app's
# permissions with it. See scripts/lib/release-bundle-id.sh.
BUNDLE_ID="$("$PROJECT_ROOT/scripts/lib/release-bundle-id.sh")"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
if [ "$BUNDLE_ID" != "io.github.kl0sin.clyde" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Clyde (dev)" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Clyde (dev)" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Clyde (dev)" "$APP_BUNDLE/Contents/Info.plist"
    echo "==> Local build: stamping $BUNDLE_ID (set CLYDE_RELEASE_BUNDLE=1 for a real release bundle)"
fi
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
