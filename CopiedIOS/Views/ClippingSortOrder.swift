import Foundation
import CopiedKit

/// Sort options offered by the Phase 9 action-sheet's "Sort List" row.
/// Persisted per-selection via `@AppStorage("sort.order.<key>")` so the
/// Copied list can sort chronologically while a user-created list sorts
/// alphabetically (or whatever each owner prefers).
enum ClippingSortOrder: String, CaseIterable, Identifiable {
    case dateDesc
    case dateAsc
    case favoritesFirst
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateDesc: return "Newest first"
        case .dateAsc: return "Oldest first"
        case .favoritesFirst: return "Favorites first"
        case .alphabetical: return "A → Z"
        }
    }

    /// Comparator suitable for `Array.sorted(by:)` over an array of
    /// `Clipping`. Swift's `sorted(by:)` isn't stable, so every case falls
    /// back to `clippingID` (a UUID string) as the final tie-breaker — same
    /// rows render in the same order every time.
    var comparator: (Clipping, Clipping) -> Bool {
        switch self {
        case .dateDesc:
            return { lhs, rhs in
                if lhs.addDate != rhs.addDate { return lhs.addDate > rhs.addDate }
                return lhs.clippingID < rhs.clippingID
            }
        case .dateAsc:
            return { lhs, rhs in
                if lhs.addDate != rhs.addDate { return lhs.addDate < rhs.addDate }
                return lhs.clippingID < rhs.clippingID
            }
        case .favoritesFirst:
            return { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                if lhs.addDate != rhs.addDate { return lhs.addDate > rhs.addDate }
                return lhs.clippingID < rhs.clippingID
            }
        case .alphabetical:
            return { lhs, rhs in
                let l = lhs.displayTitle.localizedLowercase
                let r = rhs.displayTitle.localizedLowercase
                if l != r { return l < r }
                if lhs.addDate != rhs.addDate { return lhs.addDate > rhs.addDate }
                return lhs.clippingID < rhs.clippingID
            }
        }
    }
}
