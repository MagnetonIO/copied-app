#!/bin/zsh
# Reset Copied's local IAP state for sandbox + local-StoreKit testing.
# Usage:  ./scripts/reset-iap.sh
#
# Clears the `iCloudSyncPurchased` flag and sets `_skipStoreKitReconcile=YES`
# so the launch-time listener won't auto-flip the flag from a leftover
# Xcode-StoreKit-test transaction. Run this BEFORE each Xcode Run so the
# app boots showing the Unlock CTA.
#
# For Xcode's local StoreKit test transactions (.storekit harness), also use:
#   Xcode → Debug → StoreKit → Manage Transactions → select row → Delete

set -euo pipefail

PREFS=~/Library/Containers/com.mlong.copied.mac/Data/Library/Preferences/com.mlong.copied.mac.plist

# Kill any running dev build so the relaunch picks up fresh plist state.
pkill -9 -f "Copied \(Dev\).app/Contents/MacOS/Copied" 2>/dev/null || true
pkill -9 -f "DerivedData.*Copied.app/Contents/MacOS/Copied" 2>/dev/null || true
sleep 1

# Clear purchased state + restart flags.
defaults delete "$PREFS" iCloudSyncPurchased 2>/dev/null || true
defaults delete "$PREFS" _restartedFromPurchase 2>/dev/null || true
defaults delete "$PREFS" settingsTabOnNextOpen 2>/dev/null || true

# Prevent launch-time listener from re-flipping the flag from cached sandbox txn.
defaults write "$PREFS" _skipStoreKitReconcile -bool YES

echo "✓ Reset complete"
echo "  iCloudSyncPurchased      = $(defaults read "$PREFS" iCloudSyncPurchased 2>/dev/null || echo 'absent (false)')"
echo "  _skipStoreKitReconcile   = $(defaults read "$PREFS" _skipStoreKitReconcile 2>/dev/null)"
echo ""
echo "Next steps:"
echo "  • To test via Xcode + local .storekit (recommended):"
echo "      open Copied.xcodeproj  →  Select CopiedMac scheme  →  Run (⌘R)"
echo "      Debug → StoreKit → Manage Transactions  →  Delete any prior transaction"
echo "  • To test via real sandbox (/Applications/Copied (Dev).app):"
echo "      bundle exec fastlane mac mas_debug_build  →  relaunch from /Applications"
