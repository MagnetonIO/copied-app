# iPad App Store Screenshots

## Assets

- `_original/`: real, full-screen 13-inch iPad Pro (M5) simulator captures.
- `final/`: four opaque, no-alpha sRGB PNGs at 2752 x 2064.
- `overview.png`: contact sheet for review, not for upload.
- `Copied-iPad-App-Store-Screenshots.zip`: the four final PNGs for manual upload.
- `fastlane/screenshots-ios/en-US/05_ipad_*.png` through `08_ipad_*.png`:
  identical upload copies alongside the four iPhone images.

These use the same background, typography, captions, and restrained framing as
the iPhone and Mac sets. The full tablet capture is proportionally scaled, not
stretched from an iPhone image. Sidebar, system bars, content, and settings states
are preserved. The landscape dimensions are accepted for Apple's required
13-inch iPad screenshot slot. No UI is generated or reconstructed.

The four views are the main library, a saved Swift snippet, Settings, and search
results for `Swift`. iCloud Sync is disabled in the clean simulator and is not
represented as active or verified. Only sample content is used.

## Capture

The iOS target is universal (`TARGETED_DEVICE_FAMILY: "1,2"`) and supports
iPadOS 18 or later. Regular-width navigation uses `NavigationSplitView`.
Use an isolated simulator, without an Apple account, for capture:

```sh
xcrun simctl create 'Copied iPad App Store screenshots' \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0
xcrun simctl boot SIMULATOR_UUID
xcrun simctl bootstatus SIMULATOR_UUID -b
xcodebuild -project Copied.xcodeproj -scheme CopiedIOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
xcrun simctl install SIMULATOR_UUID PATH_TO_DEBUG_SIMULATOR_COPIED_APP
ruby scripts/seed-ios-screenshot-inbox.rb SIMULATOR_UUID
xcrun simctl status_bar SIMULATOR_UUID override --time '9:41' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --batteryState charged --batteryLevel 100
xcrun simctl launch SIMULATOR_UUID com.magneton.copied
```

Keep simulator signing enabled; an unsigned app may crash when accessing
CloudKit. The seeder refuses ordinary simulators and real app containers. It
writes the real ShareInbox JSON format; Copied imports through its normal
foreground pipeline. Do not sign into iCloud or use a customer's library.

Xcode 27's simulator UI is Device Hub, located at
`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`
(`com.apple.dt.Devices`). Use its rotation control for landscape. Dismiss the
first-run paste hint, deny any request to import the host clipboard, create a
sample `Work` list, and favorite the `Swift` clipping using the actual UI.
Wait for launch, rotation, keyboard, and sheet animations to finish before
capturing. Capture these states with `xcrun simctl io SIMULATOR_UUID screenshot`:

| Filename | View |
| --- | --- |
| `05_ipad_main_list.png` | Copied library, with the sidebar visible |
| `06_ipad_clipping_detail.png` | Swift clipping detail, keyboard hidden |
| `07_ipad_settings.png` | Settings sheet over the library |
| `08_ipad_search.png` | Search for Swift, submit to hide the keyboard |

Write captures to `_original/`, outside the upload tree. Shut down and delete
only the isolated simulator when done. Never erase a user's existing simulator.

## Render And Upload

From the repository root on macOS:

```sh
swift scripts/render-ipad-store-screenshots.swift design/app-store/ipad/final
swift scripts/render-ipad-store-screenshots.swift
magick montage -font /System/Library/Fonts/Helvetica.ttc -set label '' \
  design/app-store/ipad/final/*.png -thumbnail 688x516 -tile 2x2 \
  -geometry +10+10 -background '#F3F5F6' design/app-store/ipad/overview.png
zip -j design/app-store/ipad/Copied-iPad-App-Store-Screenshots.zip \
  design/app-store/ipad/final/*.png
```

The renderer checks the entire source set before writing and does not touch
iPhone PNGs or originals. Upload the four PNGs in the iPad 13-inch slot, or use
`bundle exec fastlane ios upload_screenshots replace:true` after reviewing the
complete local iPhone and iPad sets and preserving any remote-only assets.
This lane does not submit for review. No upload is part of screenshot creation.

## Verification Scope

Simulator smoke checks cover launch, sample import, persistence across relaunch,
list creation, favoriting, sidebar switching, clipping detail, search, Settings,
and both orientations. The sidebar selection binding was corrected during this
work. iOS 1.3.3 (16) containing the fix was uploaded on 2026-10-01 and verified
as VALID in App Store Connect. Select that build for the production version
before resubmission; uploading to TestFlight does not perform that step.
Physical-device testing, purchases, and cross-device iCloud sync are separate
release checks, not established by these images.

Validated on 2026-10-01 with a signed Debug simulator build on iPadOS 27.0.
The build succeeded, all four final PNGs have three-channel sRGB pixels with no
alpha, upload copies match byte-for-byte, and the ZIP integrity check passed.
The simulator used for these captures was isolated from the user's library.

An existing footer count issue remains: an empty custom list can display the
global clipping count even though its content correctly says No Clippings.
This is separate from the corrected sidebar routing and should be checked
before production release. Compact-width iPhone navigation was not retested
after the sidebar-only change.

Apple screenshot requirements:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
