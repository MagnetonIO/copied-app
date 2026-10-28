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

Keep the marketing version and build number aligned across `CopiedMac`,
`CopiedMacDirect`, `CopiedIOS`, `CopiedShareExtension`, and
`CopiedClipperExtension`. The aligned source version is currently `1.3.4 (19)`.
Do not reset the shared build counter to 1 for a new marketing version: Mac
App Store build numbers must keep increasing across marketing versions.

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
SPARKLE_SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' -print -quit)
"$SPARKLE_SIGN_UPDATE" \
  --account com.magneton.copied \
  build/license/Copied-vX.Y.Z.pkg
```

Also update the appcast `sparkle:version`, `sparkle:shortVersionString`, URL,
and release notes. Every shipped patch must increment `CFBundleVersion`, even
when the marketing version stays the same. Give the update artifact an immutable
name such as `Copied-v1.3.3-build14.pkg`; the legacy `Copied-v1.3.3.pkg` may still
be overwritten for the website's download button, but the appcast and Homebrew
cask must point to the immutable asset. Otherwise replacing that file breaks
older appcast signatures and Homebrew caches while deployments propagate.

Use a composite Homebrew version such as `"1.3.3,14"` and interpolate
`version.csv.first` / `version.csv.second` for the marketing version / build
number in the asset filename. Update its SHA-256 for the exact published bytes.
This lets `brew upgrade` recognize same-version patches. Publish in this order:

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
Sparkle for that channel. About -> Updates checks in the background using
`brew update --quiet` and `brew info --cask --json=v2 magnetonio/tap/copied`.
It does not upgrade anything during a check. When an update is available,
**Install with Homebrew** opens a fixed `.command` in Terminal so the PKG
installer can request an administrator password. The upgrade command remains
visible and copyable:

```sh
brew upgrade --cask magnetonio/tap/copied
```

**About Copied** in the popover menu, status-item context menu, and application
menu opens Settings directly to About, including when Settings is already open.
Website builds use Sparkle and show update status inline; App Store/TestFlight
builds remain store-managed. Verify updater UI and delegate behavior with
`xcodebuild -project Copied.xcodeproj -scheme CopiedMacDirect -destination 'platform=macOS' test`.

## TestFlight Builds

Release tooling uses the repo's `.ruby-version` (Ruby 3.4.10), not Apple's
deprecated Ruby 2.6 or the shell's Homebrew Ruby. Install and use it with rbenv:

```sh
rbenv install -s "$(cat .ruby-version)"
rbenv exec gem install bundler -v 2.6.9 --no-document
rbenv exec bundle install
rbenv exec bundle exec fastlane ios archive
rbenv exec bundle exec fastlane ios testflight
```

The build and TestFlight driver scripts prepend rbenv shims when available.
For direct `bundle exec` commands, first initialize rbenv in your shell or use
`rbenv exec` as above. Ruby gems are runtime-specific; a bundle installed under
`vendor/bundle/ruby/2.6.0` cannot be reused by Ruby 3.4. Keep the old bundle
available during migration, but do not use it for new releases.
Bundler is locked to 2.6.9. The compatible lockfile uses CFPropertyList 3.0.8:
3.0.9 declares Ruby `< 3.2`, while the current Fastlane/xcodeproj constraints
exclude CFPropertyList 4.0. Keep Fastlane itself locked unless an upgrade is
explicitly needed. A signed iOS archive/export and read-only App Store Connect
query both passed with Ruby 3.4.10 on 2026-10-01.
Preserve old archive/IPA artifacts
outside the active output paths before rebuilding, then verify the exported IPA
and both extensions have the intended build number before uploading. Uploading
to TestFlight does not select the new build for a production version or resubmit
a withdrawn version for App Review.
The iOS export options set `manageAppVersionAndBuildNumber` to false so Xcode
cannot silently increment the exported IPA's build after an earlier upload.

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

Mac screenshot layout sources and status are documented in
`design/app-store/mac/README.md`. Preserve the real UI; do not upload the
AI-edited files under `previews/`. Render the local, gitignored originals with
`swift scripts/render-mac-store-screenshots.swift` to refresh Fastlane's four
2880 x 1800 PNGs. To replace an existing remote Mac screenshot set, use
`bundle exec fastlane mac upload_screenshots replace:true`; it uploads only
screenshots and does not submit for review. Review image content before upload.

The iPhone set uses the same layout conventions. Originals are kept outside
the upload tree in `design/app-store/ios/_original/`; details and review assets
are in `design/app-store/ios/README.md`. Run
`swift scripts/render-ios-store-screenshots.swift` to regenerate four opaque
1320 x 2868 PNGs in `fastlane/screenshots-ios/en-US/`. Use
`bundle exec fastlane ios upload_screenshots replace:true` only after reviewing
the images and preserving any remote-only screenshots that must remain. These
iPhone assets do not replace required iPad captures. The companion iPad set in
`design/app-store/ipad/` uses real 13-inch tablet simulator captures; see its
`README.md` for isolated sample-data setup and capture steps. Run
`swift scripts/render-ipad-store-screenshots.swift` to regenerate four opaque
2752 x 2064 landscape PNGs in the same Fastlane directory. Both renderers are
needed to refresh the full iOS screenshot set. Never stretch iPhone UI into iPad
assets. Ship the iPad sidebar selection fix in a new build before submission.

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

### Mac Review Rejection Follow-up (2026-10-06)

Mac 1.3.3 build 15 was rejected under 2.4.5 (Accessibility access for a global
shortcut) and 2.1(b) (iCloud Sync IAP not submitted). All Mac variants now
use Carbon `RegisterEventHotKey` only: no Accessibility prompt, keyboard event
tap, or synthetic paste. Website builds keep Sparkle and paid-license support.
The shared paste queue only writes clipboard data and advances its index.

The replacement Mac App Store binary is 1.3.3 build 17. The website patch is
1.3.3 build 18, published as `Copied-v1.3.3-build18.pkg` plus the legacy download
alias. Its appcast and Homebrew version (`1.3.3,18`) reference the immutable PKG.
These channel builds are separate; publishing the website does not change the
App Store build selected for review. The shared Carbon shortcut regression also
runs in `CopiedMacDirectTests` alongside `UpdateInterfaceTests`.

After every Mac App Store archive, run:

```sh
zsh scripts/verify-mas-build.sh
```

This validates signature, sandbox, Carbon registration imports, absence of
privileged keyboard/Accessibility imports, and absence of Sparkle. Test the
shortcut and native copy behavior with `GlobalHotkeyTests`,
`MainWindowCopyCommandTests`, and `PasteQueueTests` in the `CopiedMac` scheme.

The existing IAP `6764169200` / `com.magneton.copied.icloud_sync` already has a
completed review screenshot. `READY_TO_SUBMIT` is not submitted. Include the
IAP and the replacement Mac app version in the **same** review submission;
an IAP-only iOS draft does not satisfy Mac review. Inspect the actual draft
items and confirm both are present before final Submit for Review. Do not
cancel or replace the pending iOS app review just to repair the Mac submission.

When a replacement app version is stuck in an old `UNRESOLVED_ISSUES`
submission, it cannot also be added to a separate IAP draft. Remove the app
item from the old submission using the documented review-item `removed:true`
update, wait for that submission to become `COMPLETE`, then add the version
to the new Mac draft. Removal can temporarily reset the app version to
`DEVELOPER_REJECTED`; adding it to the new draft restores `READY_FOR_REVIEW`.
The public API now supports `inAppPurchaseVersion` on review submission items;
retrieve its ID from `/v2/inAppPurchases/6764169200/versions`, not the product ID.
Verify both `appStoreVersion` and `inAppPurchaseVersion` relationships. On
2026-10-06, draft `0de8b82a-a8b3-461e-a321-92e00d95eafc` was prepared with
both items, without submitting it. Recheck live state before further actions.

### iOS Guideline 3.1.1 Follow-up (2026-10-27)

iOS 1.3.3 build 16 was rejected for accepting external license keys. The iOS
app must only use StoreKit purchase/restore for the shared iCloud Sync product.
Do not reintroduce license-entry UI, license URL redemption, or `LicenseStore`
on iOS. The shared license store/validator compile only on macOS; the website
Mac license flow is unchanged. The Open-source Licenses page is attribution,
not a paid unlock.

On iOS, use `PurchaseManager.purchasedKey` everywhere rather than the legacy
`iCloudSyncPurchased` literal. Its iOS-specific StoreKit cache deliberately
ignores the old flag, which could have been set by a license key. StoreKit
reconciliation/restore repopulates the new cache for actual App Store owners;
the existing restart banner applies when the container's sync gate changes.
`SharedStore` also uses a new iOS App Group purchase key, so an extension
launched before the updated host cannot inherit a build-16 license unlock.

Run `zsh scripts/test-ios-purchases.sh SIMULATOR_UDID` on an isolated simulator.
The driver adds a test-only `get-task-allow` entitlement: without it, StoreKitTest
rejects ad-hoc simulator builds as "not installed for development" and falls
back to the real sandbox. Never apply that override to an archive/export.
`CopiedIOSTests` covers the old cache bypass, purchase, restore, absent
entitlement, and refund using the local StoreKit configuration. Then check the
actual archive/export:

```sh
zsh scripts/verify-ios-build.sh build/ios/Copied.ipa
```

The iOS archive and TestFlight lanes run this check automatically to reject
license-unlock code in the app or its extensions. Do not resubmit build 16:
upload a new build, select it on the production version, update the review
notes, and submit only when requested. These local source changes alone do
not modify the existing App Review submission.

The validated October 27 build is 1.3.3 (18), exported to
`build/ios-review-fixed/Copied.ipa`, with five StoreKit tests passing on each
of the dedicated iPhone 17 Pro Max (iOS 26.5) and iPad Air 11-inch (iPadOS 27)
simulators. It was uploaded and processed as `VALID` (build ID
`9c503f07-4d31-442b-bbb6-49d88ac1e2b0`), selected for the iOS production version,
and resubmitted on October 27 at 3:41 PM CDT. Submission
`265b57df-372a-4851-ad7e-d7c77e287deb` is `WAITING_FOR_REVIEW`; a guideline 3.1.1
remediation reply and updated review notes were posted. The exact reply is
saved in `build/ios-review-fixed/app-review-reply.txt`.

Internal TestFlight state is `READY_FOR_BETA_TESTING`; Magneton Labs has
automatic access to all builds. Build 18 was assigned to the existing External
Users group and submitted to Beta App Review on October 27; the beta review
state subsequently became `APPROVED`, with external state `IN_BETA_TESTING`
and automatic tester notifications enabled.
Beta review notes explain the StoreKit-only unlock and purchase navigation.
Internal and external testing are available; beta approval is separate from
the production review. The Mac release and approved shared IAP were not changed.
Verify tester membership as well as build/group assignment before reporting
TestFlight access. On October 27, Magneton Labs had zero testers despite its
automatic build access; the existing Matthew Long tester was restored to that
internal group. A valid distributed build does not restore a missing tester
membership. Do not remove/recreate testers as a routine release step.
The standard `build/ios/` output was preserved and still
contains the old binary; do not upload that artifact or re-upload build 18.

The iOS upload lane accepts `ipa:build/ios-review-fixed/Copied.ipa` (paths are
resolved from the repository root) to publish a verified artifact outside the
standard output location without rebuilding or overwriting preserved archives.
Recheck App Store Connect build numbers before every new upload.

### Build 18 Sync Crash (2026-10-27)

Incident `2950C88D-C0B7-4CD8-8DC4-4F1A29C64567` on iOS 27.2 was an
`EXC_BAD_ACCESS` in `rememberSystemFields(of:)`, on the sync metadata queue.
The build-18 dSYM UUID `3D9ED87B-8CAF-39F7-8BCD-5D97AF6CF23D` matches the
report. Dictionary writes used a queue, but snapshot copies, delegate cache
deletions, and other persisted-state access bypassed it.

The source fix confines all metadata access and encoding to
`SyncEngineStateStore`. Its JSON shape is unchanged; no library reset or
CloudKit wipe is required. Do not access metadata outside its `read`/`update`
closures, or call back into the store from those closures. The state uses
value semantics and is Sendable. Disk writes remain atomic and serialized.

Run `swift test --package-path CopiedKit` and
`swift test --package-path CopiedKit --sanitize=thread`. The four regression
tests also run in both Xcode test bundles. On October 27, those tests passed
under Thread Sanitizer, and all nine iOS tests passed on the dedicated iPhone
and iPad simulators. The Mac suite passed 68 tests before the additional
keyboard-navigation coverage. A Mac test host requires Apple Development
signing, not ad-hoc signing, because its entitlements include CloudKit.

The crash fix is included in the build-19 archives documented below; the
existing build-18 IPA still contains the old code. Never re-upload the old IPA
as a crash fix. The Mac Debug test
host uses an in-memory container and skips startup services when XCTest is
loaded, so focused UI tests do not start live sync or clipboard monitoring.
Tests that write to the general pasteboard can still be captured by an
already-running installed copy of Copied; use an isolated test environment.

### Main Window Keyboard Scrolling (2026-10-27)

Up/down navigation was reported to jump when reaching the visible-list
boundary; mouse scrolling was unaffected. The main window's All Clippings,
Favorites, Trash, and custom-list views now reveal single selections through
`MainWindowSelectionScrollAnchor`, using the persistent model ID and
`ScrollViewProxy.scrollTo` without an anchor (minimum necessary movement).
Native keyboard selection and modified keys remain in control of the List;
do not intercept arrows and manually replace the selection.

`MainWindowKeyboardNavigationTests` exercises the full split window with 200
mixed-height, image-containing clippings in a temporary on-disk store. It
checks adjacent selection, full row visibility, and bounded scroll movement
across 150 rows down and back up. The final targeted Mac run passed all nine
tests, including keyboard scrolling, native/control-C copy, the global hotkey,
and sync-state persistence (`build/mac-sync-keyboard-final.xcresult`). These
changes are included in the Mac 1.3.4 (19) upload documented below. No local
installation was performed as part of that release.

### Aligned 1.3.4 (19) Release (2026-10-27)

The Mac 1.3.3 (19) upload was rejected because the approved 1.3.3 release
train is closed. Its rejected artifacts are preserved under
`build/preserved/20261027-pre19/mac-1.3.3-build19-rejected/`.

Mac 1.3.4 (19), build ID `7d18394f-3ab8-448f-be35-27059622c899`, is `VALID`
and available for internal TestFlight testing. It is assigned to External
Users and waiting for Beta App Review. Its production version ID is
`6f49bc04-173a-4349-a9ad-7d5f869a6079`; submission
`7baa073b-5589-4f27-8cb2-cc7a87de53f0` was submitted October 27 at 6:04 PM CDT
and is `WAITING_FOR_REVIEW`, with automatic release after approval. Do not
cancel or recreate that Mac submission while aligning iOS.

The Mac PKG is `build/mas/Copied.pkg`, SHA-256
`fac6cb1a8ab4eb4357f26160b6cd2fa84494ce3ec40d4a807fbd15c11813d1dc`.
Mac 1.3.3 remains live in the US App Store, independently confirmed with
Apple's public lookup API on October 27.

The first crash-fixed iOS upload was 1.3.3 (19), uploaded at 5:53 PM CDT.
It was still processing when the user requested matching marketing versions;
its local artifacts are preserved in
`build/preserved/ios-1.3.3-build19-pre-alignment/`. Do not select that earlier
version when preparing the aligned release.

The replacement iOS archive/export is 1.3.4 (19), including both extensions.
`build/ios/Copied.ipa` passed signing and license-code checks and was uploaded
successfully at 6:16 PM CDT. Its SHA-256 is
`185f8b7cf10cf94ef68395823e0cd811138fca946c2417a9a6627e1e95eb0e67`.
The four sync-state regression tests passed again after alignment. Apple
processed it as `VALID`, build ID `69d974c5-fe48-4f64-b8cb-1f010aa233e7`.
It is available for internal TestFlight testing and assigned to External Users,
with automatic notification enabled and external state
`WAITING_FOR_BETA_REVIEW`. Never re-upload this version/build pair.

At the user's request, only the old iOS submission
`265b57df-372a-4851-ad7e-d7c77e287deb` was withdrawn. The existing iOS version
record `e37d5871-d005-425e-ae7a-6b5011a5dced` was updated to 1.3.4 and the
validated build 19 selected. All four iPhone and four iPad screenshots remain
`COMPLETE`; purchase metadata and review contacts were preserved. Review notes
identify the sync-crash fix and retain StoreKit-only purchase instructions.

The replacement iOS submission `1dae9589-0bc6-4edb-a082-ab5d9de66d92` was
submitted October 27 at 6:21:48 PM CDT and is `WAITING_FOR_REVIEW`, with automatic
release after approval. The actual web draft was checked before submission.
Both iOS and Mac production versions now select **1.3.4 (19)** and are waiting
for review; the Mac submission was unchanged. API verification is saved in
`build/aligned-review/submitted-1.3.4-build19.json`, and the matching screenshot
is `build/aligned-review/both-platforms-1.3.4-submitted.png`.

Apple completed processing of the earlier iOS 1.3.3 (19) upload after the
1.3.4 upload, so the UI displayed a misleading "Newer Build Available" warning.
The API confirmed that the later timestamp belonged to the old 1.3.3 train,
not a newer 1.3.4 binary. The selected production build is the verified 1.3.4
build above; do not replace it with 1.3.3 (19).

No website PKG, GitHub release, appcast, or Homebrew update was published in
this alignment step. Changing `CopiedMacDirect`'s source version does not ship
that channel. The existing approved shared IAP remains unchanged.

### Mac App Store Search Visibility (2026-10-27)

Apple Developer Support case `103010858251` was submitted under Distribution
-> App Store Search and Discoverability. The released Mac 1.3.3 listing opens
with Get and Works on this Mac, but exact-name native search did not surface
it in the results checked. Public distribution, 175 Available regions, and
unrestricted search filters were verified. Apple's US Search API returned the
app, which does not establish its native search ranking. The cause remains
unconfirmed; do not describe the issue as intentional suppression or resolved.
The form had no attachment field. The exact request, confirmation screenshot,
and original search screenshot are preserved in `build/apple-search-support/`
for follow-up. Filing the case did not change either pending 1.3.4 review.

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
