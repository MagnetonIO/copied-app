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
        cache.countLimit = 500
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB max
    }

    #if canImport(AppKit)
    private final class CachedImage: NSObject {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    /// Returns a cached thumbnail, decoding and downsampling only on cache miss.
    public func thumbnail(for clippingID: String, data: Data, maxSize: CGFloat = 120) -> NSImage {
        let key = "\(clippingID)-\(Int(maxSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
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
    #endif

    public func evict(clippingID: String) {
        // Remove all size variants
        for size in [32, 120] {
            cache.removeObject(forKey: "\(clippingID)-\(size)" as NSString)
        }
    }
}
