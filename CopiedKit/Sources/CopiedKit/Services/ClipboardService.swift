import Foundation
import SwiftData
import Observation

#if canImport(AppKit)
import AppKit
import ImageIO
import AVFoundation
#elseif canImport(UIKit)
import UIKit
#endif

/// Sendable snapshot of a single pasteboard read, produced on the main actor.
/// Passed to `ClipboardService.processCapture(_:captureImages:captureRichText:)`
/// which runs in a detached task.
private struct CaptureInput: Sendable {
    let addDate: Date
    let types: [String]
    let text: String?
    let urlString: String?
    let tiffData: Data?
    let pngData: Data?
    let richTextData: Data?
    let htmlData: Data?
    let candidateFileURLs: [URL]
    let appName: String?
    let appBundleID: String?
    let deviceName: String
}

/// Output of the detached Phase B. Hands back to the main actor for Clipping construction
/// and insertion. All fields are Sendable value types.
private struct CaptureResult: Sendable {
    var imageData: Data?
    var imageFormat: String?
    var imageWidth: Double = 0
    var imageHeight: Double = 0
    var imageByteCount: Int = 0
    var hasImage: Bool = false
    var richTextData: Data?
    var hasRichText: Bool = false
    var htmlData: Data?
    var hasHTML: Bool = false
    var extractedText: String?
    var sourceURL: String?
    var videoTitle: String?
}

/// Monitors the system pasteboard and saves new clippings to SwiftData.
@Observable
@MainActor
public final class ClipboardService {
    public var isMonitoring: Bool = false
    public var lastCapturedDate: Date?
    public var captureCount: Int = 0
    public var excludedBundleIDs: Set<String> = []

    // User-configurable capture settings
    public var allowDuplicates: Bool = false
    public var captureImages: Bool = true
    public var captureRichText: Bool = true

    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    /// Set to true before writing to pasteboard, cleared after poll skips the self-write
    public var skipNextCapture: Bool = false
    private var modelContext: ModelContext?
    private var maxHistoryOverride: Int?

    /// Max non-favorite/non-pinned clippings before trimming. Reads live from
    /// UserDefaults("maxHistorySize") unless a constructor override is set (tests).
    public var maxHistory: Int {
        if let maxHistoryOverride { return maxHistoryOverride }
        let stored = UserDefaults.standard.integer(forKey: "maxHistorySize")
        return stored > 0 ? stored : 5000
    }

    public init(maxHistory: Int? = nil) {
        self.maxHistoryOverride = maxHistory
        self.allowDuplicates = UserDefaults.standard.bool(forKey: "allowDuplicates")
        self.captureImages = UserDefaults.standard.object(forKey: "captureImages") as? Bool ?? true
        self.captureRichText = UserDefaults.standard.object(forKey: "captureRichText") as? Bool ?? true
    }

    /// Trim history to `maxHistory` immediately. Call this from Settings when
    /// the user lowers the limit so trimming doesn't wait for the next capture.
    public func trimHistoryNow() {
        enforceHistoryLimit()
        trimByAge()
        purgeOldTrash()
    }

    /// Retention (days) read live from UserDefaults. -1 or 0 disables it.
    public var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "retentionDays")
        return stored == 0 ? -1 : stored
    }

    /// Trash retention (days) — how long a trashed clipping stays recoverable before
    /// it's permanently deleted. Default 30 days (registered in AppDelegate). -1 disables.
    public var trashRetentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "trashRetentionDays")
        return stored == 0 ? 30 : stored
    }

    /// Deletes non-favorite, non-pinned clippings older than `retentionDays`.
    /// No-op when retention is -1 ("Never").
    public func trimByAge() {
        guard let modelContext, retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { clipping in
                clipping.isFavorite == false &&
                clipping.isPinned == false &&
                clipping.deleteDate == nil &&
                clipping.addDate < cutoff
            }
        )
        guard let expired = try? modelContext.fetch(descriptor), !expired.isEmpty else { return }
        for clipping in expired {
            modelContext.delete(clipping)
        }
        try? modelContext.save()
    }

    /// Permanently deletes trashed clippings whose `deleteDate` is older than
    /// `trashRetentionDays`. Keeps favorites out (a user can favorite something
    /// already in trash; better not to surprise-delete it).
    public func purgeOldTrash() {
        guard let modelContext, trashRetentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(trashRetentionDays) * 86_400)
        let descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { clipping in
                clipping.isFavorite == false && clipping.deleteDate != nil
            }
        )
        guard let trashed = try? modelContext.fetch(descriptor) else { return }
        let expired = trashed.filter { ($0.deleteDate ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        for clipping in expired {
            modelContext.delete(clipping)
        }
        try? modelContext.save()
    }

    public func configure(modelContext: ModelContext) {
        modelContext.autosaveEnabled = true
        self.modelContext = modelContext
        reclassifyIfNeeded()
    }

    // MARK: - Start / Stop

    public func start() {
        guard !isMonitoring else { return }
        #if canImport(AppKit)
        lastChangeCount = NSPasteboard.general.changeCount
        isMonitoring = true

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                await self?.poll()
            }
        }
        #endif
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
    }

    // MARK: - Manual Save

    public func saveCurrentClipboard() {
        #if canImport(AppKit)
        captureFromPasteboard(NSPasteboard.general)
        #elseif canImport(UIKit)
        captureFromUIPasteboard()
        #endif
    }

    // MARK: - macOS Polling

    #if canImport(AppKit)
    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Skip captures triggered by our own copyToClipboard
        if skipNextCapture {
            skipNextCapture = false
            return
        }
        captureFromPasteboard(pasteboard)
    }

    /// COP-42: capture now runs in three phases.
    ///   A (main): pasteboard read → Sendable `CaptureInput` snapshot.
    ///   B (detached): image/video/RTF/HTML decode → `CaptureResult`.
    ///   C (main): build Clipping, dedup, insert, save.
    /// `poll()` still advances lastChangeCount and clears skipNextCapture on main before us.
    private func captureFromPasteboard(_ pasteboard: NSPasteboard) {
        guard let input = extractCaptureInput(from: pasteboard) else { return }
        let captureImages = self.captureImages
        let captureRichText = self.captureRichText
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.processCapture(
                input,
                captureImages: captureImages,
                captureRichText: captureRichText
            )
            await self?.finalizeCapture(input: input, result: result)
        }
    }

    // MARK: - Phase A (main): pasteboard read into a Sendable snapshot.

    private func extractCaptureInput(from pasteboard: NSPasteboard) -> CaptureInput? {
        guard modelContext != nil else { return nil }
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bundleID) {
            return nil
        }

        let types = (items.first?.types ?? []).map(\.rawValue)
        let text = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        let urlString = pasteboard.string(forType: .URL).flatMap { $0.isEmpty ? nil : $0 }
        let tiffData = captureImages ? pasteboard.data(forType: .tiff) : nil
        let pngData = captureImages ? pasteboard.data(forType: .png) : nil
        let richTextData = captureRichText
            ? (pasteboard.data(forType: .rtfd) ?? pasteboard.data(forType: .rtf))
            : nil
        let htmlData = pasteboard.data(forType: .html)
        let fileURLs = candidateFileURLs(from: pasteboard)

        let frontApp = NSWorkspace.shared.frontmostApplication
        return CaptureInput(
            addDate: Date(),
            types: types,
            text: text,
            urlString: urlString,
            tiffData: tiffData,
            pngData: pngData,
            richTextData: richTextData,
            htmlData: htmlData,
            candidateFileURLs: fileURLs,
            appName: frontApp?.localizedName,
            appBundleID: frontApp?.bundleIdentifier,
            deviceName: Host.current().localizedName ?? "Mac"
        )
    }

    /// Collects every file URL the pasteboard exposes across the three discovery paths
    /// (direct .fileURL, legacy NSFilenamesPboardType, modern readObjects). Stays on main
    /// because NSPasteboard is not thread-safe. Disk reads happen later in Phase B.
    private func candidateFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let url = fileURLFromPasteboard(pasteboard) {
            urls.append(url)
        }
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let data = pasteboard.data(forType: filenameType),
           let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            for path in paths {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        if let fromReadObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            urls.append(contentsOf: fromReadObjects)
        }
        return urls
    }

    // MARK: - Phase C (main): build Clipping + dedup + insert.

    @MainActor
    private func finalizeCapture(input: CaptureInput, result: CaptureResult) {
        guard let modelContext else { return }

        let clipping = Clipping()
        clipping.addDate = input.addDate
        clipping.types = input.types
        clipping.text = input.text

        // URL handling (sanitize). Matches the pre-refactor logic exactly.
        if let urlStr = input.urlString, !urlStr.hasPrefix("file://") {
            let cleaned = Self.sanitizeURL(urlStr)
            clipping.url = cleaned
            if let text = clipping.text,
               text.trimmingCharacters(in: .whitespacesAndNewlines) == urlStr {
                clipping.text = cleaned
            }
        } else if clipping.url == nil, let text = clipping.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2048,
               !trimmed.contains("\n"),
               let url = URL(string: trimmed),
               let scheme = url.scheme,
               ["http", "https", "ftp", "ssh"].contains(scheme),
               url.host != nil {
                let cleaned = Self.sanitizeURL(trimmed)
                clipping.url = cleaned
                clipping.text = cleaned
            }
        }

        // Copy Phase B output
        clipping.imageData = result.imageData
        if let format = result.imageFormat { clipping.imageFormat = format }
        clipping.imageByteCount = result.imageByteCount
        clipping.imageWidth = result.imageWidth
        clipping.imageHeight = result.imageHeight
        clipping.hasImage = result.hasImage
        clipping.richTextData = result.richTextData
        clipping.hasRichText = result.hasRichText
        clipping.htmlData = result.htmlData
        clipping.hasHTML = result.hasHTML
        clipping.extractedText = result.extractedText
        clipping.sourceURL = result.sourceURL
        if clipping.title == nil, let videoTitle = result.videoTitle {
            clipping.title = videoTitle
        }

        let didCapture = clipping.text != nil
            || clipping.url != nil
            || clipping.hasImage
            || clipping.hasRichText
            || clipping.sourceURL != nil
        guard didCapture else { return }

        if let text = clipping.text {
            let detection = CodeDetector.detect(in: text)
            clipping.isCode = detection.isCode
            clipping.detectedLanguage = detection.language
        }

        // Known edge (not fixed): if two finalizeCapture runs of identical content arrive
        // before the first has saved, both can pass dedup. Polling is 500 ms so in practice
        // only reachable via saveCurrentClipboard bursts.
        if !allowDuplicates && isDuplicateOfLast(clipping) { return }

        clipping.appName = input.appName
        clipping.appBundleID = input.appBundleID
        clipping.deviceName = input.deviceName

        modelContext.insert(clipping)
        try? modelContext.save()
        lastCapturedDate = Date()
        captureCount += 1

        enforceHistoryLimit()
        trimByAge()
        purgeOldTrash()
    }

    // MARK: - Phase B (detached): decode / extract / thumbnail.

    nonisolated private static func processCapture(
        _ input: CaptureInput,
        captureImages: Bool,
        captureRichText: Bool
    ) -> CaptureResult {
        var result = CaptureResult()

        // Image data from pasteboard blobs first, then file URL disk read.
        if captureImages {
            if let tiff = input.tiffData {
                result.imageData = tiff
                result.imageFormat = "tiff"
                result.imageByteCount = tiff.count
                result.hasImage = true
            } else if let png = input.pngData {
                result.imageData = png
                result.imageFormat = "png"
                result.imageByteCount = png.count
                result.hasImage = true
            } else {
                for url in input.candidateFileURLs {
                    if let fid = readImageFile(at: url) {
                        result.imageData = fid.data
                        result.imageFormat = fid.format
                        result.imageByteCount = fid.data.count
                        result.hasImage = true
                        break
                    }
                }
            }
        }

        // Rich text / HTML passthrough
        if captureRichText, let rtf = input.richTextData {
            result.richTextData = rtf
            result.hasRichText = true
        }
        if let html = input.htmlData {
            result.htmlData = html
            result.hasHTML = true
        }

        // Extract plain text from HTML/RTF for search indexing.
        if result.extractedText == nil {
            if let html = result.htmlData, let extracted = plainTextFromHTML(html) {
                result.extractedText = extracted
            } else if let rtf = result.richTextData, let extracted = plainTextFromRTF(rtf) {
                result.extractedText = extracted
            }
        }

        // Video file URL — augment with a frame thumbnail if the pasteboard didn't carry one.
        for url in input.candidateFileURLs {
            guard Clipping.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            result.sourceURL = url.absoluteString
            result.videoTitle = url.lastPathComponent
            if !result.hasImage, let thumb = generateVideoThumbnail(from: url) {
                result.imageData = thumb.data
                result.imageFormat = "png"
                result.imageWidth = thumb.width
                result.imageHeight = thumb.height
                result.imageByteCount = thumb.data.count
                result.hasImage = true
            }
            break
        }

        // Fill in dimensions if we have image bytes but no size yet.
        if result.imageWidth == 0, let data = result.imageData,
           let dims = imageDimensions(from: data) {
            result.imageWidth = dims.width
            result.imageHeight = dims.height
        }

        return result
    }

    private struct FileImageData: Sendable {
        let data: Data
        let format: String
    }

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp", "heic"]

    /// Query parameters the standard marketing / analytics ecosystem appends to
    /// shared links. Stripped from captured URLs when `stripURLTrackingParams`
    /// is enabled (default on). Matched case-insensitively. `utm_*` matched by
    /// prefix — any `utm_anything` is stripped.
    private static let trackingParamNames: Set<String> = [
        "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "ref", "_hsenc", "_hsmi",
        "mkt_tok", "yclid", "wickedid", "oly_anon_id", "oly_enc_id", "__s", "vero_id"
    ]

    /// Strips tracking params (utm_*, fbclid, gclid, etc.) from a URL string
    /// when the `stripURLTrackingParams` setting is on. Returns the original
    /// string if the URL can't be parsed or the setting is off.
    static func sanitizeURL(_ urlString: String) -> String {
        guard UserDefaults.standard.object(forKey: "stripURLTrackingParams") as? Bool ?? true else {
            return urlString
        }
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems else {
            return urlString
        }
        let filtered = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") { return false }
            return !trackingParamNames.contains(name)
        }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }

    /// Grabs a frame from a video file and returns PNG-encoded bytes plus
    /// pixel dimensions. Returns nil if the asset has no video track or frame
    /// extraction fails (unreadable file, format not supported, etc.). Runs
    /// synchronously on the capture thread — at the 512 px cap the decode is
    /// fast enough (tens of ms) not to affect polling responsiveness.
    nonisolated private static func generateVideoThumbnail(from url: URL) -> (data: Data, width: Double, height: Double)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)

        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            // Fall back to time zero — some clips are <1s long
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let retryCGImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return encodePNG(retryCGImage)
        }
        return encodePNG(cgImage)
    }

    nonisolated private static func encodePNG(_ cgImage: CGImage) -> (data: Data, width: Double, height: Double)? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData,
                                                                  "public.png" as CFString,
                                                                  1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (mutableData as Data, Double(cgImage.width), Double(cgImage.height))
    }

    /// Extracts plain text from HTML data for search indexing. Returns nil
    /// if parsing fails; caller should try a different format.
    nonisolated private static func plainTextFromHTML(_ data: Data) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(5000))
    }

    /// Extracts plain text from RTF/RTFD data for search indexing.
    nonisolated private static func plainTextFromRTF(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(data: data, documentAttributes: nil) else {
            return nil
        }
        let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(5000))
    }

    nonisolated private static func imageDimensions(from data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        return (width.doubleValue, height.doubleValue)
    }

    /// Extracts a file URL from the pasteboard's string types, handling percent-encoding edge cases.
    private func fileURLFromPasteboard(_ pasteboard: NSPasteboard) -> URL? {
        guard let urlStr = pasteboard.string(forType: .fileURL) ?? pasteboard.string(forType: .URL),
              urlStr.hasPrefix("file://") else { return nil }

        // Try direct parsing first
        if let url = URL(string: urlStr) { return url }

        // Fallback: percent-encode the path portion for URLs with spaces/special chars
        let pathPortion = String(urlStr.dropFirst("file://".count))
        if let encoded = pathPortion.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "file://" + encoded) {
            return url
        }

        return nil
    }

    /// Reads image data from a file URL if it points to a supported image format.
    nonisolated private static func readImageFile(at url: URL) -> FileImageData? {
        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        let format: String
        switch ext {
        case "png": format = "png"
        case "jpg", "jpeg": format = "jpeg"
        case "gif": format = "gif"
        case "webp": format = "webp"
        case "heic": format = "heic"
        default: format = "tiff"
        }
        return FileImageData(data: data, format: format)
    }
    #endif

    // MARK: - iOS Capture

    #if canImport(UIKit) && !os(macOS)
    private func captureFromUIPasteboard() {
        guard let modelContext else { return }
        let pasteboard = UIPasteboard.general

        let clipping = Clipping()
        var didCapture = false

        if let str = pasteboard.string, !str.isEmpty {
            clipping.text = str
            didCapture = true
        }

        if let url = pasteboard.url {
            clipping.url = url.absoluteString
            didCapture = true
        }

        if let image = pasteboard.image, let data = image.pngData() {
            clipping.imageData = data
            clipping.imageWidth = Double(image.size.width)
            clipping.imageHeight = Double(image.size.height)
            didCapture = true
        }

        clipping.deviceName = UIDevice.current.name

        guard didCapture else { return }

        // Dedup check
        if !allowDuplicates && isDuplicateOfLast(clipping) { return }

        modelContext.insert(clipping)
        try? modelContext.save()
        lastCapturedDate = Date()
        captureCount += 1
    }
    #endif

    // MARK: - Reclassify Existing Clippings

    private static let reclassifyKey = "didReclassifyClippingsV2"

    /// One-time migration: re-runs URL and code detection on existing clippings
    /// that were captured before detection logic was added.
    private func reclassifyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.reclassifyKey) else { return }
        guard let modelContext else { return }

        var descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.deleteDate == nil }
        )
        descriptor.fetchLimit = 5000

        guard let clippings = try? modelContext.fetch(descriptor) else { return }

        var changed = false
        for clipping in clippings {
            // URL detection on text
            if clipping.url == nil, let text = clipping.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < 2048,
                   !trimmed.contains("\n"),
                   let url = URL(string: trimmed),
                   let scheme = url.scheme,
                   ["http", "https", "ftp", "ssh"].contains(scheme),
                   url.host != nil {
                    clipping.url = trimmed
                    changed = true
                }
            }

            // Code detection on text (re-run on all items — detector may have improved)
            if let text = clipping.text {
                let detection = CodeDetector.detect(in: text)
                if detection.isCode != clipping.isCode || detection.language != clipping.detectedLanguage {
                    clipping.isCode = detection.isCode
                    clipping.detectedLanguage = detection.language
                    changed = true
                }
            }
        }

        if changed {
            try? modelContext.save()
        }
        UserDefaults.standard.set(true, forKey: Self.reclassifyKey)
    }

    // MARK: - Dedup & Limits

    /// Checks if a new clipping is identical to any of the last N clippings.
    /// Compares text, URL, and image dimensions+size to catch all content types.
    private static let dedupWindowSize = 10

    private func isDuplicateOfLast(_ candidate: Clipping) -> Bool {
        guard let modelContext else { return false }

        var descriptor = FetchDescriptor<Clipping>(
            sortBy: [SortDescriptor(\.addDate, order: .reverse)]
        )
        descriptor.fetchLimit = Self.dedupWindowSize

        guard let recentClippings = try? modelContext.fetch(descriptor), !recentClippings.isEmpty else { return false }

        for existing in recentClippings {
            // Text match — BUG-03 fix: don't access imageData, use hasImage scalar
            if let newText = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               let oldText = existing.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !newText.isEmpty, newText == oldText {
                if !candidate.hasImage && !existing.hasImage {
                    return true
                }
            }

            // Image match — use scalar imageByteCount instead of loading imageData
            if candidate.hasImage && existing.hasImage {
                if candidate.imageWidth == existing.imageWidth &&
                   candidate.imageHeight == existing.imageHeight &&
                   candidate.imageByteCount == existing.imageByteCount {
                    return true
                }
            }

            // URL-only match
            if candidate.text == nil && !candidate.hasImage,
               let newURL = candidate.url, let oldURL = existing.url,
               newURL == oldURL {
                return true
            }
        }

        return false
    }

    private func enforceHistoryLimit() {
        guard let modelContext else { return }

        // Only count non-trashed items toward the limit
        let countDescriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.deleteDate == nil }
        )
        guard let total = try? modelContext.fetchCount(countDescriptor), total > maxHistory else { return }

        var oldest = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.isFavorite == false && $0.isPinned == false && $0.deleteDate == nil },
            sortBy: [SortDescriptor(\.addDate, order: .forward)]
        )
        oldest.fetchLimit = total - maxHistory

        if let toDelete = try? modelContext.fetch(oldest) {
            for clipping in toDelete {
                modelContext.delete(clipping)
            }
            try? modelContext.save()
        }
    }
}
