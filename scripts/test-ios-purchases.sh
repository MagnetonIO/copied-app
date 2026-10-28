#!/bin/zsh
# Run only on a dedicated simulator: tests change its local purchase history.
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Usage: zsh scripts/test-ios-purchases.sh SIMULATOR_UDID [xcodebuild options]}"
shift

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
entitlements="$workdir/StoreKitTest.entitlements"
cp CopiedIOS/CopiedIOS.entitlements "$entitlements"
# StoreKitTest rejects an ad-hoc simulator app without this development flag
# ("not installed for development"). Never use these entitlements for Release.
plutil -insert get-task-allow -bool true "$entitlements"
plutil -replace aps-environment -string development "$entitlements"
xcodegen generate
xcodebuild -project Copied.xcodeproj -scheme CopiedIOS \
    -destination "platform=iOS Simulator,id=$device" \
    -derivedDataPath build/ios-review-tests \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=7727LYTG96 \
    CODE_SIGN_ENTITLEMENTS="$entitlements" "$@" test
