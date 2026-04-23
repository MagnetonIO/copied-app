#!/bin/zsh
# Copied build matrix.
#
# Usage:
#   ./scripts/build.sh oss            Local unlocked install (all features free).
#                                     Developer ID signed + notarized PKG; auto-opens Installer.
#                                     Output:  build/oss/Copied-OSS-vX.Y.Z.pkg    (gitignored)
#                                     Use case: your personal install. Not for distribution.
#
#   ./scripts/build.sh paid-license   Paid direct-download build (Stripe-backed license).
#                                     Developer ID signed + notarized PKG; auto-opens Installer.
#                                     Output:  build/license/Copied-License-vX.Y.Z.pkg   (gitignored)
#                                     Use case: website download + GitHub Releases. Unlock
#                                     happens via Stripe Checkout → signed license JWT →
#                                     copied://unlock?key=… deep-link.
#
#   ./scripts/build.sh paid-mas       Paid build for Mac App Store submission.
#                                     3rd-Party Mac Developer Installer signed .pkg.
#                                     Output:  build/mas/Copied.pkg
#                                     Follow with `bundle exec fastlane mac mas_upload` (stages
#                                     for submission) or `mas_submit` (submits for review).

set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:-}"
# Optional --open / -o flag routes through to fastlane so Installer opens
# after build. OSS always auto-opens (it's specifically for local install).
# MAS + License default to no-open so CI and casual builds don't interrupt.
open_flag=""
if [ "${2:-}" = "--open" ] || [ "${2:-}" = "-o" ]; then
  open_flag="open:true"
fi

case "$target" in
  oss)
    bundle exec fastlane mac oss_build
    ;;
  paid-mas)
    # Apple rejects re-uploads of the same CFBundleVersion; every MAS build
    # that we intend to upload must be on a fresh build number. Auto-bump
    # before xcodebuild runs.
    ./scripts/bump-build.sh
    bundle exec fastlane mac mas_build $open_flag
    ;;
  paid-license)
    bundle exec fastlane mac paid_license_build $open_flag
    ;;
  paid-license-test)
    bundle exec fastlane mac paid_license_test_build
    ;;
  ios)
    # Unsigned Simulator build of CopiedIOS → build/ios-sim/Copied.app.
    # Install and launch via scripts/ios-sim.sh run.
    bundle exec fastlane ios dev_build
    ;;
  ios-archive)
    # Signed iOS archive for App Store Distribution → build/ios/Copied.ipa.
    # Requires App Store Connect API key + provisioning profile configured.
    ./scripts/bump-build.sh
    bundle exec fastlane ios archive
    ;;
  ios-testflight)
    # Always bump + re-archive before upload — Apple rejects duplicate
    # CFBundleVersion, and a stale IPA would silently upload the wrong bits.
    ./scripts/bump-build.sh
    bundle exec fastlane ios archive
    bundle exec fastlane ios testflight
    ;;
  *)
    echo "Usage: $0 {oss|paid-license|paid-mas|ios|ios-archive|ios-testflight} [--open|-o]"
    echo ""
    echo "  oss             build/oss/Copied-OSS-vX.Y.Z.pkg          — unlocked local install (auto-opens Installer)"
    echo "  paid-license    build/license/Copied-License-vX.Y.Z.pkg  — Stripe-backed license, direct-download"
    echo "  paid-mas        build/mas/Copied.pkg                     — Mac App Store submission (auto-bumps CFBundleVersion)"
    echo "  ios             build/ios-sim/Copied.app                 — unsigned iOS Simulator build (for dev + agent testing)"
    echo "  ios-archive     build/ios/Copied.ipa                     — signed App Store archive (auto-bumps CFBundleVersion)"
    echo "  ios-testflight                                          — archive + upload to TestFlight (auto-bumps)"
    echo ""
    echo "  --open, -o    also open Installer after build (for paid-mas / paid-license local testing)"
    exit 1
    ;;
esac
