# Copied Design System

> Your clipboard, supercharged.

This design system captures the visual and interaction language of **Copied**, a menu-bar & mobile clipboard manager for macOS / iOS by **Magneton Labs, LLC**. It's optimized for agents (Claude, Claude Code) that need to produce on-brand interfaces, marketing pages, or prototypes for Copied — or to extend the product.

---

## 1. Product context

**Copied** is a clipboard manager with four marketed superpowers:

1. **Auto-detects code** in 25+ languages, renders syntax-aware previews with language badges.
2. **Instant fuzzy search** across clipping history (Sublime-style matching).
3. **Smart text transforms** — JSON format, URL encode, UPPERCASE, strip-markdown, etc., on the fly.
4. **iCloud Sync** across all your Macs (and iOS).

There are two surfaces in scope:

| Surface | Role | Tech |
|---|---|---|
| **iOS / macOS app** | Core product. Menu-bar popover on Mac; NavigationSplitView on iOS. SwiftUI + SwiftData. Dark-only. | SwiftUI · SwiftData · CloudKit |
| **Marketing website** (`getcopied.app`) | Download + unlock. Dark, Apple-like landing page with hero, features grid, code demo, shortcuts, download CTA. | Next.js 14 · Tailwind v4 · Framer Motion |

Both are **dark-only** (pure `#000` canvas), share a **teal → emerald → cyan** accent gradient, and use **SF Pro / system font** exclusively.

### Sources consulted
- **App codebase:** `copied-reverse-engineer/` (attached locally) — SwiftUI code for `CopiedIOS`, `CopiedMac`, and shared `CopiedKit` (models, services, shared views). Primary source of truth for app UI.
- **Website codebase:** `getcopied-app/` (attached locally) — Next.js 14 app router. `app/globals.css` is the token source; `app/page.tsx`, `components/Nav.tsx`, `components/Footer.tsx` are the canonical visual patterns.
- **GitHub:** [`MagnetonIO/copied-app`](https://github.com/MagnetonIO/copied-app), [`MagnetonIO/getcopied-app`](https://github.com/MagnetonIO/getcopied-app)
- **App Store listing:** `macappstore://apps.apple.com/app/id6762879815`
- **Screenshots** (user-supplied, in `assets/screens/`): list view, action sheet, sidebar, settings — all iOS.

---

## 2. Index — files in this system

| Path | What it is |
|---|---|
| `README.md` | You are here. Manifest + all brand fundamentals. |
| `SKILL.md` | Agent Skill entry point. |
| `colors_and_type.css` | All design tokens (colors, type, radii, spacing, shadows, motion). |
| `assets/` | Real logos, icons, app-icon PNGs, OG image, iOS screens. |
| `preview/` | Small HTML cards that populate the Design System tab — palettes, type specimens, components. |
| `ui_kits/ios/` | iOS app UI kit (hi-fi recreation) with `index.html` and reusable JSX components. |
| `ui_kits/marketing/` | Marketing site UI kit (hero, features, download, nav, footer). |

---

## 3. Content fundamentals — tone & copy

Copied's voice is **Apple-adjacent**: short, confident, productive. No emoji. No exclamation marks. Nothing cute.

### Signature patterns
- **Two-beat headlines.** A claim, then a clarifying clause or foil.
  - *Your clipboard, supercharged.*
  - *Knows your code.*
  - *Keyboard first.*
  - *Everything you copy. / Nothing you lose.*
  - *Ready to try?*
- **Feature titles are 2-word noun phrases.** "Code Detection", "Fuzzy Search", "Smart Transforms", "iCloud Sync", "Keyboard First", "Favorites & Pins".
- **Feature bodies are single sentences**, concrete, ending in a period. Often they slip in a stat or a how: *"Auto-detects 25+ languages. Code snippets get monospaced preview with language badges."*
- **Second-person plural-ish** — "your clipboard", "your Macs", "your hands never leave the keyboard". Almost never "I" or "we".
- **Verbs over adjectives.** *Auto-detects, syncs, transforms, searches* — not *powerful, beautiful, seamless*.
- **Casing:** Title Case for button labels ("Download for Mac", "View on GitHub", "Unlock iCloud Sync"); Sentence case for microcopy and settings labels ("Launch at login", "Allow duplicate clippings", "Strip URL tracking parameters").
- **Keyboard shortcuts are first-class content** — displayed inline with `<kbd>`, referenced in copy ("Every action has a shortcut.").
- **Numbers > vague quantifiers.** "25+ languages", "500 Clippings", "macOS 15+", "$4.99", "⌘1–9".

### Empty / status states
- Short noun phrase title + one-sentence instruction:
  - *No Clippings Yet / Tap + to save what's on your clipboard*
  - *No Selection / Select a clipping or tap + to save your clipboard*
- Status pills borrow pasteboard-era language: *Monitoring*, *Sync is active*, *Sync is paused*, *Sync is locked*.

### Things the brand avoids
- Emoji (none in product or site).
- Exclamation marks.
- Gradient backgrounds behind cards — gradient is reserved for brand mark, the hero-heading accent word, and the app icon. Everything else is flat dark.
- Marketing superlatives ("revolutionary", "beautiful", "seamless").
- AI / LLM framing — the product is deterministic tooling.

---

## 4. Visual foundations

### 4.1 Canvas
- **Everything is dark-mode only.** `#000` pure black is the primary canvas for both site and app. Section bands use `#111`, cards use `#1a1a1a`, elevated sheets use `#1f1f1f`.
- No patterns, no textures, no illustrated backgrounds. The space is deliberately empty so content and the teal accent pop.
- Occasional **section alternation** — an inner section on `--bg-secondary` (`#111`) — provides visual rhythm on the marketing page.

### 4.2 Color
- **Accent gradient (teal→emerald→cyan)** used in exactly three places: the brand mark chip, the hero-headline accent word (`supercharged.`), and the app icon. Everywhere else is monochrome white/gray with the emerald `#34d399` as a single-color accent.
- **Content-kind colors** (code/link/image/video/text) are used as small colored icons + matching 10% tinted pill badges — never as fills for full rows or cards.
- **iOS accent** renders as teal `#2dd4bf` (the "Done" / "New List" / sidebar icons). Web CTA fills use white-on-black (`.bg-white text-black`) with Apple blue `#0071e3` reserved for selection.
- Trash / destructive uses iOS system red `#ff453a`.

### 4.3 Type
- **SF Pro / system stack only.** No webfonts. The system font stack `-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Helvetica Neue"` is used everywhere.
- **Mono:** `ui-monospace, SF Mono, Menlo`.
- **Tight tracking on displays** (-0.02 to -0.03em), normal on body. Font weights used: 400 / 500 / 600 / 700.
- Hero headlines go big: 6xl / 7xl (60–72px), tracking-tight, leading-[1.05].
- Body copy in marketing is 18–20px (`text-lg / text-xl`), muted `--text-secondary`.

### 4.4 Shape — radii
- **Pills (`9999px`)** for all primary buttons, status chips, language badges, small tags.
- **`rounded-2xl` (16px)** for hero cards and feature cards.
- **`rounded-xl` (12px)** for icon wells, inputs, kbd groups.
- **`rounded-lg` (8px)** for code blocks, single kbds, small bordered elements.
- **App-icon squircle** (22px / continuous corners on 128px icon) — macOS / iOS native continuous corner curve; don't emulate with CSS beyond approximation.

### 4.5 Borders & hairlines
- Cards / sections use **1px hairlines at `rgba(255,255,255,0.05)`** (near-invisible). On hover, they brighten to `rgba(255,255,255,0.10)`.
- The app's row dividers are `divide-white/5` — just barely perceptible.
- iOS settings groups are flat rounded rectangles with no visible border; separation comes from spacing.

### 4.6 Shadows
- **No inner shadows** in the product.
- **Hero card** drops a heavy `shadow-2xl shadow-black/50` (`0 40px 80px -20px rgba(0,0,0,0.6)`) — used sparingly on the app preview.
- **`<kbd>`** gets a 1px bottom shadow (`0 1px 0 rgba(0,0,0,0.25)`) to look physical.
- Popover / menu sheets lean on the dark background instead of a heavy shadow — 1px light border + slight elevation in bg color does the work.

### 4.7 Motion
- **Ease curve:** `easeOut` (`cubic-bezier(0.16, 1, 0.3, 1)`), 0.6s entrance, 0.1s stagger between children (from `framer-motion` variants).
- **Hover:** `transition-all duration-200` with `hover:scale-105` on primary CTAs; opacity shift `bg-white/90` on white buttons; border brightening on cards.
- **Press:** subtle `active:scale-[0.98]` on buttons.
- **No bounce springs.** No parallax. No auto-playing videos.
- **Scroll:** `scroll-behavior: smooth` site-wide.

### 4.8 Transparency + blur
- **Nav is sticky blurred:** `backdrop-blur-xl bg-black/70 border-b border-white/5` — the only use of blur on the site.
- **iOS sheets:** the system's standard `.regularMaterial` blur, used for the action sheet (`IMG_0978`) and the iCloud-activating overlay.
- **Tinted badges:** content-kind pills use `bg-<color>/10 text-<color>` — 10% color tint on dark.

### 4.9 Layout rules
- Marketing content caps at `max-w-6xl` for nav, `max-w-5xl` for feature grid, `max-w-4xl` for hero + code demo, `max-w-3xl` for download CTA.
- Feature grid is 1 → 2 → 3 columns at mobile / md / lg.
- Horizontal page padding is consistent 24px (`px-6`).
- iOS: inset-grouped list style (flat rounded cards of rows, ~16px horizontal inset from the screen edge).

### 4.10 Cards
- Flat dark (`--bg-card` / `#1a1a1a`), 1px hairline border, 16px radius, 24px padding. No shadow, no gradient. Hover brightens the border only.
- Icon wells inside cards: 40×40 rounded-xl, `bg-white/5`, centered 24px icon in `--text-secondary`.

### 4.11 Imagery
- **There is no photography.** The only raster asset is the app icon (glossy teal squircle clipboard). All other "imagery" is:
  1. Screenshots of the product (OG image shows the app popover).
  2. Inline UI mocks built in HTML/SwiftUI.
  3. Monochrome stroke SVG icons.
- If imagery is ever needed, keep it tonal (teal / dark), never warm.

---

## 5. Iconography

The system is **entirely stroke-based, single-color, 1.5–2px weight** icons.

### Approach
- **On macOS/iOS:** SF Symbols, exclusively (`clipboard`, `gearshape`, `paintbrush`, `icloud`, `info.circle`, `star.fill`, `pin.fill`, `trash`, `chevron.left.forwardslash.chevron.right`, `doc.text`, `doc.richtext`, `photo`, `play.rectangle.fill`, `link`, `globe`, `questionmark.square`, `plus.circle.fill`, `folder`, `xmark.icloud`, `checkmark.icloud.fill`, `lock.icloud`, `bag.badge.plus`, `arrow.up.right.square`). They adopt the current tint (teal in iOS, mono on Mac toolbar).
- **On the web:** hand-inlined SVGs with `strokeWidth={2}`, `strokeLinecap="round"`, matching SF-Symbol-style glyphs (clipboard, search, code-slashes, link, doc, image, star, arrow-down, kbd). No icon library — the ~10 shapes needed are written inline in `page.tsx` / `Nav.tsx`.
- **Emoji: never.**
- **Unicode arrows OK** — `→` in the code demo, `⌘` in kbd specimens, `↑` `↓` for navigation.

### In this system
- Web icons are reproduced inline in the JSX components (see `ui_kits/marketing/Icons.jsx`).
- The iOS kit substitutes **Lucide** (via CDN, 1.5px stroke) for SF Symbols — closest free match in stroke weight and geometry. **Flagged substitution** — when exporting final designs, swap back to SF Symbols if targeting an Apple-platform preview.
- App-icon PNGs are in `assets/app-icon-*.png` at 128 / 256 / 512 / 1024.

---

## 6. UI kits

Two UI kits live in `ui_kits/`:

- **`ios/`** — iOS app. Clippings list, sidebar, settings, action sheet. Renders at iPhone width inside an `ios_frame` starter component.
- **`marketing/`** — `getcopied.app` landing page. Nav, hero + app-preview, features grid, code-demo, shortcuts, download CTA, footer.

Each has its own `README.md`, an `index.html` demonstrating an interactive version, and per-component JSX files.

---

## 7. Caveats & substitutions

- **SF Pro** is Apple-licensed and not redistributable here. The CSS falls back to the `-apple-system` system stack — which renders SF Pro natively on macOS/iOS browsers and a close Helvetica-family fallback elsewhere. If final assets are exported on Windows/Linux, consider **Inter** as the nearest metric-compatible substitute (flagged).
- **SF Symbols** are Apple-licensed. The web kit uses hand-inlined SF-lookalike strokes; the iOS kit uses **Lucide** at 1.5px.
- **Continuous-corner squircle** (the app icon's mathematically-correct Apple corner) can only be approximated in CSS with `border-radius: 22%` — acceptable for previews, not pixel-perfect.
