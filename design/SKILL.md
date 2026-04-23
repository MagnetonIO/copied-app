---
name: copied-design
description: Use this skill to generate well-branded interfaces and assets for Copied (the macOS/iOS clipboard manager by Magneton Labs), either for production or throwaway prototypes/mocks. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the `README.md` file within this skill, and explore the other available files:

- `README.md` — brand context, content fundamentals, visual foundations, iconography.
- `colors_and_type.css` — CSS custom properties for colors, type, spacing, radii, shadows.
- `assets/` — logos, icons, marketing images copied from the real product.
- `ui_kits/ios/` — hi-fi iOS app recreation (clippings list, sidebar, settings, action sheet).
- `ui_kits/marketing/` — hi-fi landing page recreation (nav, hero, features, code demo, shortcuts, download, footer).
- `preview/` — atomic design-system cards (type, color, spacing, components).

If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out of `assets/` and create static HTML files for the user to view. Reference `colors_and_type.css` and lift colors/tokens directly from it. If working on production code (SwiftUI for `CopiedIOS`/`CopiedMac`, or Next.js for `getcopied-app`), use this skill to become an expert in the brand and match the visual language precisely.

If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some clarifying questions (platform, audience, scope, fidelity), and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Core brand rules to never break:
- Always pure-black `#000` canvas on dark surfaces. Never off-black greys as the base.
- Teal `#2dd4bf` is the ONLY accent for interactive affordances (links, chevrons, "Done", tab icons). Red `#ff453a` is reserved for destructive (trash, counts > threshold).
- Gradient use is restricted to: (1) the hero headline word ("supercharged."), (2) the logo mark. Never on buttons, cards, or backgrounds.
- Copy is plainspoken, lowercase-first-word after periods in marketing; sentence case in app UI. No emoji. No exclamation marks.
