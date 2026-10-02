# iPhone App Store Screenshots

## Assets

- `_original/`: unchanged real 1320 x 2868 iPhone captures, kept outside the
  Fastlane upload tree so backups cannot be uploaded by accident.
- `final/`: the four matching App Store compositions, using only real UI.
- `overview.png`: a contact sheet for reviewing the set, not an upload image.
- `Copied-iPhone-App-Store-Screenshots.zip`: the four final PNGs for manual upload.
- `fastlane/screenshots-ios/en-US/`: identical copies for Fastlane upload.

The pale-gray background, system typography, charcoal headlines, and muted
supporting copy match the Mac screenshot set. The full capture is proportionally
scaled with rounded corners and a restrained shadow. Status, navigation,
search controls, text, and settings states are retained; no UI is synthesized.
Exports are opaque, no-alpha sRGB PNGs at 1320 x 2868, accepted for Apple's
6.9-inch iPhone display slot. They can supply the scaled 6.5-inch set as shown
in App Store Connect. The companion iPad set is documented in
`../ipad/README.md`; it uses actual tablet captures, not stretched phone UI.

## Copy

| Capture | Headline | Supporting Copy |
| --- | --- | --- |
| Main list | Your clipboard, organized. | Save text, links, and code. Keep them ready to reuse. |
| Clipping detail | Keep useful snippets close. | Review, edit, and reuse saved text and code. |
| Settings | Make Copied your own. | Adjust your preferences. Keep your workflow in focus. |
| Search | Find it. Use it again. | Search your clippings without the scrolling. |

The settings capture shows iCloud Sync disabled. Its caption deliberately does
not imply an active connection. Content and timestamps reflect the original
captures rather than fresh app-version QA. For publication, new captures with
representative sample content can replace these originals without changing
the layout. Keep their dimensions at 1320 x 2868.

## Render

Run from the repository root on macOS:

```sh
swift scripts/render-ios-store-screenshots.swift design/app-store/ios/final
swift scripts/render-ios-store-screenshots.swift
```

The first command writes the design deliverables; the second updates only
Fastlane's iPhone PNGs. The renderer never writes to the originals and validates
all four inputs before replacing upload assets.

## Upload

After reviewing the exports and resolving any Apple agreement blocker:

```sh
bundle exec fastlane ios upload_screenshots replace:true
```

This replaces the remote iOS screenshot sets with the local files and does not
upload a binary, edit metadata, or submit for review. Before running, download
any remote-only screenshots you need to retain and put them in the local upload
directory. With no `replace:true`, the lane retains its previous append behavior.
No upload has been performed as part of creating this set.

Apple screenshot requirements:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
