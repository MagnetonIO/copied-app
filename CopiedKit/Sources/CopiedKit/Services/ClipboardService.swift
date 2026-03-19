import Foundation
import SwiftData
import Observation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
    private var maxHistory: Int

    public init(maxHistory: Int = 5000) {
        self.maxHistory = maxHistory
        // Read settings from UserDefaults
        self.allowDuplicates = UserDefaults.standard.bool(forKey: "allowDuplicates")
        self.captureImages = UserDefaults.standard.object(forKey: "captureImages") as? Bool ?? true
        self.captureRichText = UserDefaults.standard.object(forKey: "captureRichText") as? Bool ?? true
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

    private func captureFromPasteboard(_ pasteboard: NSPasteboard) {
        guard let modelContext else { return }
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        // Skip if frontmost app is excluded
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bundleID) {
            return
        }

        let clipping = Clipping()
        var didCapture = false

        let availableTypes = items.first?.types ?? []
        clipping.types = availableTypes.map(\.rawValue)

        // Text content
        if let str = pasteboard.string(forType: .string), !str.isEmpty {
            clipping.text = str
            didCapture = true
        }

        // URL — check .URL type first, then detect URLs in text
        if let urlStr = pasteboard.string(forType: .URL), !urlStr.isEmpty,
           !urlStr.hasPrefix("file://") {
            clipping.url = urlStr
            didCapture = true
        } else if clipping.url == nil, let text = clipping.text {
            // Detect if the entire text is a URL (common when copying from address bar)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2048,
               !trimmed.contains("\n"),
               let url = URL(string: trimmed),
               let scheme = url.scheme,
               ["http", "https", "ftp", "ssh"].contains(scheme),
               url.host != nil {
                clipping.url = trimmed
            }
        }

        // Image — BUG-14 fix: store raw data, don't re-encode TIFF
        if !captureImages {
            // Skip image capture when disabled
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            clipping.imageData = tiffData
            clipping.hasImage = true
            clipping.imageByteCount = tiffData.count
            clipping.imageFormat = "tiff"
            if let image = NSImage(data: tiffData) {
                clipping.imageWidth = Double(image.size.width)
                clipping.imageHeight = Double(image.size.height)
            }
            didCapture = true
        } else if let pngData = pasteboard.data(forType: .png) {
            clipping.imageData = pngData
            clipping.hasImage = true
            clipping.imageByteCount = pngData.count
            clipping.imageFormat = "png"
            if let image = NSImage(data: pngData) {
                clipping.imageWidth = Double(image.size.width)
                clipping.imageHeight = Double(image.size.height)
            }
            didCapture = true
        } else if let imageData = imageDataFromFileURL(pasteboard) {
            // File URL pointing to an image (e.g. copying a screenshot file from Finder)
            clipping.imageData = imageData.data
            clipping.hasImage = true
            clipping.imageByteCount = imageData.data.count
            clipping.imageFormat = imageData.format
            if let image = NSImage(data: imageData.data) {
                clipping.imageWidth = Double(image.size.width)
                clipping.imageHeight = Double(image.size.height)
            }
            didCapture = true
        }

        // Rich text (RTF/RTFD)
        if captureRichText, let rtfData = pasteboard.data(forType: .rtf) ?? pasteboard.data(forType: .rtfd) {
            clipping.richTextData = rtfData
            clipping.hasRichText = true
            didCapture = true
        }

        // HTML content
        if let htmlData = pasteboard.data(forType: .html) {
            clipping.htmlData = htmlData
            clipping.hasHTML = true
        }

        guard didCapture else { return }

        // Code detection
        if let text = clipping.text {
            let detection = CodeDetector.detect(in: text)
            clipping.isCode = detection.isCode
            clipping.detectedLanguage = detection.language
        }

        // Dedup check — skip if user allows duplicates
        if !allowDuplicates && isDuplicateOfLast(clipping) { return }

        // Source app — store bundle ID only, NOT the icon data (icons are 2-5MB each as TIFF)
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            clipping.appName = frontApp.localizedName
            clipping.appBundleID = frontApp.bundleIdentifier
        }

        clipping.deviceName = Host.current().localizedName ?? "Mac"

        modelContext.insert(clipping)
        try? modelContext.save()
        lastCapturedDate = Date()
        captureCount += 1

        // Play capture sound if enabled
        if UserDefaults.standard.bool(forKey: "playSounds") {
            NSSound(named: .init("Morse"))?.play()
        }

        enforceHistoryLimit()
    }

    private struct FileImageData {
        let data: Data
        let format: String
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp", "heic"]

    /// Reads image data from a file URL on the pasteboard (e.g. copying a screenshot file from Finder).
    /// Checks multiple pasteboard types: public.file-url, NSFilenamesPboardType, readObjects(NSURL).
    private func imageDataFromFileURL(_ pasteboard: NSPasteboard) -> FileImageData? {
        // Strategy 1: Read file URL string from pasteboard
        if let url = fileURLFromPasteboard(pasteboard) {
            if let result = readImageFile(at: url) { return result }
        }

        // Strategy 2: NSFilenamesPboardType (legacy, still used by Finder)
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let data = pasteboard.data(forType: filenameType),
           let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                if let result = readImageFile(at: url) { return result }
            }
        }

        // Strategy 3: readObjects (modern NSPasteboardReading API)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            for url in urls {
                if let result = readImageFile(at: url) { return result }
            }
        }

        return nil
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
    private func readImageFile(at url: URL) -> FileImageData? {
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
