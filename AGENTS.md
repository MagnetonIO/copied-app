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

## Direct Download Updates

The website/GitHub build uses the `CopiedMacDirect` target and Sparkle 2. The
Mac App Store target is deliberately separate and must never embed Sparkle.

- Feed: `https://www.getcopied.app/appcast.xml`
- Feed source: `../getcopied-app/public/appcast.xml`
- Sparkle keychain account: `com.magneton.copied`
- Homebrew tap: `MagnetonIO/homebrew-tap`
- Cask source: `../homebrew-tap/Casks/copied.rb`

The private Sparkle key lives in the macOS Keychain. A local backup may exist
under `.keys/`, which is gitignored. Never commit or print the private key.

After building a replacement PKG, sign that exact artifact and copy the emitted
signature and length into the appcast enclosure:

```sh
/tmp/copied-sparkle-2.10/bin/sign_update \
  --account com.magneton.copied \
  build/license/Copied-vX.Y.Z.pkg
```

Also update the appcast `sparkle:version`, `sparkle:shortVersionString`, URL,
and release notes. Update the Homebrew cask version and SHA-256 when either
changes. Publish in this order to avoid a live feed referencing the wrong bytes:

1. Upload the new PKG to the GitHub release with `--clobber`.
2. Commit and push the Homebrew cask update.
3. Commit and push the website appcast update.

Verify all channels:

```sh
curl -LfsS https://github.com/MagnetonIO/copied-app/releases/download/vX.Y.Z/Copied-vX.Y.Z.pkg -o /tmp/Copied-live.pkg
shasum -a 256 /tmp/Copied-live.pkg
pkgutil --check-signature /tmp/Copied-live.pkg
xcrun stapler validate /tmp/Copied-live.pkg
curl -fsS https://www.getcopied.app/appcast.xml | xmllint --noout -
brew audit --cask --online magnetonio/tap/copied
brew fetch --cask magnetonio/tap/copied
```

For a UI update test, first install an updater-enabled build with a lower
`CFBundleVersion`, then publish a higher build in the appcast. Open Copied's
About settings and click **Check for Updates**. Confirm Sparkle offers the newer
build, validates it, requests administrator approval for the PKG, installs it,
and relaunches Copied. A build cannot offer itself as an update.

Homebrew installs are detected from the cask receipt under
`/opt/homebrew/Caskroom/copied` or `/usr/local/Caskroom/copied`. Copied disables
Sparkle for that channel and shows:

```sh
brew upgrade --cask magnetonio/tap/copied
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

## App Store Production Staging

TestFlight upload does not stage the production listings. After both builds are
`VALID`, upload the checked-in metadata and screenshots without submitting:

```sh
bundle exec fastlane mac upload_metadata
bundle exec fastlane ios upload_metadata
bundle exec fastlane ios upload_screenshots
```

Then select the same validated build for the macOS and iOS production version
records in App Store Connect. Do not re-run `mas_upload` for a package
that was already uploaded to TestFlight; Apple rejects duplicate build numbers.

Before submission, verify in App Store Connect for each platform:

- The intended build is selected and still `VALID`.
- Metadata, review contact details, and screenshots are complete.
- Age Rating, App Privacy, pricing, availability, content rights, and release
  mode are complete.
- Agreements, tax, banking, and Digital Services Act status have no blocking
  actions.
- For the first Mac release, add the `com.magneton.copied.icloud_sync`
  non-consumable IAP to the same review submission.

The production versions are separate review items. Do not submit either one
unless the user explicitly asks for submission. Apple now uses the two-step
`Add for Review` then `Submit for Review` flow; verify the draft contents in the
web UI before the final action.

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
