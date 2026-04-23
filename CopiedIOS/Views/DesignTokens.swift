import SwiftUI

/// Single-source design tokens pulled from `design/colors_and_type.css` and the
/// reference screenshots in `images/IMG_0977…IMG_0980.png`. iOS is dark-only:
/// background `#000`, teal `#2DD4BF` for interactive accent, red `#FF453A` for
/// destructive / over-limit. SF Pro is implied by the system font.
extension Color {
    /// Primary interactive accent (chevrons, "Done", links, teal icons).
    static let copiedTeal = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255)

    /// Destructive action + over-limit counter.
    static let copiedRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    /// `systemBackground` equivalent for the app. Always `#000` on iOS; matches
    /// the design system even under `.light` color scheme.
    static let copiedCanvas = Color.black

    /// Inset-grouped card fill (`UIColor.secondarySystemBackground` on dark).
    static let copiedCard = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)

    /// Divider / separator at ~5% white.
    static let copiedSeparator = Color.white.opacity(0.08)

    /// Muted label (metadata, gray chevron counts).
    static let copiedSecondaryLabel = Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8B / 255)
}
