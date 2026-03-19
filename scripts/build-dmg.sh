#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

echo "Building Copied.app Release archive..."

# 1. Build Release archive
xcodebuild -project Copied.xcodeproj -scheme CopiedMac \
  -configuration Release \
  -archivePath build/Copied.xcarchive \
  archive

# 2. Export signed .app
xcodebuild -exportArchive \
  -archivePath build/Copied.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist

# 3. Create DMG
DMG_NAME="Copied-$(date +%Y%m%d).dmg"
hdiutil create -volname "Copied" \
  -srcfolder build/export/Copied.app \
  -ov -format UDZO \
  "build/$DMG_NAME"

echo "✓ DMG created: build/$DMG_NAME"
