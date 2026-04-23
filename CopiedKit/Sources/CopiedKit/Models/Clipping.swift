import SwiftData
import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

@Model
public final class Clipping {
    // BUG-05 fix: add indexes for common query patterns
    #Index<Clipping>([\.addDate], [\.deleteDate], [\.isFavorite, \.deleteDate], [\.listIndex])

    // Identity
    public var clippingID: String = UUID().uuidString

    // Content
    public var text: String?
    public var title: String?
    public var url: String?
    public var sourceURL: String?

    // Binary content — stored externally to keep SQLite lean
    @Attribute(.externalStorage) public var imageData: Data?
    @Attribute(.externalStorage) public var richTextData: Data?
    @Attribute(.externalStorage) public var fileBookmarks: [Data]?

    // Scalar flags to avoid faulting external storage for nil checks (BUG-25 fix)
    public var hasImage: Bool = false
    public var hasRichText: Bool = false
    public var imageByteCount: Int = 0
    public var imageFormat: String = "tiff"  // "tiff" or "png"

    // Code detection
    public var isCode: Bool = false
    public var detectedLanguage: String?

    // Plain-text extract of richTextData / htmlData bodies, populated at
    // capture time so popover search can reach inside formatted content.
    public var extractedText: String?

    // HTML content
    @Attribute(.externalStorage) public var htmlData: Data?
    public var hasHTML: Bool = false

    // Pasteboard metadata
    public var types: [String] = []

    // Timestamps
    public var addDate: Date = Date()
    public var lastUsedDate: Date?  // BUG-30 fix: separate from addDate for "move to top"
    public var copiedDate: Date?
    public var deleteDate: Date?
    public var modifiedDate: Date?

    // Source info
    public var deviceName: String = ""
    public var appName: String?
    public var appBundleID: String?

    // Display hints
    public var imageWidth: Double = 0
    public var imageHeight: Double = 0
    public var isFavorite: Bool = false
    public var isPinned: Bool = false
    public var listIndex: Int = 0

    // Relationships
    public var list: ClipList?

    @Relationship(deleteRule: .cascade, inverse: \Asset.clipping)
    public var assets: [Asset]?

    // BUG-31 fix: don't regenerate UUID in init — the default value handles it
    public init(
        text: String? = nil,
        title: String? = nil,
        url: String? = nil,
        types: [String] = [],
        deviceName: String = ""
    ) {
        self.text = text
        self.title = title
        self.url = url
        self.types = types
        self.deviceName = deviceName
    }
}

// MARK: - Computed Helpers

extension Clipping {
    public var isInTrash: Bool { deleteDate != nil }

    // BUG-25 fix: use hasImage instead of faulting imageData
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let text, !text.isEmpty {
            return String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        }
        if let url, !url.isEmpty { return url }
        if hasImage { return "Image" }
        return "Empty Clipping"
    }

    public var contentKind: ContentKind {
        if isVideoFile { return .video }
        if hasImage { return .image }
        if url != nil { return .link }
        if isCode { return .code }
        if hasHTML { return .html }
        if hasRichText { return .richText }
        if text != nil { return .text }
        if sourceURL != nil { return .file }
        return .unknown
    }

    /// Sort key: lastUsedDate if set, otherwise addDate (BUG-30 fix)
    public var sortDate: Date {
        lastUsedDate ?? addDate
    }

    public func moveToTrash() {
        deleteDate = Date()
        modifiedDate = Date()
        // SwiftData's default autosave is periodic (few seconds), and
        // NSPersistentCloudKitContainer only pushes to CloudKit when a
        // save commits. Forcing the save here means every callsite that
        // trashes a clipping (row swipe, detail toolbar, Mac context
        // menu, etc.) gets cross-device propagation without remembering
        // to call save manually.
        try? modelContext?.save()
    }

    public func restore() {
        deleteDate = nil
        modifiedDate = Date()
        try? modelContext?.save()
    }

    /// Flush any pending property mutations (favorite, pin, title, etc.)
    /// out through SwiftData + CloudKit immediately. Same rationale as
    /// the save inside `moveToTrash`.
    public func persist() {
        modifiedDate = Date()
        try? modelContext?.save()
    }

    public func markUsed() {
        let now = Date()
        lastUsedDate = now
        copiedDate = now
        addDate = now  // Update addDate so @Query sort puts copied items at top
        // Same rationale as moveToTrash/restore/persist — commit the
        // change so CloudKit mirror pushes lastUsedDate/addDate to other
        // devices. Without this the MRU ordering is per-device local.
        try? modelContext?.save()
    }

    #if canImport(AppKit)
    public var richTextPasteboardType: NSPasteboard.PasteboardType {
        types.contains(NSPasteboard.PasteboardType.rtfd.rawValue) ? .rtfd : .rtf
    }
    #endif

    // MARK: - Content fingerprint (for dedup)

    /// SHA-256 of the canonical content payload. Deterministic across
    /// devices — same text / url / image produces the same hex digest
    /// on iOS and Mac. Used by `ClipboardService` capture-path dedup
    /// and the one-shot "Remove Duplicates" cleanup. Excludes metadata
    /// fields like timestamps, device name, favorite state — only the
    /// content that defines "same clipping".
    public func contentHash() -> String {
        var hasher = SHA256()
        hasher.update(data: Data(contentKind.rawValue.utf8))
        hasher.update(data: Data("\0".utf8))
        if let t = text { hasher.update(data: Data(t.utf8)) }
        hasher.update(data: Data("\0".utf8))
        if let u = url { hasher.update(data: Data(u.utf8)) }
        hasher.update(data: Data("\0".utf8))
        if let d = imageData { hasher.update(data: d) }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Static Relative Date (avoids SwiftUI's Text(date, style: .relative) constant re-render)

extension Date {
    /// Returns a human-readable relative time string. Computed once per call,
    /// does NOT trigger continuous SwiftUI layout cycles like `Text(date, style: .relative)`.
    public var relativeLabel: String {
        let seconds = -self.timeIntervalSinceNow
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) sec" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours) hr" }
        let days = Int(seconds / 86400)
        if days < 30 { return "\(days) day\(days == 1 ? "" : "s")" }
        let months = Int(seconds / 2_592_000)
        return "\(months) mo"
    }
}

public enum ContentKind: String, Codable, Sendable {
    case text
    case richText
    case image
    case video
    case link
    case file
    case code
    case html
    case unknown
}

extension Clipping {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]

    public var isVideoFile: Bool {
        guard let src = sourceURL,
              let url = URL(string: src) else { return false }
        return Self.videoExtensions.contains(url.pathExtension.lowercased())
    }
}
