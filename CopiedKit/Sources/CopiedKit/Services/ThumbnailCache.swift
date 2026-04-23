import Foundation
import CoreGraphics
import ImageIO
#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Caches downsampled thumbnails to avoid decoding multi-MB images on every render.
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CachedImage>()

    /// Boxes a `PlatformImage` for `NSCache`, which requires an NSObject-typed value.
    private final class CachedImage: NSObject {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    private init() {
        // Sized for full scroll cycles of long clipboard histories: 2000 entries
        // at up to 150 MB. With two size variants (32, 120) that's ~1000 thumbnails,
        // covering ~1000 image clippings without eviction on scroll-back.
        cache.countLimit = 2000
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    /// Returns a cached thumbnail, decoding and downsampling only on cache miss.
    /// `data` is an autoclosure so the caller's expression is only evaluated on
    /// cache miss — critical when the underlying blob is `@Attribute(.externalStorage)`,
    /// where a naive access faults the full image bytes off disk on every row render.
    public func thumbnail(for clippingID: String, data: @autoclosure () -> Data?, maxSize: CGFloat = 120) -> PlatformImage {
        let key = "\(clippingID)-\(Int(maxSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let resolved = data(),
              let cgImage = Self.decode(data: resolved, maxSize: maxSize) else {
            return PlatformImage()
        }

        let image = Self.makeImage(cgImage: cgImage)
        let cost = cgImage.width * cgImage.height * 4
        cache.setObject(CachedImage(image), forKey: key, cost: cost)
        return image
    }

    /// Cache-hit fast path: returns nil on miss. Safe to call from any thread.
    public func cachedThumbnail(for clippingID: String, maxSize: CGFloat = 120) -> PlatformImage? {
        let key = "\(clippingID)-\(Int(maxSize))" as NSString
        return cache.object(forKey: key)?.image
    }

    /// Off-main thumbnail decode. Returns nil if the image data can't be resolved
    /// or decoded. Populates the cache on success.
    public func decodeThumbnail(for clippingID: String, data: Data?, maxSize: CGFloat = 120) async -> PlatformImage? {
        if let cached = cachedThumbnail(for: clippingID, maxSize: maxSize) { return cached }
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let cgImage = Self.decode(data: data, maxSize: maxSize) else { return nil }
            let image = Self.makeImage(cgImage: cgImage)
            let key = "\(clippingID)-\(Int(maxSize))" as NSString
            let cost = cgImage.width * cgImage.height * 4
            self?.cache.setObject(CachedImage(image), forKey: key, cost: cost)
            return image
        }.value
    }

    public func evict(clippingID: String) {
        for size in [32, 120] {
            cache.removeObject(forKey: "\(clippingID)-\(size)" as NSString)
        }
    }

    // MARK: - Shared decode path

    private static func decode(data: Data, maxSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize * 2, // 2x for Retina
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeImage(cgImage: CGImage) -> PlatformImage {
        let size = CGSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: 2.0, orientation: .up)
        #else
        return PlatformImage()
        #endif
    }
}
