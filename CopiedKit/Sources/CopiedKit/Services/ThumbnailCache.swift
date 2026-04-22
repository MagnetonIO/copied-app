import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Caches downsampled thumbnails to avoid decoding multi-MB images on every render.
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CachedImage>()

    private init() {
        // Sized for full scroll cycles of long clipboard histories: 2000 entries
        // at up to 150 MB. With two size variants (32, 120) that's ~1000 thumbnails,
        // covering ~1000 image clippings without eviction on scroll-back. Previous
        // 500 / 50 MB evicted mid-scroll and forced re-decodes on scroll-up,
        // producing the reported stutter.
        cache.countLimit = 2000
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    #if canImport(AppKit)
    private final class CachedImage: NSObject {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    /// Returns a cached thumbnail, decoding and downsampling only on cache miss.
    /// `data` is an autoclosure so the caller's expression is only evaluated on
    /// cache miss — critical when the underlying blob is `@Attribute(.externalStorage)`,
    /// where a naive access faults the full image bytes off disk on every row render.
    public func thumbnail(for clippingID: String, data: @autoclosure () -> Data?, maxSize: CGFloat = 120) -> NSImage {
        let key = "\(clippingID)-\(Int(maxSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let resolved = data(),
              let source = CGImageSourceCreateWithData(resolved as CFData, nil) else {
            return NSImage()
        }

        // Downsample at decode time — never creates a full-resolution bitmap
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize * 2, // 2x for Retina
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage()
        }

        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        let cost = cgImage.width * cgImage.height * 4 // approximate bytes
        cache.setObject(CachedImage(thumbnail), forKey: key, cost: cost)
        return thumbnail
    }

    /// Cache-hit fast path: returns nil on miss. Safe to call from any thread.
    /// Use this in hot scroll paths where the caller can show a placeholder
    /// and await the full decode via `decodeThumbnail` off-main.
    public func cachedThumbnail(for clippingID: String, maxSize: CGFloat = 120) -> NSImage? {
        let key = "\(clippingID)-\(Int(maxSize))" as NSString
        return cache.object(forKey: key)?.image
    }

    /// Off-main thumbnail decode. Returns nil if the image data can't be resolved
    /// or decoded. Populates the cache on success. Never blocks the caller's thread
    /// on the CGImageSource decode itself.
    public func decodeThumbnail(for clippingID: String, data: Data?, maxSize: CGFloat = 120) async -> NSImage? {
        if let cached = cachedThumbnail(for: clippingID, maxSize: maxSize) { return cached }
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxSize * 2,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let thumbnail = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
            )
            let key = "\(clippingID)-\(Int(maxSize))" as NSString
            let cost = cgImage.width * cgImage.height * 4
            self?.cache.setObject(CachedImage(thumbnail), forKey: key, cost: cost)
            return thumbnail
        }.value
    }
    #endif

    public func evict(clippingID: String) {
        // Remove all size variants
        for size in [32, 120] {
            cache.removeObject(forKey: "\(clippingID)-\(size)" as NSString)
        }
    }
}
