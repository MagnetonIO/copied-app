# Copied

A modern clipboard manager for macOS built with SwiftUI and SwiftData.

## Features

- **Clipboard Monitoring** — Automatically captures text, URLs, images, rich text, and HTML from the system clipboard
- **Code Snippet Detection** — Auto-detects code in clipboard with language identification (Swift, Python, JS, Go, Rust, and 20+ languages)
- **Fuzzy Search** — Sublime Text-style fuzzy matching with highlighted results
- **Smart Paste / Transformations** — "Copy As…" menu with UPPERCASE, lowercase, JSON format/minify, URL encode/decode, strip markdown, and more
- **Content Type Filtering** — Filter by Text, Rich Text, Image, Link, or Code
- **Global Hotkey** — ⌃⇧C to toggle the popover from anywhere
- **Keyboard Navigation** — Arrow keys to navigate, Enter to copy, ⌘1–⌘9 for quick paste
- **Favorites & Pinning** — Star important clippings, pin items to the top
- **iCloud Sync** — Sync clipboard history across Macs via CloudKit
- **Sync Status** — Real-time sync indicator showing Importing/Exporting/Synced status
- **Image Thumbnails** — Efficient thumbnail cache using `CGImageSourceCreateThumbnailAtIndex`
- **Trash & Restore** — Soft-delete with restore capability
- **Lists** — Organize clippings into collections
- **Menu Bar App** — Lives in the menu bar, no Dock icon by default
- **Settings** — Configurable history size, capture preferences, excluded apps, appearance

## Architecture

```
CopiedKit/          — Shared framework (models, services, views)
  Models/           — SwiftData models (Clipping, ClipList, Asset)
  Services/         — ClipboardService, CodeDetector, FuzzyMatcher, TextTransform, SyncMonitor, ThumbnailCache
  Views/            — ClippingDetail, ClippingRow

CopiedMac/          — macOS app target
  App/              — AppDelegate, GlobalHotkeyManager, StatusBarController, PermissionManager
  MenuBar/          — PopoverView, PopoverClippingCard
  Windows/          — MainWindowView (three-column layout)
  Views/            — SettingsView, ClippingEditSheet

CopiedIOS/          — iOS app target (placeholder)
```

## Requirements

- macOS 15.0+
- Xcode 16+
- Swift 6

## Building

```bash
# Debug build (unsigned)
xcodebuild -project Copied.xcodeproj -scheme CopiedMac build CODE_SIGNING_ALLOWED=NO

# Release build (signed, for testing)
xcodebuild -project Copied.xcodeproj -scheme CopiedMac \
  -configuration Release \
  DEVELOPMENT_TEAM=7727LYTG96 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates build

# Create DMG
hdiutil create -volname "Copied" \
  -srcfolder ~/Library/Developer/Xcode/DerivedData/Copied-*/Build/Products/Release/Copied.app \
  -ov -format UDZO build/Copied.dmg
```

## iCloud Sync

Uses CloudKit container `iCloud.com.mlong.copied` with SwiftData's automatic sync. Both devices must be signed into the same iCloud account.

## License

Proprietary — Magneton Labs, LLC
