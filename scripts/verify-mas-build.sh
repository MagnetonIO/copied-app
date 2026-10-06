#!/bin/zsh
# Check the exact signed app before uploading an App Store build.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/mas/Copied.xcarchive/Products/Applications/Copied.app}"
binary="$app/Contents/MacOS/Copied"
[[ -f "$binary" ]] || { print -u2 "Missing Mac binary: $binary"; exit 1; }
codesign --verify --deep --strict "$app"

entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
sandbox=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")
[[ "$sandbox" == true ]] || { print -u2 "App Store build must be sandboxed"; exit 1; }

symbols=$(nm -u "$binary")
if rg '_(AXIsProcessTrusted(WithOptions)?|CGEventTapCreate|CGEventPost(ToPid)?|CGPostKeyboardEvent)([[:space:]]|$)' <<< "$symbols"; then
    print -u2 "App Store binary contains privileged keyboard/Accessibility APIs"
    exit 1
fi
rg -q '_RegisterEventHotKey([[:space:]]|$)' <<< "$symbols" || {
    print -u2 "Missing permission-free Carbon global shortcut"
    exit 1
}
if [[ -e "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    print -u2 "App Store build must not embed Sparkle"
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
print "Verified sandboxed Mac App Store build $version ($build): Carbon hotkey, no privileged keyboard APIs or Sparkle"
