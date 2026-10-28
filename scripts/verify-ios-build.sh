#!/bin/zsh
# Check the built app and extensions, not just the source configuration.
set -euo pipefail
repo="${0:A:h:h}"
artifact="${1:-$repo/build/ios/Copied.xcarchive/Products/Applications/Copied.app}"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
if [[ "$artifact" == *.ipa ]]; then
    ditto -x -k "$artifact" "$workdir"
    apps=("$workdir"/Payload/*.app(N))
    (( ${#apps} == 1 )) || { print -u2 "Expected one app in IPA: $artifact"; exit 1; }
    app="${apps[1]}"
else
    app="$artifact"
fi
[[ -d "$app" ]] || { print -u2 "Missing iOS app: $app"; exit 1; }

strings_file="$workdir/strings.txt"
bundles=("$app" "$app"/PlugIns/*.appex(N))
for bundle in "${bundles[@]}"; do
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")
    binary="$bundle/$executable"
    [[ -f "$binary" ]] || { print -u2 "Missing executable: $binary"; exit 1; }
done
for binary in "$app"/**/*(.ND); do
    file -b "$binary" | rg -q '^Mach-O' || continue
    strings -a "$binary" > "$strings_file"
    if rg 'LicenseEntrySheet|LicenseStore|LicenseValidator|Enter License|copied://unlock|com\.magneton\.copied\.license' "$strings_file"; then
        print -u2 "iOS binary contains a non-App-Store license unlock: $binary"
        exit 1
    fi
done

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
print "Verified iOS build $version ($build): no license-key UI or validator in app or extensions"
