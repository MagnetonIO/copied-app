# iOS UI Kit — Copied

Hi-fi recreation of the Copied iOS app, ported from `CopiedIOS/` SwiftUI views.

## Files
- `index.html` — three phones side-by-side: list, sidebar, settings. Tap the `⋯` in the list to trigger the action sheet.
- `ClippingRow.jsx` — `<ClippingRow clipping={...}/>` plus `<KindIcon kind="code|link|text|image|video|file"/>`.
- `IOSScreens.jsx` — `<ListScreen/>`, `<SidebarScreen/>`, `<SettingsScreen/>`, `<ActionSheet/>`, `<NavBar/>`.
- `ios-frame.jsx` — starter component (currently unused; the local simple phone chrome is used instead).

## Design notes
- Pure-black canvas, iOS teal tint (`#2dd4bf`) for all accents: chevrons, nav leading, "Done", "New List", tab-bar icons.
- iOS system red (`#ff453a`) for destructive: Trash icon, the `500` count in the sidebar + tab bar.
- Inset-grouped settings (flat rounded-12 cards, no border, separated by spacing).
- Row typography: 15px title, 11px caption metadata with clock glyph + char/word count + relative time.
- Action sheet uses `regularMaterial`-style blur (`rgba(40,40,40,0.92)` + `backdrop-filter: blur(30px)`).

## Caveats
- Icon set is hand-inlined SVG approximations of the SF Symbols used in Swift (`clipboard`, `folder`, `trash`, `gearshape`, `plus.circle.fill`, `arrow.up.arrow.down.circle`, etc.). For production, swap these for actual SF Symbols on-platform.
- Status bar cellular/wifi/battery glyphs are simplified.
- Swipe actions (favorite / trash) from `IOSContentView.swift` are not implemented in the static prototype.
