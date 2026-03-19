#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" CopiedMac/Info.plist 2>/dev/null || echo "0.1.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" CopiedMac/Info.plist 2>/dev/null || echo "1")
DMG_NAME="Copied-${VERSION}.dmg"

echo "Building Copied v${VERSION} (${BUILD})..."

# Clean build directory
mkdir -p build
rm -f "build/${DMG_NAME}"

# Build signed Release
xcodebuild -project Copied.xcodeproj \
  -scheme CopiedMac \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  DEVELOPMENT_TEAM=7727LYTG96 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  clean build

# Find the built .app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Copied-*/Build/Products/Release -name "Copied.app" -maxdepth 1 | head -1)

if [ -z "$APP_PATH" ]; then
  echo "ERROR: Copied.app not found in DerivedData"
  exit 1
fi

echo "App: $APP_PATH"

# Create installer DMG with background and Applications symlink
DMG_TEMP="build/Copied-temp.dmg"
DMG_FINAL="build/${DMG_NAME}"

# Create a temporary folder with app + Applications alias
STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Copied.app"
ln -s /Applications "$STAGING/Applications"

# Create a read-write DMG first so we can customize Finder window
rm -f "$DMG_TEMP"
hdiutil create -volname "Copied" \
  -srcfolder "$STAGING" \
  -ov -format UDRW \
  "$DMG_TEMP"

# Mount the read-write DMG and configure Finder view
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep '/Volumes/' | sed 's/.*\/Volumes/\/Volumes/')
echo "Mounted at: $MOUNT_DIR"

# Use AppleScript to set icon view with proper layout
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "Copied"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 640, 400}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 13
    set background color of theViewOptions to {7710, 7710, 7710}
    set position of item "Copied.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Ensure Finder writes the .DS_Store
sync
sleep 2

# Detach the DMG
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force

# Convert to compressed read-only DMG
rm -f "$DMG_FINAL"
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -f "$DMG_TEMP"

# Clean up staging
rm -rf "$STAGING"

echo ""
echo "========================================="
echo "  Copied v${VERSION} (${BUILD})"
echo "  DMG: build/${DMG_NAME}"
echo "========================================="
