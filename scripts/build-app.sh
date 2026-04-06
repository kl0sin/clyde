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

# Copy Info.plist
cp Clyde/Info.plist "$CONTENTS/Info.plist"

# Copy app icon if present
if [ -f "Clyde/Assets/AppIcon.icns" ]; then
    cp Clyde/Assets/AppIcon.icns "$RESOURCES/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
fi

echo "✓ Built $APP_DIR"
echo ""
echo "To run: open '$APP_DIR'"
echo "To install: cp -r '$APP_DIR' /Applications/"
