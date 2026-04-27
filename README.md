# Copied

A modern clipboard manager for macOS built with SwiftUI and SwiftData.

## Features

- **Clipboard Monitoring** — Automatically captures text, URLs, images, rich text, and HTML
- **Code Snippet Detection** — Auto-detects code with language identification (25+ languages)
- **Fuzzy Search** — Sublime Text-style fuzzy matching with highlighted results
- **Smart Paste / Transformations** — "Copy As…" menu with case transforms, JSON format/minify, URL encode/decode, strip markdown, and more
- **Content Type Filtering** — Filter by Text, Rich Text, Image, Link, or Code
- **Global Hotkey** — ⌃⇧C to toggle the popover from anywhere
- **Keyboard Navigation** — Arrow keys to navigate, Enter to copy, ⌘1–⌘9 for quick paste
- **Favorites & Pinning** — Star important clippings, pin items to the top
- **iCloud Sync** — Sync clipboard history across your Macs automatically
- **Sync Status** — Real-time indicator showing sync activity
- **Trash & Restore** — Soft-delete with restore capability
- **Lists** — Organize clippings into collections
- **Menu Bar App** — Lives in the menu bar, no Dock icon by default
- **Settings** — Configurable history size, capture preferences, excluded apps, appearance

## Requirements

- macOS 15.0+
- Xcode 16+
- Swift 6

## Building

```bash
# Debug build
xcodebuild -project Copied.xcodeproj -scheme CopiedMac build CODE_SIGNING_ALLOWED=NO

# Create DMG
hdiutil create -volname "Copied" \
  -srcfolder ~/Library/Developer/Xcode/DerivedData/Copied-*/Build/Products/Release/Copied.app \
  -ov -format UDZO build/Copied.dmg
```

## Architecture

```
CopiedKit/          — Shared framework (models, services, views)
  Models/           — SwiftData models (Clipping, ClipList, Asset)
  Services/         — ClipboardService, CodeDetector, FuzzyMatcher, TextTransform, SyncMonitor
  Views/            — ClippingDetail, ClippingRow

CopiedMac/          — macOS app target
  App/              — AppDelegate, GlobalHotkeyManager, StatusBarController
  MenuBar/          — PopoverView, PopoverClippingCard
  Windows/          — MainWindowView (three-column layout)
  Views/            — SettingsView

CopiedIOS/          — iOS app target (planned)
```

## iCloud Sync

Clipboard history syncs automatically across all your Macs via iCloud. Both devices must be signed into the same iCloud account. Each user's data is private — stored in their own iCloud account.

## License

Proprietary — Magneton Labs, LLC

## 💰 Bounty Contribution

- **Task:** Manual ASC web items required before submitting Copied 1.3.0 for App Store revie
- **Reward:** $5
- **Source:** GitHub-Paid
- **Date:** 2026-04-28

