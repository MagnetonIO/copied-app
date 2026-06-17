# Copied App Agent Notes

## Release Build Context

Use the repo root as the working directory:

```sh
cd /Users/mlong/Documents/Development/copied-reverse-engineer
```

Release automation is Fastlane-based and reads App Store Connect credentials from
the repo `.env` via `fastlane/Fastfile`:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_PATH` pointing at the `.p8` key

GitHub release publishing uses the authenticated `gh` CLI and the release repo
`MagnetonIO/copied-app`.

## Build Numbers

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.yml`.
`CFBundleVersion` is wired to `$(CURRENT_PROJECT_VERSION)`.

To bump or set the build number, use:

```sh
scripts/bump-build.sh        # increment current build by 1
scripts/bump-build.sh 9      # set an explicit build number
```

This regenerates `Copied.xcodeproj` with `xcodegen generate`.

Important: Apple rejects duplicate `CFBundleVersion` uploads. Do not run a lane
that bumps the build number if the requested build number is already prepared.

## GitHub Release Builds

For a new marketing version where the GitHub release tag does not exist:

```sh
bundle exec fastlane mac release_pkg
```

This builds the paid-license direct-download PKG and creates `vX.Y.Z` with
`build/license/Copied-vX.Y.Z.pkg`.

For an existing marketing version where the GitHub release already exists and
the asset should be overwritten:

```sh
bundle exec fastlane mac replace_pkg
```

This bumps `CURRENT_PROJECT_VERSION`, builds the paid-license PKG, and uploads
`build/license/Copied-vX.Y.Z.pkg` to the existing GitHub release with
`--clobber`.

Verify the GitHub asset with:

```sh
gh release view vX.Y.Z --repo MagnetonIO/copied-app --json tagName,name,assets,url
pkgutil --check-signature build/license/Copied-vX.Y.Z.pkg
xcrun stapler validate build/license/Copied-vX.Y.Z.pkg
```

## TestFlight Builds

To release both macOS and iOS TestFlight builds with one shared new build
number:

```sh
scripts/release-testflight.sh
```

This bumps once, then runs:

```sh
bundle exec fastlane mac mas_build
bundle exec fastlane mac testflight
bundle exec fastlane ios archive
bundle exec fastlane ios testflight
```

To upload only macOS or only iOS with a new build number:

```sh
scripts/release-testflight.sh mac
scripts/release-testflight.sh ios
```

If the build number has already been bumped or explicitly set, do not use
`scripts/release-testflight.sh`, `fastlane mac release_testflight`,
`fastlane ios release_testflight`, or `fastlane mac ship_patch`; they bump again.
Instead build and upload the already-prepared version:

```sh
bundle exec fastlane mac mas_build
bundle exec fastlane mac testflight

rm -rf build/ios/Copied.xcarchive build/ios/Copied.ipa build/ios/ExportOptions.plist
bundle exec fastlane ios archive
bundle exec fastlane ios testflight
```

The upload lanes use `skip_waiting_for_build_processing`, so App Store Connect
may take a few minutes before the uploaded build appears in the TestFlight UI.

Verify local archive versions before reporting success:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/mas/Copied.xcarchive/Products/Applications/Copied.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/mas/Copied.xcarchive/Products/Applications/Copied.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/ios/Copied.xcarchive/Products/Applications/Copied.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/ios/Copied.xcarchive/Products/Applications/Copied.app/Info.plist
ls -lh build/mas/Copied.pkg build/ios/Copied.ipa
```

## Combined Release Lanes

For a new version that should publish GitHub and upload both TestFlight builds:

```sh
bundle exec fastlane mac ship
```

For a same-version patch that should replace the existing GitHub PKG and upload
both TestFlight builds:

```sh
bundle exec fastlane mac ship_patch
```

`ship_patch` calls `replace_pkg`, so it bumps once there and then uses that same
build number for Mac and iOS TestFlight.
