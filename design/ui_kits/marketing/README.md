# Marketing UI Kit — getcopied.app

Hi-fi recreation of the Copied landing page. Ported from `getcopied-app/app/page.tsx` + `components/Nav.tsx` + `components/Footer.tsx`.

## Files
- `index.html` — full landing page (nav → hero → features → code demo → shortcuts → download → footer).
- `MarketingComponents.jsx` — `<Nav/>`, `<Hero/>`, `<AppPreview/>`, `<Features/>`, `<CodeDemo/>`, `<Shortcuts/>`, `<Download/>`, `<Footer/>`, `<LogoMark/>`.

## Design notes
- `max-w-6xl` nav · `max-w-5xl` features · `max-w-4xl` hero/code · `max-w-3xl` download.
- Hero headline: 72px, tracking -0.03em, line-height 1.05, final word in teal→emerald→cyan gradient text.
- Primary CTA: white-on-black `rounded-full`, 14px padding. Secondary: outline with 20% white border.
- Feature cards: flat `#1a1a1a`, `rounded-2xl`, 1px hairline border, icon well 40×40 in `bg-white/5`.
- CodeDemo uses a green `#34d399` "monitoring" dot + faint-green code on pure black.
- Shortcut `<kbd>`s use 1px bottom shadow for physical lift.

## Caveats
- Framer-motion entrance animations (fade+slide) omitted; static render only.
- Links are placeholder `<a>` tags without `href`.
