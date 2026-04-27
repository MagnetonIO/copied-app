#!/bin/zsh
# Cross-platform TestFlight release driver.
#
# Bumps build numbers ONCE so Mac + iOS share the same build counter,
# then archives and uploads both platforms to TestFlight without
# submitting either for App Store review.
#
# Pre-req: APP_STORE_CONNECT_API_KEY_ID / _ISSUER_ID / _PATH set in .env
# (consumed by `asc_api_key` in fastlane/Fastfile).
#
# Usage:
#   scripts/release-testflight.sh            # both platforms
#   scripts/release-testflight.sh mac        # Mac only
#   scripts/release-testflight.sh ios        # iOS only

set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:-both}"

case "$target" in
  mac|ios|both) ;;
  *) echo "Usage: $0 [mac|ios|both]" >&2; exit 2 ;;
esac

echo "▶ Bumping build numbers (single bump shared across all targets)"
scripts/bump-build.sh

if [[ "$target" == "mac" || "$target" == "both" ]]; then
  echo "▶ Mac: archiving MAS .pkg"
  bundle exec fastlane mac mas_build
  echo "▶ Mac: uploading to TestFlight"
  bundle exec fastlane mac testflight
fi

if [[ "$target" == "ios" || "$target" == "both" ]]; then
  echo "▶ iOS: archiving"
  bundle exec fastlane ios archive
  echo "▶ iOS: uploading to TestFlight"
  bundle exec fastlane ios testflight
fi

echo "✓ Done. Check App Store Connect → TestFlight → Builds for processing status."
