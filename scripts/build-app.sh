#!/bin/bash
# Build script that creates a proper Clyde.app bundle from the SPM executable.
# Usage: ./scripts/build-app.sh [release|debug]

set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Clyde"
BUILD_DIR=".build/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build the executable
echo "→ Building $CONFIG..."
swift build -c "$CONFIG"

# Clean previous .app
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES"

# Copy the executable
cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"

# Copy Info.plist, then give the dev bundle its own identity.
#
# macOS keys Accessibility, Automation and notification grants to the
# bundle identifier. A dev build carrying the shipped one competes with
# the installed app for the same TCC record: System Settings keeps
# showing the permission as granted while the release build is quietly
# denied, and the only cure is resetting it by hand. Separate
# identifiers means both can be trusted independently.
cp Clyde/Info.plist "$CONTENTS/Info.plist"
DEV_BUNDLE_ID="io.github.kl0sin.clyde.dev"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Clyde (dev)" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string Clyde (dev)" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Clyde (dev)" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Clyde (dev)" "$CONTENTS/Info.plist"

# Copy SwiftPM's resource bundle. Without it `Bundle.module` finds nothing,
# so the app cannot install its own hook and reports the bundled script as
# missing — while a hook copied there by hand keeps the app looking healthy.
# scripts/release/build.sh has always done this; this script did not, which
# meant every live scenario ran against a bundle unlike the shipped one.
RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"
else
    echo "⚠️  ${APP_NAME}_${APP_NAME}.bundle not found — the app will not find its hook script."
fi

# Copy app icon if present
if [ -f "Clyde/Assets/AppIcon.icns" ]; then
    cp Clyde/Assets/AppIcon.icns "$RESOURCES/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
fi

# Embed Sparkle. The executable links it, so without this the bundle dies
# at launch with `dyld: Library not loaded: @rpath/Sparkle.framework`.
# SwiftPM leaves the framework in the build dir rather than in the bundle,
# which is why running the raw binary or `swift run` never works for this app.
SPARKLE=$(find .build -maxdepth 4 -name 'Sparkle.framework' -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE" ]; then
    mkdir -p "$CONTENTS/Frameworks"
    cp -R "$SPARKLE" "$CONTENTS/Frameworks/"
    # Order matters: rewrite the load path BEFORE signing. Signing first and
    # patching after leaves an inconsistent signature and macOS kills the
    # process on launch with SIGKILL (exit 137) and no useful message.
    install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/$APP_NAME" 2>/dev/null || true
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
else
    echo "⚠️  Sparkle.framework not found under .build — the bundle will not launch."
fi

echo "✓ Built $APP_DIR ($DEV_BUNDLE_ID)"
echo ""
echo "To run: open '$APP_DIR'"
echo "To install: cp -r '$APP_DIR' /Applications/"
