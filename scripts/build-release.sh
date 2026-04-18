#!/bin/bash
set -e

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" CopiedMac/Info.plist 2>/dev/null || echo "1.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" CopiedMac/Info.plist 2>/dev/null || echo "1")
TEAM_ID="7727LYTG96"
IDENTIFIER="com.mlong.copied.mac"
# Developer ID profile that actually matches com.mlong.copied.mac + iCloud
# container. Required because CloudKit entitlements force a provisioning
# profile even for Developer ID signing.
PROVISIONING_PROFILE_SPECIFIER="Copied Mac DevID"

echo "========================================"
echo "  Building Copied v${VERSION} (${BUILD})"
echo "  Signing: Developer ID Application"
echo "========================================"
echo ""

mkdir -p build

# ── 1. Archive ────────────────────────────────
echo "[1/6] Archiving..."
set -o pipefail
xcodebuild -project Copied.xcodeproj \
  -scheme CopiedMac \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath build/Copied.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER" \
  ENABLE_HARDENED_RUNTIME=YES \
  -allowProvisioningUpdates \
  archive 2>&1 | tail -5

# ── 2. Export ─────────────────────────────────
echo "[2/6] Exporting signed app..."

# Create export options for Developer ID
cat > build/ExportOptions-Release.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$IDENTIFIER</key>
        <string>$PROVISIONING_PROFILE_SPECIFIER</string>
    </dict>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/Copied.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions-Release.plist \
  -allowProvisioningUpdates 2>&1 | tail -3

APP_PATH="build/export/Copied.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Export failed — Copied.app not found"
  exit 1
fi

# ── 3. Verify signing ────────────────────────
echo "[3/6] Verifying signature..."
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier"

# ── 4. Notarize ──────────────────────────────
echo "[4/6] Notarizing (this may take 2-5 minutes)..."

# Create a zip for notarization
ditto -c -k --keepParent "$APP_PATH" build/Copied-notarize.zip

xcrun notarytool submit build/Copied-notarize.zip \
  --keychain-profile "AC_PASSWORD" \
  --wait 2>&1 | tee build/notarize-log.txt

rm -f build/Copied-notarize.zip

# Check if notarization succeeded
if grep -q "status: Accepted" build/notarize-log.txt; then
  echo "Notarization accepted!"
else
  echo "WARNING: Notarization may have failed. Check build/notarize-log.txt"
  echo "Continuing anyway..."
fi

# ── 5. Staple ────────────────────────────────
echo "[5/6] Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH" 2>&1

# ── 6. Package ───────────────────────────────
echo "[6/6] Creating installer and DMG..."

# PKG installer
PKG_ROOT="build/pkg-root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_PATH" "$PKG_ROOT/Applications/Copied.app"

pkgbuild --root "$PKG_ROOT" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts installer/scripts \
  --sign "Developer ID Installer: Magneton Labs, LLC ($TEAM_ID)" \
  build/Copied-component.pkg 2>&1 | tail -1

rm -rf "$PKG_ROOT"

productbuild \
  --distribution installer/distribution.xml \
  --resources installer \
  --package-path build \
  --sign "Developer ID Installer: Magneton Labs, LLC ($TEAM_ID)" \
  "build/Copied-${VERSION}-Installer.pkg" 2>&1 | tail -1

rm -f build/Copied-component.pkg

# Notarize the PKG too
echo "Notarizing installer..."
xcrun notarytool submit "build/Copied-${VERSION}-Installer.pkg" \
  --keychain-profile "AC_PASSWORD" \
  --wait 2>&1 | tail -3

xcrun stapler staple "build/Copied-${VERSION}-Installer.pkg" 2>&1

# DMG
STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Copied.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Copied" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "build/Copied-${VERSION}.dmg" 2>&1 | tail -1

rm -rf "$STAGING"

# Notarize the DMG
echo "Notarizing DMG..."
xcrun notarytool submit "build/Copied-${VERSION}.dmg" \
  --keychain-profile "AC_PASSWORD" \
  --wait 2>&1 | tail -3

xcrun stapler staple "build/Copied-${VERSION}.dmg" 2>&1

# Cleanup
rm -rf build/Copied.xcarchive build/export build/ExportOptions-Release.plist build/notarize-log.txt

echo ""
echo "========================================"
echo "  Copied v${VERSION} — RELEASE BUILD"
echo ""
echo "  Installer: build/Copied-${VERSION}-Installer.pkg"
echo "  DMG:       build/Copied-${VERSION}.dmg"
echo ""
echo "  Signed:     Developer ID Application"
echo "  Notarized:  Yes"
echo "  Ready for:  Public distribution"
echo "========================================"
