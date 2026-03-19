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

# Create a temporary folder with app + Applications alias
STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Copied.app"
ln -s /Applications "$STAGING/Applications"

# Create DMG from staging folder
hdiutil create -volname "Copied" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "build/${DMG_NAME}"

# Clean up staging
rm -rf "$STAGING"

echo ""
echo "========================================="
echo "  Copied v${VERSION} (${BUILD})"
echo "  DMG: build/${DMG_NAME}"
echo "========================================="
