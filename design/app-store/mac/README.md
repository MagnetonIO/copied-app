# Mac App Store Screenshot Layouts

## Status

`final/` contains four deterministic compositions using the real source
screenshots. These also replace the local `fastlane/screenshots/en-US/*.png`
upload assets. Nothing has been uploaded to Apple. The original captures in
`fastlane/screenshots/en-US/_original/` are unchanged.

`previews/` contains the earlier built-in image generation layout experiments,
not production screenshots. Its output is not pixel-exact and must not be
uploaded. The final set uses AppKit/Core Graphics, only cropping, proportional
resizing, window-silhouette masking, headings, and layout. No controls, app text,
icons, or states are synthesized or replaced.

The source captures include a 1.2.0 clipping and local development paths. These
are preserved rather than edited out of the UI. Before publication, fresh
captures with non-personal sample content and a selected clipping in the main
window would improve the content further. The originals are local, gitignored
inputs; a fresh checkout needs these source captures before rendering.

## Render And Upload

From the repo root, on macOS:

```sh
swift scripts/render-mac-store-screenshots.swift design/app-store/mac/final
swift scripts/render-mac-store-screenshots.swift
```

The first command renders to the design folder; the second renders to Fastlane's
Mac screenshot directory. Original dimensions and crop bounds are validated.
When replacing the captures, update the crop rectangles in the renderer to
match the new window positions.

To explicitly replace the remote Mac screenshot set without uploading a build,
editing metadata, or submitting for review:

```sh
bundle exec fastlane mac upload_screenshots replace:true
```

Review the final set first and resolve any Apple agreement blocker. The upload
lane keeps its append behavior unless `replace:true` is explicitly provided.

## Layout And Copy

All final images are opaque sRGB PNGs rendered to 2880 x 1800 (16:10), an accepted
Mac screenshot size. Proportional resizing does not increase original detail.

| File | Headline | Supporting Copy |
| --- | --- | --- |
| `01_main_window.png` | Your clipboard, organized. | Keep text, links, and images ready to reuse. |
| `02_popover.png` | Ready when you need it. | Search and reuse clippings from your menu bar. |
| `03_sync_active.png` | Your clippings, across devices. | Keep your library together with iCloud Sync. |
| `04_clipboard_settings.png` | Capture what matters. | Choose what Copied saves and which apps to exclude. |

## Prompt Set

Common brief used for all four built-in image edits:

- Compositing edit of the corresponding real capture, one landscape screenshot.
- Plain pale-gray `#F3F5F6` background, centered charcoal headline and smaller
  medium-gray subtitle in native system-style type with zero letter spacing.
- Remove desktop wallpaper and the macOS menu bar outside the application.
- Enlarge the complete application window below the heading; preserve native
  proportions, full window edges, and the visible contents. Add a subtle shadow.
- Treat the app UI as a locked bitmap, with no invented or altered controls,
  icons, text, states, or rows. This invariant was not fully achieved by the tool.
- No device frames, decorative elements, gradients, badges, or watermark.

Image-specific briefs:

1. Main window: complete three-column window, large and centered, with header
   occupying roughly the top 23 percent. Use the first row's copy above.
2. Popover: extract only the complete menu-bar popover, including footer;
   center below the header at roughly 77 percent of the canvas height. Use the
   main-window preview as the typography/background style reference only.
3. Sync: extract only the foreground Settings window with Sync selected; remove
   the background main window. Center at roughly 72 percent of canvas height.
   Preserve the sync state and labels from the original capture.
4. Clipboard: extract the complete Settings window with Clipboard selected;
   center at roughly 72 percent of canvas height, preserving capture toggles,
   Excluded Apps, and Add App. Use the main preview as the style reference only.

Before final upload, inspect every full-resolution image, verify current UI and
sample content, and ensure headings, controls, and windows are not clipped.
