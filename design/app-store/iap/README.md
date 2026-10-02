# iCloud Sync IAP assets

Created October 1, 2026. These are local files; no App Store Connect upload,
purchase, review submission, or account-setting change was performed.

## Which file goes where

| File in `final/` | Dimensions | App Store Connect field |
| --- | --- | --- |
| `icloud-sync-promotional-1024.png` | 1024 x 1024 | **Image (Optional)** on the iCloud Sync IAP record |
| `mac-icloud-sync-review.png` | 1440 x 900 | **Review Information > Screenshot**, Mac-only capture |
| `ios-icloud-sync-review.png` | 1320 x 2868 | **Review Information > Screenshot**, iPhone capture |
| `mac-ios-icloud-sync-review.png` | 2880 x 1800 | Reviewer-only comparison of both platforms for the shared IAP record |

The optional image is conceptual promotional artwork, not an app screenshot.
The review images show the actual production purchase views with the $4.99 US
price and Restore Purchases visible. All final PNGs are flattened RGB without
alpha. The promotional PNG is tagged at 72 dpi.

Apple asks for a review screenshot that shows the item/service being offered
and uses a screenshot size the app supports. Its promotional-image guidance
asks for a separate 1024 x 1024 graphic, distinct from screenshots and the app
icon, without text overlays or important detail in the lower-left icon area:

- [In-App Purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)
- [Promoting In-App Purchases](https://developer.apple.com/app-store/promoting-in-app-purchases/)

## Review warning

The production iOS paywall currently promises restoration of a family member's
purchase. The previously inspected App Store Connect IAP record had Family
Sharing disabled, and `Copied.storekit` also has `familyShareable: false`.
The capture intentionally preserves this real UI. Resolve the mismatch before
using the iOS or combined screenshot for review: either enable Family Sharing
after considering Apple's permanent-setting implications, or change the app's
claim and recapture. No Family Sharing settings were changed here.

These screenshots do not demonstrate a completed App Store purchase, restore,
cross-device entitlement, or iCloud Sync test.

## Capture provenance

The capture hosts compile the unmodified production views:

- macOS: `CopiedMac/Views/SettingsView.swift`, with MAS_STOREFRONT enabled.
- iOS: `CopiedIOS/Views/SyncScreen.swift` and `DesignTokens.swift`.
- Both use the real `CopiedKit.PurchaseManager` and repository `Copied.storekit`.

Distinct bundle IDs isolate preferences from the user's real Copied app.
The Mac host uses an in-memory, non-CloudKit model container and does not start
clipboard monitoring or SyncMonitor. The iOS host runs on a fresh simulator,
without a signed-in account, clipboard database, or share extensions.

Regenerate the capture-only project from the repository root:

```sh
mkdir -p build/iap-capture
xcodegen generate --spec design/app-store/iap/capture-project.yml --project build/iap-capture
```

Open `build/iap-capture/CopiedIAPCapture.xcodeproj` in Xcode. Run the
`MacIAPCapture` scheme on My Mac and `IOSIAPCapture` on a dedicated iPhone
16 Pro Max simulator. The schemes attach `Copied.storekit` to the Run action.
Wait for the real localized price to appear; do not press Unlock or Restore.

On this machine, CLI-only SKTestSession initialization could not load the
product; running through the Xcode IDE's attached configuration worked.
The final assets were captured from successful IDE-launched hosts, not from
the failed CLI test attempt. Mac capture used Computer Use's native app-window
capture. iOS capture used `simctl io <dedicated-device-uuid> screenshot`.

The originals remain in `_original/`. The renderer only crops the Mac capture
host title bar/excess blank space, adds neutral margins, resizes proportionally,
and adds platform labels outside the real UI in the comparison image. It never
adds, removes, or repaints purchase controls or price text.

```sh
sh design/app-store/iap/render-assets.sh
```

## Promotional image provenance

Generated with the built-in `image_gen.imagegen` tool. Original saved as
`_original/icloud-sync-generated.png`, then proportionally resized and flattened
to 1024 x 1024. No production UI was generated or modified by AI.

Prompt:

> Use case: ads-marketing. Create one finished 1024 x 1024 square promotional image for the Copied app's iCloud Sync one-time in-app purchase, for Apple App Store Connect's optional promotional image field. This is conceptual promotional artwork, NOT an app screenshot. Clean premium Apple-platform productivity illustration: a large crisp white cloud is the central subject, with two elegant teal directional synchronization arrows forming an open circular loop around it. Beneath the cloud, three small orderly document clipping sheets indicate shared saved content; subtly include minimal thin outlines of a laptop, tablet, and phone integrated into the lower-center composition so the subject reads as cross-device clipboard sync. Soft near-white neutral background, refined jade and teal accents, restrained dimensional edge highlights and shallow shadows, excellent visual clarity at thumbnail sizes, centered graphic with generous margins and empty lower-left corner for the App Store's app-icon overlay. Use the Copied brand's clean teal/white visual language but DO NOT reproduce or incorporate its app icon or any Apple logo. No text, no letters, no prices, no call-to-action, no words, no badges, no watermarks. No UI panels, fabricated screenshots, card border, outer rounded corners, noisy gradients, floating decorative orbs, or bokeh. Opaque image fills all edges; exactly square.
