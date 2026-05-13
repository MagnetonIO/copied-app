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
    /// Pre-computed in Phase B (off-main) so `finalizeCapture` doesn't burn
    /// 80+ regex compiles on `@MainActor` per system copy event.
    var isCode: Bool = false
    var detectedLanguage: String?
}

/// Monitors the system pasteboard and saves new clippings to SwiftData.
@Observable
@MainActor
public final class ClipboardService {
    public var isMonitoring: Bool = false
    public var lastCapturedDate: Date?
    public var captureCount: Int = 0
    public var excludedBundleIDs: Set<String> = []

    /// COP-109: hard-coded ignore set for system processes whose pasteboard
    /// bumps shouldn't drive a clipping capture. The macOS screenshot UI
    /// puts multi-MB image bytes onto the pasteboard for every Cmd+Shift+4 /
    /// Cmd+Shift+5 capture; reading them on main inside extractCaptureInput
    /// stalls the popover. Kept separate from `excludedBundleIDs` (which
    /// starts empty and is overwritten by Settings save) so the default
    /// can't be lost by user actions.
    private static let systemIgnoredBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
    ]

    // User-configurable capture settings.
    // `allowDuplicates` removed (Q7): dedup is always-on via
    // contentHash lookup in finalizeCapture. Same content merges into
    // the existing row; no user setting needed.
    public var captureImages: Bool = true
    public var captureRichText: Bool = true

    /// Set by the Mac popover view (PopoverView's scenePhase observer) so the
    /// polling loop can stretch its interval when the user isn't actively
    /// looking at the popover. Default false (poll at the relaxed cadence
    /// until the popover signals presence).
    public var popoverIsActive: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    #if canImport(UIKit) && !canImport(AppKit)
    /// Block-observer token from `NotificationCenter.addObserver(forName:…)`.
    /// We keep it so `stop()` can unregister — `removeObserver(self, …)` does
    /// not remove block-based observers.
    private var pasteboardObserverToken: NSObjectProtocol?
    #endif
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
        self.captureImages = UserDefaults.standard.object(forKey: "captureImages") as? Bool ?? true
        self.captureRichText = UserDefaults.standard.object(forKey: "captureRichText") as? Bool ?? true
    }

    /// Canonical cache directory for QuickLook temp files
    /// (`~/Library/Caches/Copied/quicklook/`). Created on first access;
    /// caller is responsible for writing the file. Use the directory for
    /// any short-lived file the user might double-click to open externally
    /// — keeps `/tmp` clean and gives `cleanupQuickLookCache(olderThan:)`
    /// a single dir to prune.
    public static func quickLookCacheDirectory() -> URL {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches
            .appendingPathComponent("Copied", isDirectory: true)
            .appendingPathComponent("quicklook", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Delete QuickLook temp files older than `seconds`. Default 24 h. Run
    /// once at app launch — these files are written when the user opens a
    /// snippet/image in the default viewer and serve no purpose afterwards.
    public static func cleanupQuickLookCache(olderThan seconds: TimeInterval = 86_400) {
        let dir = quickLookCacheDirectory()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in entries {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Fetch one externalStorage blob through an ephemeral `ModelContext` so
    /// the materialized `Data` doesn't pin in the shared `mainContext` row
    /// cache. The context drops at the end of this scope, releasing the
    /// faulted bytes once the caller has copied them out (to the pasteboard,
    /// ThumbnailCache, CKAsset temp file, etc.). Use for `imageData`,
    /// `richTextData`, `htmlData` reads from view code; SwiftUI `@Query`
    /// keeps reading scalars off the shared mainContext as before.
    public static func readBlob(
        in container: ModelContainer,
        clippingID: String,
        key: KeyPath<Clipping, Data?>
    ) -> Data? {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.clippingID == clippingID }
        )
        descriptor.fetchLimit = 1
        return (try? ctx.fetch(descriptor))?.first?[keyPath: key]
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
        let deletedIDs = expired.map(\.clippingID)
        for clipping in expired {
            modelContext.delete(clipping)
        }
        try? modelContext.save()
        for id in deletedIDs {
            CopiedSyncEngine.shared.enqueueDelete(
                recordID: CopiedSyncEngine.clippingRecordID(id)
            )
        }
    }

    /// Hard-delete clippings that have zero usable content — no text,
    /// title, url, image, rich-text, or HTML. These are leftovers from
    /// earlier capture-path bugs (capture ran but failed to populate
    /// any content field) and show up in the popover as "Empty Clipping"
    /// rows. Safe to run unconditionally: the `displayTitle` path
    /// returns "Empty Clipping" only when ALL content predicates are
    /// empty, which is the same predicate used here.
    ///
    /// Enqueues a `.deleteRecord` for each purged row so CloudKit mirrors
    /// the deletion on other devices.
    public func purgeEmptyClippings(in context: ModelContext) {
        // Match `Clipping.displayTitle`'s "Empty Clipping" fallback
        // exactly: displayTitle returns "Empty Clipping" whenever
        // title/text/url are all empty AND hasImage is false. It does
        // NOT inspect hasRichText / hasHTML / sourceURL — so a row
        // with richText data but no title/text/url still shows as
        // "Empty Clipping" and must be purged.
        //
        // Narrow fetch via the scalar `hasImage` index so we don't
        // fault externalStorage blobs on every row.
        // Match Clipping.displayTitle's "Empty Clipping" fallback: no
        // text / title / url / extractedText / sourceURL AND no image /
        // richText / HTML. Narrow the fetch via scalar index then
        // filter remaining content-bearing fields in memory.
        let desc = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { c in
                c.hasImage == false && c.hasRichText == false && c.hasHTML == false
            }
        )
        guard let candidates = try? context.fetch(desc) else { return }
        let empties = candidates.filter { c in
            let textEmpty = (c.text ?? "").isEmpty
            let titleEmpty = (c.title ?? "").isEmpty
            let urlEmpty = (c.url ?? "").isEmpty
            let sourceEmpty = (c.sourceURL ?? "").isEmpty
            let extractedEmpty = (c.extractedText ?? "").isEmpty
            return textEmpty && titleEmpty && urlEmpty && sourceEmpty && extractedEmpty
        }
        guard !empties.isEmpty else { return }
        let deletedIDs = empties.map(\.clippingID)
        for clipping in empties {
            context.delete(clipping)
        }
        try? context.save()
        for id in deletedIDs {
            CopiedSyncEngine.shared.enqueueDelete(
                recordID: CopiedSyncEngine.clippingRecordID(id)
            )
        }
        NSLog("[ClipboardService] purgeEmptyClippings removed \(empties.count) rows")
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
        let deletedIDs = expired.map(\.clippingID)
        for clipping in expired {
            modelContext.delete(clipping)
        }
        try? modelContext.save()
        for id in deletedIDs {
            CopiedSyncEngine.shared.enqueueDelete(
                recordID: CopiedSyncEngine.clippingRecordID(id)
            )
        }
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
                // Tight cadence while the user is in the popover; relaxed
                // when idle. Cuts background CPU/wakeups by 3× when the
                // popover is closed, with a worst-case 1.5 s capture lag
                // until the user opens it.
                let interval = await MainActor.run { self?.popoverIsActive == true } ? 500 : 1500
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.poll() }
            }
        }
        #elseif canImport(UIKit)
        // iOS has no background clipboard polling — the OS suspends apps and
        // throttles pasteboard reads. Strategy: capture on `.changedNotification`
        // whenever we're foregrounded, and on `ScenePhase.active` transition
        // via `checkForPasteboardChanges()`. Seed `lastChangeCount = -1` so the
        // first scene-phase-active check sees a different value and actually
        // captures the current pasteboard (whatever the user copied before
        // launching us).
        lastChangeCount = -1
        isMonitoring = true

        pasteboardObserverToken = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForPasteboardChanges() }
        }
        #endif
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
        #if canImport(UIKit) && !canImport(AppKit)
        if let token = pasteboardObserverToken {
            NotificationCenter.default.removeObserver(token)
            pasteboardObserverToken = nil
        }
        #endif
    }

    #if canImport(UIKit) && !canImport(AppKit)
    /// iOS-only poll. Compares the current `UIPasteboard.changeCount` to the
    /// last seen; captures only on a genuine change. Used by the notification
    /// observer and by the app on `ScenePhase.active` (the OS doesn't fire
    /// `.changedNotification` for a change that happened while we were in the
    /// background).
    @MainActor
    public func checkForPasteboardChanges() {
        let cc = UIPasteboard.general.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        if skipNextCapture {
            skipNextCapture = false
            return
        }
        captureFromUIPasteboard()
    }
    #endif

    // MARK: - Manual Save

    public func saveCurrentClipboard() {
        #if canImport(AppKit)
        captureFromPasteboard(NSPasteboard.general)
        #elseif canImport(UIKit)
        captureFromUIPasteboard()
        #endif
    }

    #if canImport(UIKit) && !canImport(AppKit)
    /// iOS-only: write `items` to `UIPasteboard.general` and record the
    /// resulting `changeCount` so the very next foreground check / observer
    /// fire won't re-capture what we just wrote. Callers should use this
    /// instead of `UIPasteboard.general.setItems(...)` + toggling
    /// `skipNextCapture` — the old flag-based approach leaves the flag armed
    /// if no notification fires (e.g. user copies elsewhere first), causing
    /// the next legitimate capture to be silently dropped.
    @MainActor
    public func writeToPasteboard(_ items: [[String: Any]]) {
        UIPasteboard.general.setItems(items, options: [:])
        lastChangeCount = UIPasteboard.general.changeCount
    }
    #endif

    // MARK: - Canonical insert pipeline

    /// Outcome of `insertOrMerge`.
    public enum InsertOutcome {
        /// Brand-new content committed.
        case inserted
        /// Same content already existed; MRU timestamps bumped instead.
        /// Associated value is the row that absorbed the merge.
        case merged(Clipping)
        /// Clipping had no content signals — refused before touching the store.
        case rejected
    }

    /// Canonical insert pipeline for every SwiftData path in the app —
    /// auto-capture, Share Extension drain, manual Save CTA, merge
    /// script output. Consolidates the empty-shell guard, SHA-256
    /// content fingerprint, hash-based dedup, and `CKSyncEngine`
    /// enqueue that every insert path was re-implementing (and most
    /// were skipping steps, which is why iOS kept producing "Empty
    /// Clipping" ghost rows and why Share Extension entries never made
    /// it to the Mac).
    ///
    /// Callers populate all content fields on `clipping` first
    /// (text/url/imageData/hasRichText/appName/etc.). This helper
    /// handles the four mandatory steps:
    ///   1. Reject clippings with no content signals.
    ///   2. Compute `contentHash`.
    ///   3. If an active row with the same hash exists, bump its MRU
    ///      timestamps, save, and enqueue the existing row's CK change.
    ///      The caller's `clipping` instance is discarded.
    ///   4. Otherwise insert the caller's clipping, save, and enqueue it.
    @MainActor
    @discardableResult
    public static func insertOrMerge(
        _ clipping: Clipping,
        in context: ModelContext
    ) -> InsertOutcome {
        // Empty-shell guard. A row without any content signals is a bug
        // state — the Share Extension once wrote such rows, which
        // surfaced as "Empty Clipping" ghosts on both platforms.
        let didCapture = (clipping.text?.isEmpty == false)
            || (clipping.url?.isEmpty == false)
            || clipping.hasImage
            || clipping.hasRichText
            || clipping.hasHTML
            || (clipping.sourceURL?.isEmpty == false)
            || (clipping.extractedText?.isEmpty == false)
        guard didCapture else { return .rejected }

        // Last line of defense for `deviceName` attribution. Insert
        // paths that bypass this fill (Siri intent, Save sheet, share
        // extension drain) all flow through `insertOrMerge`, so an empty
        // `deviceName` here means the caller didn't set it — pick the
        // local platform default.
        if clipping.deviceName.isEmpty {
            clipping.deviceName = currentDeviceName
        }

        if clipping.modifiedDate == nil {
            clipping.modifiedDate = clipping.addDate
        }

        // SHA-256 fingerprint — same content → same hash on every
        // device, serving both capture-time dedup and cross-device
        // dedup in `CopiedSyncEngine.upsertClipping`.
        clipping.contentHash = clipping.computeContentHash()
        let hash = clipping.contentHash

        // Content-hash dedup — ALWAYS ON (Q7). "Allow duplicates" is a
        // nonsense option for a clipboard history. Copying the same
        // text 100× yields one row that keeps bubbling to the top.
        if !hash.isEmpty {
            let dupeDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> {
                    $0.deleteDate == nil && $0.contentHash == hash
                }
            )
            if let existing = try? context.fetch(dupeDesc).first {
                let now = Date()
                existing.lastUsedDate = now
                existing.copiedDate = now
                existing.addDate = now
                existing.modifiedDate = now
                // Latest copier wins — re-copying on a different device
                // updates the attribution so users see "the device that
                // most recently copied this", not "the device that
                // happened to copy it first weeks ago".
                existing.deviceName = clipping.deviceName
                try? context.save()
                CopiedSyncEngine.shared.enqueueChange(
                    recordID: CopiedSyncEngine.clippingRecordID(existing.clippingID)
                )
                return .merged(existing)
            }
        }

        context.insert(clipping)
        try? context.save()
        // Push to CloudKit via CKSyncEngine. Safe to call even if the
        // engine hasn't started — buffered in pending state and
        // flushed on first `sendChanges`.
        CopiedSyncEngine.shared.enqueueChange(
            recordID: CopiedSyncEngine.clippingRecordID(clipping.clippingID)
        )
        return .inserted
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
            let result = await Self.processCapture(
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
           Self.systemIgnoredBundleIDs.contains(bundleID) || excludedBundleIDs.contains(bundleID) {
            return nil
        }

        let types = (items.first?.types ?? []).map(\.rawValue)
        let text = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        let urlString = pasteboard.string(forType: .URL).flatMap { $0.isEmpty ? nil : $0 }
        let pngData = captureImages && types.contains(NSPasteboard.PasteboardType.png.rawValue)
            ? pasteboard.data(forType: .png)
            : nil
        let tiffData = captureImages && pngData == nil
            ? pasteboard.data(forType: .tiff)
            : nil
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
    private func finalizeCapture(input: CaptureInput, result: CaptureResult) async {
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

        // Categorization already ran off-main in processCapture (Phase B).
        // Just assign the precomputed result onto the Clipping.
        clipping.isCode = result.isCode
        clipping.detectedLanguage = result.detectedLanguage

        clipping.appName = input.appName
        clipping.appBundleID = input.appBundleID
        clipping.deviceName = input.deviceName

        switch Self.insertOrMerge(clipping, in: modelContext) {
        case .rejected:
            return
        case .merged:
            lastCapturedDate = Date()
            return
        case .inserted:
            lastCapturedDate = Date()
            captureCount += 1
        }

        enforceHistoryLimit()
        trimByAge()
        purgeOldTrash()
    }

    // MARK: - Phase B (detached): decode / extract / thumbnail.

    nonisolated private static func processCapture(
        _ input: CaptureInput,
        captureImages: Bool,
        captureRichText: Bool
    ) async -> CaptureResult {
        var result = CaptureResult()

        // Image data from pasteboard blobs first, then file URL disk read.
        if captureImages {
            if let png = input.pngData {
                result.imageData = png
                result.imageFormat = "png"
                result.imageByteCount = png.count
                result.hasImage = true
            } else if let tiff = input.tiffData {
                result.imageData = tiff
                result.imageFormat = "tiff"
                result.imageByteCount = tiff.count
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
        // Gate htmlData on size + structural richness. Most modern apps stuff
        // a plaintext-equivalent HTML wrapper (a few <span>s around text) onto
        // every clipboard write; storing those bytes triggered a per-capture
        // SwiftData externalStorage write + CKAsset upload + iOS download
        // chain. Drop trivial wrappers — the plain `text` field is already
        // captured for them, no fidelity loss.
        if let html = input.htmlData,
           html.count >= 500,
           let htmlString = String(data: html, encoding: .utf8),
           !CodeDetector.htmlIsTrivialWrapper(htmlString) {
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
            if !result.hasImage, let thumb = await Self.generateVideoThumbnail(from: url) {
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

        // Categorize off-main so finalizeCapture (Phase C) doesn't burn
        // 80+ regex compiles on @MainActor per system copy event.
        let cat = Self.categorize(
            text: input.text,
            types: input.types,
            hasHTML: result.hasHTML,
            htmlData: result.htmlData,
            appBundleID: input.appBundleID
        )
        result.isCode = cat.isCode
        result.detectedLanguage = cat.detectedLanguage

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
    /// extraction fails (unreadable file, format not supported, etc.). Uses
    /// the modern async `AVAssetImageGenerator.image(at:)` API (iOS 16 /
    /// macOS 13+); the legacy `copyCGImage(at:actualTime:)` was deprecated
    /// in iOS 18 / macOS 15. Async, but at the 512 px cap the decode is
    /// fast enough (tens of ms) not to affect polling responsiveness.
    nonisolated private static func generateVideoThumbnail(from url: URL) async -> (data: Data, width: Double, height: Double)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)

        if let result = try? await generator.image(at: time) {
            return encodePNG(result.image)
        }

        // Fall back to time zero — some clips are <1s long
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let retry = try? await generator.image(at: .zero) else {
            return nil
        }
        return encodePNG(retry.image)
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
            // `hasImage` drives `Clipping.contentKind` (→ `.image`).
            // `imageByteCount` feeds the content-hash fingerprint used
            // for dedup; `imageFormat` tells the Mac renderer how to
            // decode. All three must be set together.
            clipping.hasImage = true
            clipping.imageByteCount = data.count
            clipping.imageFormat = "png"
            didCapture = true
        }

        // Mirror Mac's HTML / RTF capture so HTML clippings (and the
        // markdown-formatted plain text that ChatGPT/Notion/Bear paste
        // alongside) sync iOS → Mac the same way they already sync
        // Mac → iOS.
        if let htmlData = pasteboard.data(forPasteboardType: "public.html") {
            clipping.htmlData = htmlData
            clipping.hasHTML = true
            didCapture = true
            if clipping.extractedText == nil,
               let extracted = Self.plainTextFromHTMLPublic(htmlData) {
                clipping.extractedText = extracted
            }
        }
        if let rtfData = pasteboard.data(forPasteboardType: "public.rtf")
            ?? pasteboard.data(forPasteboardType: "com.apple.flat-rtfd")
            ?? pasteboard.data(forPasteboardType: "public.rtfd") {
            clipping.richTextData = rtfData
            clipping.hasRichText = true
            didCapture = true
            if clipping.extractedText == nil,
               let extracted = Self.plainTextFromRTFPublic(rtfData) {
                clipping.extractedText = extracted
            }
        }

        // Surface the full UTI list so the detail panel "UTI Types"
        // row works for iOS-origin clippings (was always empty before).
        if let firstItem = pasteboard.items.first {
            clipping.types = Array(firstItem.keys)
        }

        clipping.deviceName = UIDevice.current.name

        guard didCapture else { return }

        // Evaluate user-defined automation rules BEFORE the insert. A rule
        // can veto the save entirely (.skip), flag the clipping as favorite,
        // or route it to a custom ClipList — each stacks on top of the
        // prior defaults. See `RuleEngine.evaluate` for ordering semantics.
        let outcome = RuleEngine.evaluate(
            text: clipping.text,
            url: clipping.url,
            imageData: clipping.imageData
        )
        guard outcome.shouldSave else { return }
        if outcome.markFavorite { clipping.isFavorite = true }
        if let listID = outcome.routeToListID {
            var descriptor = FetchDescriptor<ClipList>(
                predicate: #Predicate<ClipList> { $0.listID == listID }
            )
            descriptor.fetchLimit = 1
            if let list = try? modelContext.fetch(descriptor).first {
                clipping.list = list
            }
        }

        // Categorize using the same priority chain as the Mac path: UTI
        // source-code → markdown → rich HTML → plain-text heuristic.
        Self.applyCategorization(to: clipping)

        switch Self.insertOrMerge(clipping, in: modelContext) {
        case .rejected:
            return
        case .merged:
            lastCapturedDate = Date()
        case .inserted:
            lastCapturedDate = Date()
            captureCount += 1
        }
    }
    #endif

    // MARK: - Reclassify Existing Clippings

    // Bump V6→V7 so existing rows mis-tagged by the over-aggressive 1.3.x
    // anchor regexes (e.g. prose tagged as Zig/SQL/Python) re-run through
    // the tightened categorizer (strong/weak split + NLTagger prose
    // disqualifier). Reclassify uses an ephemeral ModelContext so the
    // migration's working set drops cleanly when it returns.
    private static let reclassifyKey = "didReclassifyClippingsV7"

    /// One-time migration: re-runs URL and categorization on existing
    /// clippings. V3 introduces UTI-based source-code detection, markdown
    /// detection, and HTML triviality demotion — so old `.html` rows
    /// whose body is actually markdown re-tag as `.markdown`, source
    /// code that escaped heuristic detection picks up its language.
    private func reclassifyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.reclassifyKey) else { return }
        guard let modelContext else { return }

        // Use an EPHEMERAL ModelContext for the migration. Previously this
        // ran on the shared env modelContext, which left up to 5000
        // materialized Clipping objects + their @Observable registrar state
        // (~25 KB each = ~125 MB) registered in the app-lifetime context
        // forever. With an ephemeral context, the materialized objects
        // drop out of scope when the function returns and ARC releases
        // them (and their Observation tracking entries). Saved mutations
        // still propagate to SQLite + CloudKit identically.
        let migrationCtx = ModelContext(modelContext.container)

        var descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.deleteDate == nil }
        )
        descriptor.fetchLimit = 5000

        guard let clippings = try? migrationCtx.fetch(descriptor) else { return }

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

            // Re-run the new categorization chain. applyCategorization now
            // returns true only when it actually mutated a property, so
            // unchanged records don't dirty the SQLite write or the
            // CKSyncEngine upload queue.
            if Self.applyCategorization(to: clipping) {
                changed = true
            }
        }

        if changed {
            try? migrationCtx.save()
        }
        UserDefaults.standard.set(true, forKey: Self.reclassifyKey)
    }

    // MARK: - Cross-platform helpers

    /// Best-effort name of the device that's currently running the app —
    /// stored on every locally-captured `Clipping` so other devices know
    /// where the content originated. iOS returns the user-set device name
    /// (e.g. "Matthew's iPhone") only if the app holds the
    /// `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement; otherwise it returns the model class ("iPhone").
    public static var currentDeviceName: String {
        #if canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Unknown"
        #endif
    }

    /// Cross-platform plain-text extraction from `text/html` data.
    /// Mirrors the Mac-only `plainTextFromHTML` helper used in Phase B
    /// so the iOS pasteboard path can populate `extractedText` for
    /// search indexing.
    nonisolated static func plainTextFromHTMLPublic(_ data: Data) -> String? {
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

    /// Cross-platform plain-text extraction from RTF/RTFD data.
    nonisolated static func plainTextFromRTFPublic(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(data: data, documentAttributes: nil) else {
            return nil
        }
        let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(5000))
    }

    /// Pure categorization: same priority chain as `applyCategorization` but
    /// parameterized so it can run off `@MainActor` from `processCapture`
    /// (Phase B). Avoids burning 80+ regex compiles on the main thread per
    /// system copy event — that was the "app unusable after copy" symptom.
    nonisolated static func categorize(
        text: String?,
        types: [String],
        hasHTML: Bool,
        htmlData: Data?,
        appBundleID: String?
    ) -> (isCode: Bool, detectedLanguage: String?) {
        // 1. Pasteboard UTI says it's source code — strongest signal.
        if let lang = CodeDetector.languageFromUTIs(types) {
            return (true, lang)
        }
        // 2. Structured config formats (YAML / JSON / TOML / Dockerfile /
        // Makefile). Distinctive whole-document structural shape — runs
        // BEFORE language anchors so a YAML with embedded shell blocks
        // doesn't get tagged as shell on keyword heuristic fallback.
        if let text, let lang = CodeDetector.configLanguage(in: text) {
            return (true, lang)
        }
        // 3. Markdown — heading + bullets + bold + code spans. Whole-
        // document structural signal. MUST run BEFORE the language anchors
        // so a markdown doc that mentions `function name()` doesn't get
        // tagged as Lua on the function anchor. Markdown's score-based
        // detector (≥ 3) only fires on real markdown shape.
        if let text, CodeDetector.looksLikeMarkdown(text) {
            return (true, "markdown")
        }
        // 4. Per-language anchor regex (strong patterns + weak with ≥ 2 hits).
        if let text, let lang = CodeDetector.anchorLanguage(in: text) {
            return (true, lang)
        }
        // 5. NLTagger prose disqualifier — by here we know it's not code
        // (no UTI / no config / no markdown / no anchor). If it's
        // overwhelmingly natural English (≥ 70% of words are nouns /
        // verbs / etc.), it's plain text — don't fall through to the
        // weaker heuristics that mis-fire on prose mentioning code.
        if let text, CodeDetector.looksLikeProseNL(text) {
            return (false, nil)
        }
        // 4. Real, structurally-rich HTML.
        if hasHTML,
           let data = htmlData,
           let html = String(data: data, encoding: .utf8),
           !CodeDetector.htmlIsTrivialWrapper(html) {
            return (true, "html")
        }
        // 5. Source app is a known code editor.
        if let bundleID = appBundleID,
           CodeDetector.codeEditorBundleIDs.contains(bundleID) {
            let lang = CodeDetector.defaultLanguageForIDE(bundleID)
                ?? text.flatMap { CodeDetector.detect(in: $0).language }
            return (true, lang)
        }
        // 6. Keyword-heuristic plain-text fallback.
        if let text {
            let d = CodeDetector.detect(in: text)
            return (d.isCode, d.isCode ? d.language : nil)
        }
        return (false, nil)
    }

    /// Main-actor wrapper kept for `reclassifyIfNeeded` migration callers
    /// that have a Clipping in hand. Runs the same categorization synchronously.
    /// New captures should NOT use this — they get categorization from
    /// `processCapture` (Phase B) for free.
    /// Returns true if the categorization actually changed any property on
    /// the clipping. Callers can use this to avoid saving a clean record
    /// (which would otherwise dirty it for the next CKSyncEngine push).
    @MainActor
    @discardableResult
    static func applyCategorization(to clipping: Clipping) -> Bool {
        let result = categorize(
            text: clipping.text,
            types: clipping.types,
            hasHTML: clipping.hasHTML,
            htmlData: clipping.htmlData,
            appBundleID: clipping.appBundleID
        )
        var changed = false
        // Only assign when the value actually differs — otherwise SwiftData
        // marks the property as dirty even on no-op assignments and the
        // record gets re-uploaded. This was tipping the V6 migration into
        // a 5000-record CKSyncEngine flood.
        if clipping.isCode != result.isCode {
            clipping.isCode = result.isCode
            changed = true
        }
        if clipping.detectedLanguage != result.detectedLanguage {
            clipping.detectedLanguage = result.detectedLanguage
            changed = true
        }
        return changed
    }

    // MARK: - Dedup & Limits

    // Q7: `isDuplicateOfLast` window check and `removeDuplicates(in:)`
    // cleanup static removed. Dedup is enforced at `insertOrMerge`
    // time via `contentHash`, so duplicates can never reach storage
    // and there is nothing for a manual cleanup pass to collect.

    // MARK: - List Creation

    /// Trim, validate, insert, save, and enqueue a new `ClipList`. Single source
    /// of truth shared by the main-window sidebar (COP-98) and the popover's
    /// "+ New List…" affordance (COP-98) — and consumed by COP-99's per-row
    /// list-picker so a user can create-and-assign in one gesture.
    ///
    /// Returns the inserted list on success, `nil` if the trimmed name is empty.
    /// `sortOrder` is set to the current ClipList count so the new entry sorts
    /// to the end of the sidebar — matching the pre-extraction behaviour.
    @MainActor
    public static func createList(named rawName: String, in context: ModelContext) -> ClipList? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let existingCount = (try? context.fetchCount(FetchDescriptor<ClipList>())) ?? 0
        let list = ClipList(name: name)
        list.sortOrder = existingCount
        context.insert(list)
        try? context.save()
        // The previous in-view createList() did not enqueue a CloudKit
        // upload, so user-created lists only synced when an unrelated
        // mutation flushed the engine. Push the saveRecord directly.
        CopiedSyncEngine.shared.enqueueChange(
            recordID: CopiedSyncEngine.clipListRecordID(list.listID)
        )
        return list
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
            // COP-107: capture IDs BEFORE delete so we can enqueue the CK
            // delete-record events. Custom CKSyncEngine doesn't auto-mirror
            // SwiftData deletes — every other hard-delete site in this file
            // (trimByAge, purgeEmptyClippings, purgeOldTrash) calls
            // enqueueDelete; the trim path was the lone outlier, so the cap
            // didn't actually hold: next CK fetch re-imported the rows.
            let deletedIDs = toDelete.map(\.clippingID)
            for clipping in toDelete {
                modelContext.delete(clipping)
            }
            try? modelContext.save()
            for id in deletedIDs {
                CopiedSyncEngine.shared.enqueueDelete(
                    recordID: CopiedSyncEngine.clippingRecordID(id)
                )
            }
        }
    }
}
