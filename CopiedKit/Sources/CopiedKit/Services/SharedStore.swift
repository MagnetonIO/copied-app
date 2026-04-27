import Foundation

/// Inbox queue shared between the host iOS app and the Share Extension via
/// the `group.com.magneton.copied` App Group container.
///
/// We deliberately do **not** share the SwiftData store directly: the main
/// store is backed by CloudKit (NSPersistentCloudKitContainer), which expects
/// to own its store URL and can't be pointed at an App Group path without
/// losing sync. So the extension writes a tiny JSON file per capture into an
/// inbox directory, and the host drains the inbox into its SwiftData store
/// on `ScenePhase.active`.
public enum SharedStore {
    public static let appGroupIdentifier = "group.com.magneton.copied"

    /// One pending capture from an extension. Shape is intentionally loose —
    /// text / url / imageData / title are all optional, matching the
    /// possible combinations a share-sheet input can deliver.
    public struct PendingClipping: Codable, Sendable {
        public let id: String
        public let createdAt: Date
        public let text: String?
        public let url: String?
        public let title: String?
        public let imageData: Data?
        /// Hint for the host so it can route a Copied Browser share into the
        /// in-app browser instead of the default "save to history" path.
        public let source: Source

        public enum Source: String, Codable, Sendable {
            case share       // "Save to Copied"
            case browser     // "Copied Browser"
            case clipper     // "Copied Clipper"
        }

        public init(
            id: String = UUID().uuidString,
            createdAt: Date = Date(),
            text: String? = nil,
            url: String? = nil,
            title: String? = nil,
            imageData: Data? = nil,
            source: Source
        ) {
            self.id = id
            self.createdAt = createdAt
            self.text = text
            self.url = url
            self.title = title
            self.imageData = imageData
            self.source = source
        }
    }

    // MARK: - Paths

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var inboxURL: URL? {
        containerURL?.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private static func ensureInbox() -> URL? {
        guard let url = inboxURL else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Write (extension side)

    /// Append one pending capture. Atomic write with a random filename so
    /// concurrent extension invocations never collide.
    public static func enqueue(_ pending: PendingClipping) throws {
        guard let dir = ensureInbox() else {
            throw NSError(
                domain: "SharedStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"]
            )
        }
        let data = try JSONEncoder().encode(pending)
        let file = dir.appendingPathComponent("\(pending.id).json")
        try data.write(to: file, options: .atomic)
    }

    // MARK: - Drain (host side)

    /// One entry returned by `readInbox()` — pairs the decoded payload with
    /// the file URL so the caller can `acknowledge(_:)` it only after a
    /// successful SwiftData write. Malformed files are auto-quarantined
    /// during read.
    public struct InboxEntry: Sendable {
        public let pending: PendingClipping
        public let fileURL: URL
    }

    /// Returns all pending captures in chronological order **without**
    /// deleting them. The caller must call `acknowledge(_:)` after a
    /// successful persist so we don't lose shares on a crash between read
    /// and write.
    public static func readInbox() -> [InboxEntry] {
        guard let dir = inboxURL,
              FileManager.default.fileExists(atPath: dir.path) else {
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        let quarantine = dir.appendingPathComponent("Quarantine", isDirectory: true)
        var results: [InboxEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? decoder.decode(PendingClipping.self, from: data) else {
                // Malformed entry — move aside so we neither loop on it nor
                // silently lose it (useful for post-mortem).
                try? FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let dest = quarantine.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.moveItem(at: file, to: dest)
                continue
            }
            results.append(InboxEntry(pending: pending, fileURL: file))
        }
        return results.sorted { $0.pending.createdAt < $1.pending.createdAt }
    }

    /// Remove one inbox entry. Call this **after** the caller has durably
    /// persisted the pending clipping (e.g. `modelContext.save()` succeeded).
    public static func acknowledge(_ entry: InboxEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
    }

    /// Legacy one-shot drain. Kept for callers that don't care about
    /// acknowledge semantics; uses the safe read+ack path.
    @discardableResult
    public static func drainInbox() -> [PendingClipping] {
        let entries = readInbox()
        for entry in entries { acknowledge(entry) }
        return entries.map(\.pending)
    }

    // MARK: - Shared defaults

    /// App Group-scoped UserDefaults. Extensions cannot read `UserDefaults.standard`
    /// of the host; anything the extension needs to observe (e.g. the host's
    /// `iCloudSyncPurchased` flag) must live here.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` isn't `Sendable` but is
    /// documented thread-safe for the read/write calls we use (set/get of
    /// property-list types), so no external synchronization is required.
    public nonisolated(unsafe) static let defaults: UserDefaults = {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }()
}
