# Copied.app Reverse Engineering Analysis

## Application Overview

| Field | Value |
|-------|-------|
| **Bundle ID** | `com.udoncode.copiedmac` |
| **Version** | 4.0.1 (build 407) |
| **Developer** | udonCODE (2015-2020) |
| **Architecture** | x86_64 only (Mach-O) — runs via Rosetta on Apple Silicon |
| **Min OS** | macOS 10.14 |
| **Built with** | Xcode 11.6, macOS 10.15 SDK, Swift 5.2 |
| **Language** | Objective-C + Swift (mixed, CD-prefix = ObjC, some Swift classes) |
| **App Sandbox** | Yes (Mac App Store distribution) |
| **AppleScript** | Enabled (Copied.sdef) |

## Technology Stack

### Frameworks & Libraries
| Library | Purpose |
|---------|---------|
| **Realm** (Obj-C) | Primary data storage — `copied.realm` in Group Container |
| **CoreData** | Legacy/migration only — `datastore` SQLite in Group Container |
| **CloudKit** | iCloud sync (`iCloud.com.udoncode.copied`) |
| **ShortcutRecorder** 2.17 | Global hotkey recording UI |
| **PTHotKey** 1.6 | Global hotkey registration |
| **NSLogger** 1.9 | Debug logging |
| **JavaScriptCore** | Template/merge/format script execution |
| **LinkPresentation** | URL metadata/preview fetching |
| **AudioToolbox** | Sound effects (0.caf–9.caf, error.caf) |

### Data Storage Locations
```
~/Library/Group Containers/3DZ6694B2C.group.udoncode.copied/
├── copied.realm              # PRIMARY DATABASE (~486MB in your case)
├── copied.realm.lock
├── copied.realm.management/
├── copied.realm.note
├── assets/                   # 330 asset files (images, files)
├── datastore                 # Legacy CoreData SQLite (pre-Realm migration)
├── datastore-shm
├── datastore-wal
├── logs/
└── Library/

~/Library/Containers/com.udoncode.copiedmac/     # App sandbox container
~/Library/Preferences/com.udoncode.copiedmac.plist  # UserDefaults
~/Library/Mobile Documents/iCloud~com~udoncode~copied/  # iCloud Drive
```

## Data Model (Realm)

### Entity: Clipping (Primary Key: `clippingID`)
| Property | Type | Notes |
|----------|------|-------|
| `clippingID` | String | Primary key, format: `C-{UUID}` |
| `text` | String? | Plain text content |
| `customTitle` | String? | User-editable title |
| `url` | String? | URL if clipping is a link |
| `urlName` | String? | Display name for URL |
| `sourceURL` | String? | Where clipping was copied from |
| `image` | Data? | Image data (thumbnail/inline) |
| `video` | Data? | Video data |
| `files` | Data? | File references |
| `items` | Data? | Serialized NSPasteboardItem array |
| `types` | String? | UTI types (comma-separated or serialized) |
| `style` | Data? | Rich text styling (NSAttributedString archive) |
| `copiedStyle` | String? | Template-processed style |
| `copiedTemplate` | String? | Applied template name |
| `addDate` | Date | When clipping was created |
| `copiedDate` | Date? | When clipping was copied to clipboard |
| `deleteDate` | Date? | Soft-delete timestamp (trash) |
| `modifiedDate` | Date? | Last modification date |
| `deviceName` | String? | Device that created the clipping |
| `dataTypes` | String? | Data type descriptors |
| `pasteboardIndex` | Int | Position in paste queue |
| `listIndex` | Int | Position in list |
| `color` | Int | Color tag |
| `sync` | Bool | CloudKit sync flag |
| `recordSystemFields` | Data? | CKRecord system fields for sync |
| `formattedText` | String? | Ignored property (computed) |
| `transformedText` | String? | Text after JS transform |
| `deleted` | Date? | Deletion marker |
| `permaDeleted` | Bool? | Permanent deletion flag |
| `imageWidth` | Double | Image dimensions |
| `imageHeight` | Double | Image dimensions |
| `icon` | Data? | App icon data |
| `appName` | String? | Source app name |
| **list** | List? | → List relationship |
| **assets** | RLMArray\<Asset\> | → Asset relationship |

### Entity: List (Primary Key: `listID`)
| Property | Type | Notes |
|----------|------|-------|
| `listID` | String | Primary key |
| `name` | String | List display name |
| `color` | Int | Color hex value |
| `sortBy` | Int | Sort type enum |
| `index` | Int | Display order |
| `root` | Bool | Whether this is the root/default list |
| `recordSystemFields` | Data? | CKRecord for sync |
| `sync` | Bool | CloudKit sync flag |
| `modifiedDate` | Date? | Last modification |
| **clippings** | RLMLinkingObjects | ← Clipping inverse relationship |

### Entity: Asset (Primary Key: `assetID`)
| Property | Type | Notes |
|----------|------|-------|
| `assetID` | String | Primary key |
| `filename` | String | File name in assets/ directory |
| `modifiedDate` | Date? | Last modification |
| `recordSystemFields` | Data? | CKRecord for sync |
| `sync` | Bool | CloudKit sync flag |
| **clippings** | RLMLinkingObjects | ← Clipping inverse relationship |

### Entity: Meta
| Property | Type | Notes |
|----------|------|-------|
| `stamp` | Date? | Metadata timestamp |

### Core Data Migration History
```
Copied.mom → CopiedV2.mom → CopiedV3.mom → CopiedV4.mom (current)
```
V3 added `Meta` entity. V4 modified `Clipping` and `List` schemas.

## Architecture

### Window Controllers
| Controller | Purpose |
|------------|---------|
| `CDCopiedWindowController` | Main app window |
| `CDClipboardWindowController` | Clipboard content viewer (Swift) |
| `CDFullWindowController` | Full/expanded view mode |
| `CDPreferencesWindowController` | Preferences (tabbed) |
| `CDListWindowController` | List management |
| `CDManageListWindowController` | List organization |
| `CDMergeWindowController` | Merge clippings UI |
| `CDScriptBrowserWindowController` | Script browser |
| `CDAboutWindowController` | About window |

### View Controllers
| Controller | Purpose |
|------------|---------|
| `CDClippingsViewController` | Main clippings list |
| `CDCompactClippingsViewController` | Compact mode clippings |
| `CDFullClippingsViewController` | Full mode clippings |
| `CDClippingDetailsViewController` | Clipping detail/edit view |
| `CDClippingItemViewController` | Individual clipping cell |
| `CDClippingPopoverViewController` | Clipping popover preview |
| `CDClippingLinkViewController` | Link preview (Swift) |
| `CDClippingHotkeyViewController` | Hotkey assignment per clipping |
| `CDListOutlineViewController` | List sidebar outline |
| `CDScriptEditorViewController` | JS script editor |
| `CDTemplateEditorViewController` | Template editor |

### Preferences View Controllers
| Controller | Tab |
|------------|-----|
| `CDGeneralPreferencesViewController` | General |
| `CDAppearancePreferencesViewController` | Appearance |
| `CDHotkeyPreferencesViewController` | Hotkeys |
| `CDRulesPreferencesViewController` | Rules |
| `CDSyncPreferencesViewController` | Sync/iCloud |
| `CDTemplatePreferenceViewController` | Templates |

### Core Managers
| Manager | Purpose |
|---------|---------|
| `CDPasteboardManager` | NSPasteboard monitoring (polling changeCount) |
| `CDPasteQueueManager` | Paste queue (sequential paste) |
| `CDCloudKitSyncManager` | CloudKit sync engine |
| `HotkeyManager` (Swift) | Global hotkey management |
| `LinkMetadataManager` (Swift) | LPMetadataProvider wrapper |

### Key Patterns
- **Notification-driven**: Heavy use of NSNotificationCenter (40+ custom notifications like `CDClipboardDidUpdateNotification`, `CDClippingCopiedNotification`, etc.)
- **Realm change observers**: `RLMNotificationToken` for reactive UI updates
- **Rules engine**: App rules (`CDAppRule`) with regex matching, domain rules, per-app configuration
- **Template system**: JavaScript-based formatters executed via JavaScriptCore
- **Paste Queue**: FIFO queue for sequential pasting with hotkey advancement

## Clipboard Monitoring

The `CDPasteboardManager` / `CDMacPasteboard` classes monitor `NSPasteboard.general`:
1. Polls `changeCount` on a timer
2. On change: reads all UTIs from pasteboard
3. Creates `CDPasteboardItem` objects
4. Evaluates rules (`CDRule`, `CDRegExRule`, `CDAppRule`) against content
5. Saves matching content as `Clipping` in Realm
6. Posts `CDClipboardDidUpdateNotification`

### Excluded pasteboard types handled:
- `Apple CFPasteboard drag`
- `Apple Web Archive pasteboard type`
- Continuity clipboard items (configurable via `CDUserDefaultsSaveContinuityClipboard`)

## iCloud Sync (CloudKit)

- **Container**: `iCloud.com.udoncode.copied`
- **Record Zone**: Custom zone with `CKRecordZoneID`
- **Sync queue**: `app.copied.syncqueue` (serial dispatch queue)
- **Server change token**: Stored in UserDefaults (`CDUserDefaultsCloudKitServerChangeToken`)
- **Sync flow**: Fetch changes → Apply to Realm → Upload local changes → Subscribe to push
- **Error handling**: Comprehensive CloudKit error mapping (zone busy, quota exceeded, rate limited, etc.)

## AppleScript Interface

```applescript
-- Save current clipboard
save clipboard
save clipboard in "list name"

-- Save arbitrary text
save "some text"
save "some text" in "list name"

-- Copy clipping at index
copyClipping 1
copyClipping 1 in "list name"
```

## JavaScript Extension System

Templates and merge scripts use JavaScriptCore. Clipping objects exposed to JS:
```javascript
{
  title: String?,    // clipping title
  text: String?,     // plain text content
  url: String?,      // URL
  saveDate: Date?    // when saved
}
```

### Built-in scripts:
| Script | Purpose |
|--------|---------|
| `merge.js` | Default merge (newline-separated) |
| `titlecase.js` | Title Case formatter |
| `uppercase.js` / `lowercase.js` | Case transforms |
| `cleanwhitespace.js` | Whitespace normalization |
| `encodestring.js` | URL encoding |
| `htmllist.js` | HTML list generation |
| `mdbullet.js` / `mdnumbered.js` / `mdquotes.js` | Markdown formatters |
| `numberedmerge.js` / `lineseparatormerge.js` / `referencesmerge.js` | Merge variants |
| `hextorbg.js` | Hex to RGB conversion |
| `default.js` | Default formatter |

## UserDefaults Keys (100+)

Key categories:
- **Clipboard**: `CaptureClipboard`, `ClipboardSize`, `ClipboardSync`, `AllowDupes`, `SaveOnLaunch`
- **Appearance**: `ApplicationDarkMode`, `WindowAppearance`, `FontSizeKey`, `RowHeightKey`, `ShowClippingIcons`
- **Hotkeys**: `ShowApplication`, `SaveClipboard`, `ShowClipboard`, `CopyClipping`, `PasteClipping`, `ToggleClipboardRecorder`, etc.
- **Actions**: `ReturnActionKey`, `DoubleClickAction`, `DragAction`, `SwipeLeftActionKey`, `SwipeRightActionKey`
- **Sync**: `SyncEnabled`, `LastSyncDate`, `CloudKitServerChangeToken`, `SyncListsOnly`
- **Window**: `WindowFrame`, `FullWindowFrameKey`, `FloatWindow`, `ShowWindowUnderCursor`, `LastWindowModeKey`
- **Rules**: `ApplicationRules`, `ClippingRules`

## iOS App Considerations

The bundle ID pattern and shared group container (`3DZ6694B2C.group.udoncode.copied`) indicate:
- iOS app shares the same Realm database schema
- iOS bundle likely: `com.udoncode.copied` (vs `com.udoncode.copiedmac`)
- Keyboard extension present (references to `ExtensionKeyboard*` defaults)
- Widget support (`SaveOnWidgetLaunch`)
- Shared via App Group and iCloud sync

## Reconstruction Strategy

### Phase 1: Core Data Layer
1. Create Realm models matching the schema above
2. Open and read the existing `copied.realm` database
3. Implement data migration from CoreData `datastore` if needed

### Phase 2: Clipboard Engine
1. `NSPasteboard` change monitoring via timer
2. Multi-type pasteboard reading (text, images, URLs, files, rich text)
3. Clipping creation with deduplication
4. Rules engine for filtering/routing

### Phase 3: UI Shell
1. Menu bar presence + main window
2. Clipping list with search
3. List/folder management
4. Detail view with preview (text, image, link metadata)

### Phase 4: Productivity Features
1. Global hotkeys (ShortcutRecorder replacement or native)
2. Paste queue (sequential paste)
3. Templates/formatters (JavaScriptCore)
4. Merge functionality

### Phase 5: Sync
1. CloudKit sync (or modern alternative)
2. iOS companion app with shared Realm/data layer

### Modern Technology Choices
| Original | Modern Replacement |
|----------|--------------------|
| Realm (Obj-C) | SwiftData or Realm Swift or GRDB |
| CoreData (legacy) | Drop entirely |
| ShortcutRecorder + PTHotKey | Native `NSEvent.addGlobalMonitorForEvents` + Settings API |
| NSLogger | `os_log` / `Logger` |
| JavaScriptCore templates | Keep JSCore or move to Swift string processing |
| CloudKit (manual) | `NSPersistentCloudKitContainer` or CloudKit structured concurrency |
| x86_64 only | Universal binary (arm64 + x86_64) |
| macOS 10.14+ | macOS 13+ (for SwiftUI, modern APIs) |
| NIB files | SwiftUI or programmatic |
