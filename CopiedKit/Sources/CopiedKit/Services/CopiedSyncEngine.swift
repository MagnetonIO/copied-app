import Foundation
import CloudKit
import SwiftData
import Observation

/// Sync engine wrapper around Apple's `CKSyncEngine` (iOS 17 / macOS 14+).
///
/// Replaces `NSPersistentCloudKitContainer`'s `.cloudKitDatabase: .private(...)`
/// automatic mirroring. Why: NSPCKC exposes no public API to force a
/// pull, silent push on dev-signed Mac binaries is unreliable (Apple
/// forum FB8968738 — dev-APS courier doesn't connect), and the mirror's
/// internal schedule is opaque. `CKSyncEngine` gives us first-class
/// `fetchChanges()` / `sendChanges()` APIs and observable delegate
/// events, which the "Sync Now" button and status label both need.
///
/// Lifecycle:
/// 1. AppDelegate calls `start(modelContainer:)` once `SharedData.container`
///    is ready and `cloudSyncEnabled` is on.
/// 2. Engine restores persisted state (or creates zone on first run) and
///    kicks off its own automatic fetch/send loop.
/// 3. Mutation sites (ClipboardService.finalizeCapture, Clipping.persist,
///    ClipList.deleteTrashingClippings, etc.) call `enqueueChange(recordID:)`
///    or `enqueueDelete(recordID:)` — Phase 3 wires these.
/// 4. Inbound records from the server arrive via `handleEvent(.fetchedRecordZoneChanges)`
///    → upserted into SwiftData with last-write-wins by `modifiedDate`
///    — Phase 4 fills this in.
public final class CopiedSyncEngine: CKSyncEngineDelegate, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = CopiedSyncEngine(
        containerIdentifier: CopiedSchema.containerIdentifier
    )

    // MARK: - Zone + record-type constants

    /// Single custom zone used for all Copied records. Distinct from the
    /// `com.apple.coredata.cloudkit.zone` that NSPCKC auto-creates — on
    /// clean-start migration (Phase 6), old `CD_*` records in the NSPCKC
    /// zone become orphaned. `CKSyncEngine` has no knowledge of that
    /// legacy zone.
    public static let zoneID = CKRecordZone.ID(
        zoneName: "copied",
        ownerName: CKCurrentUserDefaultName
    )

    public enum RecordType {
        public static let clipping = "Clipping"
        public static let clipList = "ClipList"
        public static let asset = "Asset"
    }

    // MARK: - Stored state

    private let containerIdentifier: String
    private let container: CKContainer
    private var engine: CKSyncEngine?
    private weak var modelContainer: ModelContainer?

    /// Serialized alongside `CKSyncEngine.State.Serialization` so both
    /// survive relaunches. Also carries migration flags (Phase 6).
    private struct Persisted: Codable {
        var stateSerialization: CKSyncEngine.State.Serialization?
        /// Set after a successful one-time upload of pre-existing local
        /// SwiftData rows on first launch post-CKSyncEngine migration.
        /// Guarantees we don't re-seed on every launch.
        var didSeedUpload: Bool = false
    }

    private var persisted: Persisted
    private let stateFileURL: URL
    private let stateQueue = DispatchQueue(label: "com.mlong.copied.syncengine.state")

    // MARK: - Init

    private init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.container = CKContainer(identifier: containerIdentifier)

        // Sandboxed app support dir — persists across launches, isolated
        // per user + per app. Read-only fallback if disk is wedged: fresh
        // state, engine will do a full refetch on first sync.
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CopiedSync", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateFileURL = dir.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: self.stateFileURL),
           let state = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.persisted = state
        } else {
            self.persisted = Persisted()
        }
    }

    /// Call once from AppDelegate after the SwiftData container exists
    /// and the user's cloudSync gate is enabled. Idempotent — a second
    /// call with the same container is a no-op.
    @MainActor
    public func start(modelContainer: ModelContainer) {
        if engine != nil { return }
        self.modelContainer = modelContainer

        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: persisted.stateSerialization,
            delegate: self
        )
        config.automaticallySync = true
        let created = CKSyncEngine(config)
        self.engine = created

        // Enqueue zone creation on very first launch (state serialization
        // is nil → never synced before). CKSyncEngine dedupes zone saves,
        // so a second enqueue on subsequent launches is harmless.
        if persisted.stateSerialization == nil {
            created.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: Self.zoneID))
            ])
        }
    }

    // MARK: - Public API — wired to Sync Now, Resume Monitoring, etc. in Phase 5

    /// Manual sync — fetch first (pull inbound), then send (push outbound).
    /// Matches the user's "Sync Now" semantics: one button, both directions.
    public func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            NSLog("[CopiedSyncEngine] syncNow failed: \(error.localizedDescription)")
        }
    }

    public func fetchChanges() async {
        try? await engine?.fetchChanges()
    }

    public func sendChanges() async {
        try? await engine?.sendChanges()
    }

    /// Called by every Clipping / ClipList / Asset mutation site (Phase 3
    /// wires these). Safe to call before the engine has started — changes
    /// buffer up and flush on first `sendChanges`.
    public func enqueueChange(recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    public func enqueueDelete(recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    // MARK: - Record-ID builders

    public static func clippingRecordID(_ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    public static func clipListRecordID(_ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    public static func assetRecordID(_ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let e):
            // Persist engine state on every update so restarts resume
            // from the latest server-change token instead of full refetch.
            persisted.stateSerialization = e.stateSerialization
            persist()

        case .accountChange(let e):
            await handleAccountChange(e)

        case .fetchedDatabaseChanges(let e):
            // Zone create/delete events. We only care about our `copied`
            // zone; Phase 4 fills in zone-deletion handling (user signed
            // out + back in → need to reseed).
            _ = e

        case .fetchedRecordZoneChanges(let e):
            await handleFetchedRecordZoneChanges(e)

        case .sentRecordZoneChanges(let e):
            await handleSentRecordZoneChanges(e)

        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            // Lifecycle events — Phase 5 hooks these to drive UI status.
            break

        @unknown default:
            NSLog("[CopiedSyncEngine] unknown event: \(event)")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // Phase 3 fills in the record-provider closure to look up
        // Clipping/ClipList/Asset by record name and populate a CKRecord
        // via CKRecordMapper. Phase 2 drops every pending save so any
        // accidentally-enqueued change doesn't block the queue forever.
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes
        ) { recordID in
            // TODO(Phase 3): materialize CKRecord from SwiftData via CKRecordMapper
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    // MARK: - Event handlers — filled in across Phase 4 / Phase 6

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        // Phase 4: on .switchedAccount / .signOut — reset local engine
        // state (keep SwiftData), reseed on next sign-in.
        // Phase 6 seed-upload also re-runs from a zeroed state.
        _ = event
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        // Phase 4: for each modification → upsert into SwiftData
        // (match by clippingID / listID / assetID; LWW on modifiedDate).
        // For each deletion → hard-delete locally.
        _ = event
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        // Phase 4: handle per-record failures (zoneNotFound → reseed,
        // serverRecordChanged → conflict resolve, unknownItem → drop).
        _ = event
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = persisted
        stateQueue.async { [stateFileURL] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: stateFileURL, options: .atomic)
            } catch {
                NSLog("[CopiedSyncEngine] persist failed: \(error.localizedDescription)")
            }
        }
    }
}
