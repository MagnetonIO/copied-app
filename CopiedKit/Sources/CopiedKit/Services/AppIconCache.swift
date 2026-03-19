#if canImport(AppKit)
import AppKit

/// Lightweight in-memory cache for app icons. Looks up icons by bundle ID
/// instead of storing data in the database.
/// Uses NSCache for automatic memory pressure eviction (BUG-10 fix).
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    public func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // BUG-11 fix: use modern image creation instead of deprecated lockFocus
        let small = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }

        cache.setObject(small, forKey: key)
        return small
    }
}
#endif
