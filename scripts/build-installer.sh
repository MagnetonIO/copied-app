#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" CopiedMac/Info.plist 2>/dev/null || echo "1.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" CopiedMac/Info.plist 2>/dev/null || echo "1")
IDENTIFIER="com.magneton.copied"

echo "Building Copied v${VERSION} (${BUILD})..."
mkdir -p build

# ── Build signed Release ──────────────────────────
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

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Copied-*/Build/Products/Release -name "Copied.app" -maxdepth 1 | head -1)

if [ -z "$APP_PATH" ]; then
  echo "ERROR: Copied.app not found"
  exit 1
fi

echo "App: $APP_PATH"

# ── Create PKG installer ─────────────────────────
echo ""
echo "Creating installer package..."

# Stage the app for pkgbuild
PKG_ROOT="build/pkg-root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_PATH" "$PKG_ROOT/Applications/Copied.app"

# Component package: installs Copied.app to /Applications
pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts installer/scripts \
  build/Copied-component.pkg

rm -rf "$PKG_ROOT"

# Product archive: wraps component with welcome/conclusion UI
productbuild \
  --distribution installer/distribution.xml \
  --resources installer \
  --package-path build \
  "build/Copied-${VERSION}-Installer.pkg"

# Clean up component
rm -f build/Copied-component.pkg

# ── Create DMG (drag-install) ─────────────────────
echo ""
echo "Creating DMG..."

STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Copied.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Copied" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "build/Copied-${VERSION}.dmg"

rm -rf "$STAGING"

echo ""
echo "========================================="
echo "  Copied v${VERSION} (${BUILD})"
echo ""
echo "  Installer: build/Copied-${VERSION}-Installer.pkg"
echo "  DMG:       build/Copied-${VERSION}.dmg"
echo "========================================="
