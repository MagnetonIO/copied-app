import SwiftData
import Foundation

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
        if hasImage { return .image }
        if url != nil { return .link }
        if isCode { return .code }
        if hasHTML { return .html }
        if hasRichText { return .richText }
        if text != nil { return .text }
        return .unknown
    }

    /// Sort key: lastUsedDate if set, otherwise addDate (BUG-30 fix)
    public var sortDate: Date {
        lastUsedDate ?? addDate
    }

    public func moveToTrash() {
        deleteDate = Date()
        modifiedDate = Date()
    }

    public func restore() {
        deleteDate = nil
        modifiedDate = Date()
    }

    public func markUsed() {
        let now = Date()
        lastUsedDate = now
        copiedDate = now
        addDate = now  // Update addDate so @Query sort puts copied items at top
    }
}

public enum ContentKind: String, Codable, Sendable {
    case text
    case richText
    case image
    case link
    case file
    case code
    case html
    case unknown
}
