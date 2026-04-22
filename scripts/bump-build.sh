#!/bin/zsh
# Increment CFBundleVersion + CURRENT_PROJECT_VERSION in project.yml by 1 and
# regenerate the Xcode project. Keeps MARKETING_VERSION untouched — that's a
# human decision (patch, minor, major).
#
# Called automatically by `scripts/build.sh paid-mas` so every MAS build gets
# a unique build number (Apple rejects re-uploads of the same CFBundleVersion).
#
# Usage:
#   scripts/bump-build.sh                # current+1
#   scripts/bump-build.sh <number>       # set to specific value

set -euo pipefail
cd "$(dirname "$0")/.."

current=$(awk '/CFBundleVersion:/ {gsub(/["]/,"",$2); print $2; exit}' project.yml)
[ -z "$current" ] && { echo "Could not read CFBundleVersion from project.yml" >&2; exit 1; }

if [ $# -gt 0 ]; then
  next="$1"
else
  next=$((current + 1))
fi

echo "Bumping build number: $current → $next"

# BSD sed (macOS) needs -i '' for in-place without backup file.
sed -i '' -E "s/(CFBundleVersion:[[:space:]]*)\"[0-9]+\"/\1\"$next\"/" project.yml
sed -i '' -E "s/(CURRENT_PROJECT_VERSION:[[:space:]]*)\"[0-9]+\"/\1\"$next\"/" project.yml

# Regenerate xcodeproj so the next xcodebuild invocation sees the new version.
xcodegen generate > /dev/null

echo "✓ project.yml + Copied.xcodeproj updated to build $next"
