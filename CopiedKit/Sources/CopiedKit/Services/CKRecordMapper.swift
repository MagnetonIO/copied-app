import Foundation
import CloudKit
import SwiftData

/// Bi-directional mapping between SwiftData `@Model` types and
/// `CKRecord`. Used by `CopiedSyncEngine` for both outbound batch
/// construction (`nextRecordZoneChangeBatch`) and inbound upsert
/// (`.fetchedRecordZoneChanges`).
///
/// Field-name convention: CKRecord field names match the SwiftData
/// property name exactly (e.g. `record["modifiedDate"]`). No CD_
/// prefixes — those were NSPCKC's auto-generated convention and are
/// intentionally avoided here so the legacy + new zones don't collide
/// and so the CloudKit Dashboard column names read naturally.
///
/// Binary blobs stored as `@Attribute(.externalStorage)` on the model
/// (`imageData`, `richTextData`, `htmlData`) become `CKAsset` fields,
/// which CloudKit streams separately. Writes blobs to a temp file
/// under the caller's cache dir so CKAsset has a stable URL to read
/// at upload time; caller is responsible for cleanup on sent event.
public enum CKRecordMapper {

    // MARK: - Field name constants (keep in sync with model properties)

    private enum Field {
        static let contentHash = "contentHash"
        static let text = "text"
        static let title = "title"
        static let url = "url"
        static let sourceURL = "sourceURL"
        static let imageData = "imageData"
        static let richTextData = "richTextData"
        static let htmlData = "htmlData"
        static let hasImage = "hasImage"
        static let hasRichText = "hasRichText"
        static let hasHTML = "hasHTML"
        static let imageByteCount = "imageByteCount"
        static let imageFormat = "imageFormat"
        static let isCode = "isCode"
        static let detectedLanguage = "detectedLanguage"
        static let extractedText = "extractedText"
        static let types = "types"
        static let addDate = "addDate"
        static let lastUsedDate = "lastUsedDate"
        static let copiedDate = "copiedDate"
        static let deleteDate = "deleteDate"
        static let modifiedDate = "modifiedDate"
        static let deviceName = "deviceName"
        static let appName = "appName"
        static let appBundleID = "appBundleID"
        static let imageWidth = "imageWidth"
        static let imageHeight = "imageHeight"
        static let isFavorite = "isFavorite"
        static let isPinned = "isPinned"
        static let listIndex = "listIndex"
        static let list = "list" // CKReference to ClipList

        // ClipList
        static let name = "name"
        static let colorHex = "colorHex"
        static let sortOrder = "sortOrder"
        static let isDefault = "isDefault"
        static let isSmartList = "isSmartList"
        static let smartPredicate = "smartPredicate"
        static let createdDate = "createdDate"
    }

    // MARK: - Temp-file handling for CKAsset blobs

    /// Directory for outbound blob staging — CKAsset reads from this
    /// URL at upload time. Cleaned up when `.sentRecordZoneChanges`
    /// confirms the blob landed (Phase 4).
    private static let outboundBlobsDir: URL = {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("CopiedSync/outbound-blobs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func writeTempBlob(_ data: Data, key: String, recordName: String) -> URL? {
        let file = outboundBlobsDir.appendingPathComponent("\(recordName).\(key).bin")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            NSLog("[CKRecordMapper] writeTempBlob \(key) failed: \(error)")
            return nil
        }
    }

    /// Helper used by `apply(_:to:prefetchedBlobs:)` to assign one blob
    /// field on a Clipping. Three semantic cases must be preserved
    /// (matches the pre-COP-108 inline behavior exactly):
    ///   1. Caller pre-read the blob off-main → assign it.
    ///   2. Record has a CKAsset but no prefetch → fall back to a
    ///      synchronous `Data(contentsOf:)` read (memory-mapped). Keeps
    ///      callers that haven't been migrated to the prefetched-blobs
    ///      path working.
    ///   3. Record explicitly has no CKAsset for this field → clear the
    ///      local blob (so deletes propagate).
    /// CKAsset present but read fails → leave existing value alone.
    private static func applyBlob(
        record: CKRecord,
        field: String,
        prefetched: Data?,
        assign: (Data?) -> Void
    ) {
        if let prefetched {
            assign(prefetched)
            return
        }
        if let asset = record[field] as? CKAsset {
            if let url = asset.fileURL,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                assign(data)
            }
            // asset present but read failed → leave existing value
        } else if record[field] == nil {
            assign(nil)
        }
    }

    // MARK: - Clipping → CKRecord

    /// Populate `record` from `clipping`. If a `lastKnownRecord` exists
    /// (from a previous fetch), merge onto that so unchanged CKRecord
    /// metadata (parent, encryption, etc.) is preserved. CKSyncEngine
    /// recommends this pattern.
    public static func populate(_ record: CKRecord, from clipping: Clipping) {
        record[Field.contentHash] = clipping.contentHash as NSString
        record[Field.text] = clipping.text as NSString?
        record[Field.title] = clipping.title as NSString?
        record[Field.url] = clipping.url as NSString?
        record[Field.sourceURL] = clipping.sourceURL as NSString?
        record[Field.hasImage] = clipping.hasImage as NSNumber
        record[Field.hasRichText] = clipping.hasRichText as NSNumber
        record[Field.hasHTML] = clipping.hasHTML as NSNumber
        record[Field.imageByteCount] = clipping.imageByteCount as NSNumber
        record[Field.imageFormat] = clipping.imageFormat as NSString
        record[Field.isCode] = clipping.isCode as NSNumber
        record[Field.detectedLanguage] = clipping.detectedLanguage as NSString?
        record[Field.extractedText] = clipping.extractedText as NSString?
        record[Field.types] = clipping.types as NSArray
        record[Field.addDate] = clipping.addDate as NSDate
        record[Field.lastUsedDate] = clipping.lastUsedDate as NSDate?
        record[Field.copiedDate] = clipping.copiedDate as NSDate?
        record[Field.deleteDate] = clipping.deleteDate as NSDate?
        record[Field.modifiedDate] = (clipping.modifiedDate ?? clipping.addDate) as NSDate
        record[Field.deviceName] = clipping.deviceName as NSString
        record[Field.appName] = clipping.appName as NSString?
        record[Field.appBundleID] = clipping.appBundleID as NSString?
        record[Field.imageWidth] = clipping.imageWidth as NSNumber
        record[Field.imageHeight] = clipping.imageHeight as NSNumber
        record[Field.isFavorite] = clipping.isFavorite as NSNumber
        record[Field.isPinned] = clipping.isPinned as NSNumber
        record[Field.listIndex] = clipping.listIndex as NSNumber

        // Binary blobs → CKAsset. Materialize to temp file only if data
        // is present; CKAsset requires a readable file URL at send time.
        if let d = clipping.imageData {
            if let url = writeTempBlob(d, key: "imageData", recordName: clipping.clippingID) {
                record[Field.imageData] = CKAsset(fileURL: url)
            }
        } else {
            record[Field.imageData] = nil
        }
        if let d = clipping.richTextData {
            if let url = writeTempBlob(d, key: "richTextData", recordName: clipping.clippingID) {
                record[Field.richTextData] = CKAsset(fileURL: url)
            }
        } else {
            record[Field.richTextData] = nil
        }
        if let d = clipping.htmlData {
            if let url = writeTempBlob(d, key: "htmlData", recordName: clipping.clippingID) {
                record[Field.htmlData] = CKAsset(fileURL: url)
            }
        } else {
            record[Field.htmlData] = nil
        }

        // Relationship to ClipList. `.none` action because CK doesn't
        // enforce our business rule (orphan clippings are fine — they
        // just drop back to "All Clippings").
        if let listID = clipping.list?.listID {
            let listRef = CKRecord.Reference(
                recordID: CopiedSyncEngine.clipListRecordID(listID),
                action: .none
            )
            record[Field.list] = listRef
        } else {
            record[Field.list] = nil
        }
    }

    /// Bytes pre-loaded from a CKRecord's CKAsset fileURLs on a background
    /// queue, so the caller can pass them into `apply(...)` and avoid the
    /// synchronous `Data(contentsOf:)` main-thread reads (COP-108).
    ///
    /// All three fields are optional — nil means either no asset was on
    /// the record or the off-main prefetch couldn't read it (in which case
    /// `apply` falls back to the synchronous read, preserving prior
    /// behavior).
    public struct PrefetchedBlobs: Sendable {
        public let image: Data?
        public let richText: Data?
        public let html: Data?
        public init(image: Data? = nil, richText: Data? = nil, html: Data? = nil) {
            self.image = image
            self.richText = richText
            self.html = html
        }
    }

    /// Sendable URL bundle for a single CKRecord, used to ship CKAsset
    /// fileURLs across actor boundaries without carrying the CKRecord
    /// itself (which is a reference type and non-Sendable in Swift 6).
    /// Returned from `blobURLs(in:)` and consumed by off-main prefetch
    /// loops in `CopiedSyncEngine.applyManualPullChanges`.
    public struct BlobURLs: Sendable {
        public let recordName: String
        public let image: URL?
        public let richText: URL?
        public let html: URL?
    }

    /// Extract the CKAsset fileURLs for a Clipping CKRecord. Caller passes
    /// the result into a background task to read the bytes off-main,
    /// then feeds the resulting `PrefetchedBlobs` back into `apply`.
    public static func blobURLs(in record: CKRecord) -> BlobURLs {
        BlobURLs(
            recordName: record.recordID.recordName,
            image: (record[Field.imageData] as? CKAsset)?.fileURL,
            richText: (record[Field.richTextData] as? CKAsset)?.fileURL,
            html: (record[Field.htmlData] as? CKAsset)?.fileURL
        )
    }

    /// Apply fields from `record` onto `clipping` (in-place upsert).
    /// Caller is responsible for conflict resolution (LWW on
    /// `modifiedDate`) before invoking — this method unconditionally
    /// overwrites every field.
    ///
    /// `prefetchedBlobs` — if provided, the three blob fields use these
    /// Data values and SKIP the synchronous `Data(contentsOf:)` disk read.
    /// Pass nil (the default) when the caller hasn't done off-main
    /// prefetching; the original synchronous-read path runs in that case.
    public static func apply(_ record: CKRecord, to clipping: Clipping, prefetchedBlobs: PrefetchedBlobs? = nil) {
        clipping.contentHash = (record[Field.contentHash] as? String) ?? clipping.contentHash
        clipping.text = record[Field.text] as? String
        clipping.title = record[Field.title] as? String
        clipping.url = record[Field.url] as? String
        clipping.sourceURL = record[Field.sourceURL] as? String
        clipping.hasImage = (record[Field.hasImage] as? Bool) ?? false
        clipping.hasRichText = (record[Field.hasRichText] as? Bool) ?? false
        clipping.hasHTML = (record[Field.hasHTML] as? Bool) ?? false
        clipping.imageByteCount = (record[Field.imageByteCount] as? Int) ?? 0
        clipping.imageFormat = (record[Field.imageFormat] as? String) ?? "tiff"
        clipping.isCode = (record[Field.isCode] as? Bool) ?? false
        clipping.detectedLanguage = record[Field.detectedLanguage] as? String
        clipping.extractedText = record[Field.extractedText] as? String
        clipping.types = (record[Field.types] as? [String]) ?? []
        if let d = record[Field.addDate] as? Date { clipping.addDate = d }
        clipping.lastUsedDate = record[Field.lastUsedDate] as? Date
        clipping.copiedDate = record[Field.copiedDate] as? Date
        clipping.deleteDate = record[Field.deleteDate] as? Date
        clipping.modifiedDate = record[Field.modifiedDate] as? Date
        clipping.deviceName = (record[Field.deviceName] as? String) ?? ""
        clipping.appName = record[Field.appName] as? String
        clipping.appBundleID = record[Field.appBundleID] as? String
        clipping.imageWidth = (record[Field.imageWidth] as? Double) ?? 0
        clipping.imageHeight = (record[Field.imageHeight] as? Double) ?? 0
        clipping.isFavorite = (record[Field.isFavorite] as? Bool) ?? false
        clipping.isPinned = (record[Field.isPinned] as? Bool) ?? false
        clipping.listIndex = (record[Field.listIndex] as? Int) ?? 0

        // Load blobs from CKAsset fileURLs. CloudKit has already
        // downloaded the asset to local disk by the time the
        // .fetchedRecordZoneChanges event fires.
        //
        // COP-108: prefer caller-provided prefetched Data (read off-main
        // before the upsert). Fall back to synchronous `Data(contentsOf:)`
        // when no prefetch was supplied — keeps backward compatibility for
        // call sites that don't yet thread prefetched blobs through.
        applyBlob(record: record, field: Field.imageData, prefetched: prefetchedBlobs?.image) {
            clipping.imageData = $0
        }
        applyBlob(record: record, field: Field.richTextData, prefetched: prefetchedBlobs?.richText) {
            clipping.richTextData = $0
        }
        applyBlob(record: record, field: Field.htmlData, prefetched: prefetchedBlobs?.html) {
            clipping.htmlData = $0
        }

        // ClipList relationship is resolved by the caller (which has
        // the ModelContext to look up the ClipList by ID). We expose
        // the referenced list ID as a helper.
    }

    /// Extract the referenced ClipList ID from a Clipping record, if any.
    /// The caller uses this to resolve the SwiftData relationship after
    /// upsert.
    public static func listID(from clippingRecord: CKRecord) -> String? {
        (clippingRecord[Field.list] as? CKRecord.Reference)?.recordID.recordName
    }

    // MARK: - ClipList → CKRecord

    public static func populate(_ record: CKRecord, from list: ClipList) {
        record[Field.name] = list.name as NSString
        record[Field.colorHex] = list.colorHex as NSNumber
        record[Field.sortOrder] = list.sortOrder as NSNumber
        record[Field.isDefault] = list.isDefault as NSNumber
        record[Field.isSmartList] = list.isSmartList as NSNumber
        record[Field.smartPredicate] = list.smartPredicate as NSString?
        record[Field.createdDate] = list.createdDate as NSDate
        record[Field.modifiedDate] = (list.modifiedDate ?? list.createdDate) as NSDate
    }

    public static func apply(_ record: CKRecord, to list: ClipList) {
        list.name = (record[Field.name] as? String) ?? list.name
        list.colorHex = (record[Field.colorHex] as? Int) ?? list.colorHex
        list.sortOrder = (record[Field.sortOrder] as? Int) ?? 0
        list.isDefault = (record[Field.isDefault] as? Bool) ?? false
        list.isSmartList = (record[Field.isSmartList] as? Bool) ?? false
        list.smartPredicate = record[Field.smartPredicate] as? String
        if let d = record[Field.createdDate] as? Date { list.createdDate = d }
        list.modifiedDate = record[Field.modifiedDate] as? Date
    }
}
