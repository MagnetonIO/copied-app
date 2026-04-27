# Copied

A modern clipboard manager for macOS and iOS built with SwiftUI and SwiftData. Syncs clipboard history across devices via iCloud.

## Platforms

- **macOS 15.0+** — Menu bar app with global hotkey, fuzzy search, smart paste, and full keyboard navigation.
- **iOS 18.0+** — Companion app with Share Extension ("Save to Copied") and Action Extension ("Copied Clipper") for capturing content from any app.

## Features

### Cross-platform
- **iCloud Sync** — Clipboard history syncs across all your Macs and iOS devices automatically
- **Clipboard Monitoring** — Automatically captures text, URLs, images, rich text, and HTML
- **Code Snippet Detection** — Auto-detects code with language identification (25+ languages)
- **Fuzzy Search** — Sublime Text-style fuzzy matching with highlighted results
- **Smart Paste / Transformations** — "Copy As…" menu with case transforms, JSON format/minify, URL encode/decode, strip markdown, and more
- **Content Type Filtering** — Filter by Text, Rich Text, Image, Link, or Code
- **Favorites & Pinning** — Star important clippings, pin items to the top
- **Trash & Restore** — Soft-delete with restore capability
- **Lists** — Organize clippings into collections

### macOS only
- **Global Hotkey** — ⌃⇧C to toggle the popover from anywhere
- **Keyboard Navigation** — Arrow keys to navigate, Enter to copy, ⌘1–⌘9 for quick paste
- **Menu Bar App** — Lives in the menu bar, no Dock icon by default

### iOS only
- **Share Extension** — Save anything from any app via the system share sheet ("Save to Copied")
- **Action Extension** — One-tap "Copied Clipper" action for fast capture without opening the app

## Requirements

- **macOS:** 15.0 (Sequoia) or later — Apple Silicon & Intel
- **iOS:** 18.0 or later — iPhone & iPad
- Active iCloud account on every device for sync
- Xcode 16+ and Swift 6 to build from source

## TestFlight (1.3.0)

Both Mac and iOS apps are available via TestFlight. See the Linear task in the `copied-app` team for tester invite + install steps.

## Building

```bash
# Debug build (macOS)
xcodebuild -project Copied.xcodeproj -scheme CopiedMac build CODE_SIGNING_ALLOWED=NO

# Debug build (iOS Simulator)
bundle exec fastlane ios dev_build

# Mac App Store TestFlight (signed, uploaded)
bundle exec fastlane mac mas_build
bundle exec fastlane mac testflight

# iOS TestFlight (signed, uploaded)
bundle exec fastlane ios archive
bundle exec fastlane ios testflight

# Both at once
scripts/release-testflight.sh
```

## Architecture

```
CopiedKit/                  — Shared framework (models, services, views)
  Models/                   — SwiftData models (Clipping, ClipList, Asset)
  Services/                 — ClipboardService, CodeDetector, FuzzyMatcher, TextTransform, SyncMonitor, CopiedSyncEngine
  Views/                    — ClippingDetail, ClippingRow

CopiedMac/                  — macOS app target
  App/                      — AppDelegate, GlobalHotkeyManager, StatusBarController
  MenuBar/                  — PopoverView, PopoverClippingCard
  Windows/                  — MainWindowView (three-column layout)
  Views/                    — SettingsView

CopiedIOS/                  — iOS app target
CopiedShareExtension/       — iOS Share Extension ("Save to Copied")
CopiedClipperExtension/     — iOS Action Extension ("Copied Clipper")
```

## iCloud Sync

Clipboard history syncs automatically across all your Macs and iOS devices via iCloud. Every device must be signed into the same iCloud account. Each user's data is private — stored in their own iCloud account; never touches our servers.

## License

Proprietary — Magneton Labs, LLC

## 💰 Bounty Contribution

- **Task:** Manual ASC web items required before submitting Copied 1.3.0 for App Store revie
- **Reward:** $5
- **Source:** GitHub-Paid
- **Date:** 2026-04-28

