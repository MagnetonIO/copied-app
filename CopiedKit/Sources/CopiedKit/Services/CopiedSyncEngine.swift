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
    ///
    /// Capitalized "Copied" matches the app brand. If a previous build
    /// used a different zone name (e.g. early "copied" lowercase), the
    /// state-nuking check in `start()` detects the mismatch and forces
    /// a clean seed into the new zone.
    public static let zoneID = CKRecordZone.ID(
        zoneName: "Copied",
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

    /// App's existing observable status façade. Set by AppDelegate after
    /// both the engine and monitor are constructed. Engine events
    /// (`handleEvent`) update the monitor's status via main-actor hops
    /// so SwiftUI views keep binding to `SyncMonitor` unchanged.
    @MainActor
    public weak var syncMonitor: SyncMonitor?

    /// Serialized alongside `CKSyncEngine.State.Serialization` so both
    /// survive relaunches. Also carries migration flags (Phase 6) and
    /// the zone name the state was captured under — so we can detect
    /// a zone rename (e.g. "copied" → "Copied") and force a clean
    /// re-seed rather than carry stale change tokens into a zone that
    /// no longer exists.
    private struct Persisted: Codable {
        var stateSerialization: CKSyncEngine.State.Serialization?
        /// Set after a successful one-time upload of pre-existing local
        /// SwiftData rows on first launch post-CKSyncEngine migration.
        /// Guarantees we don't re-seed on every launch.
        var didSeedUpload: Bool = false
        /// The CKRecordZone name the serialization above was captured
        /// under. Used by `start()` to detect zone-rename migrations.
        var lastZoneName: String?
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

        // Zone-rename detection: if the persisted state was captured
        // under a different zone name (or no zone name at all — pre-
        // upgrade state files), clear the serialization and re-seed.
        // Stale change tokens from a different zone are worthless and
        // can confuse the engine's reconciliation.
        if persisted.lastZoneName != Self.zoneID.zoneName {
            NSLog("[CopiedSyncEngine] zone changed: '\(persisted.lastZoneName ?? "nil")' → '\(Self.zoneID.zoneName)'. Clearing state + forcing re-seed.")
            persisted.stateSerialization = nil
            persisted.didSeedUpload = false
            persisted.lastZoneName = Self.zoneID.zoneName
            persist()
        }

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

        // Phase 6 — clean-start seed migration. On the first launch that
        // boots CKSyncEngine (either brand-new install or upgrade from
        // pre-migration Copied), enumerate all local Clipping / ClipList
        // rows and enqueue each as a pending save. CKSyncEngine will
        // upload them under the new custom record types on its next
        // `sendChanges`. Legacy NSPCKC-mirrored `CD_*` records in the old
        // zone are left alone — they become orphaned cloud garbage and
        // can be cleaned up via CloudKit Dashboard by the user.
        if !persisted.didSeedUpload {
            seedLocalData(container: modelContainer)
            persisted.didSeedUpload = true
            persist()
        }
    }

    /// One-shot enumeration of local rows → pending CKRecord saves.
    /// Idempotent because it only runs when `didSeedUpload == false`,
    /// which is flipped to true as soon as the enqueue finishes.
    /// The engine itself will coalesce + retry on its normal schedule
    /// after the enqueue returns.
    @MainActor
    private func seedLocalData(container: ModelContainer) {
        let ctx = ModelContext(container)

        let clippingDesc = FetchDescriptor<Clipping>()
        if let clippings = try? ctx.fetch(clippingDesc) {
            var enqueued = 0
            var skipped = 0
            for clipping in clippings {
                // Skip empty-shell clippings (same definition as
                // `ClipboardService.purgeEmptyClippings` + `Clipping.displayTitle`
                // fallback): no title / text / url and no image. Uploading
                // these would just pollute CloudKit with garbage that every
                // other device would pull down as "Empty Clipping" rows
                // before their own purge has a chance to run.
                let textEmpty = (clipping.text ?? "").isEmpty
                let titleEmpty = (clipping.title ?? "").isEmpty
                let urlEmpty = (clipping.url ?? "").isEmpty
                if textEmpty && titleEmpty && urlEmpty && !clipping.hasImage {
                    skipped += 1
                    continue
                }
                engine?.state.add(pendingRecordZoneChanges: [
                    .saveRecord(Self.clippingRecordID(clipping.clippingID))
                ])
                enqueued += 1
            }
            NSLog("[CopiedSyncEngine] seeded \(enqueued) clippings for upload (skipped \(skipped) empty shells)")
        }

        let listDesc = FetchDescriptor<ClipList>()
        if let lists = try? ctx.fetch(listDesc) {
            for list in lists {
                engine?.state.add(pendingRecordZoneChanges: [
                    .saveRecord(Self.clipListRecordID(list.listID))
                ])
            }
            NSLog("[CopiedSyncEngine] seeded \(lists.count) lists for upload")
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

        case .willFetchChanges:
            await updateStatus(SyncMonitor.SyncStatus.syncing(direction: "Checking…"))

        case .willSendChanges:
            await updateStatus(SyncMonitor.SyncStatus.syncing(direction: "Uploading…"))

        case .didFetchChanges:
            // If we didn't flip to `.synced(...)` from the modifications
            // path, fall back to `.available` so the label doesn't lie
            // with a stale "Synced Xm ago".
            await updateStatusIfSyncing(SyncMonitor.SyncStatus.available)

        case .didSendChanges:
            await updateStatusIfSyncing(SyncMonitor.SyncStatus.available)

        case .sentDatabaseChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges:
            break

        @unknown default:
            NSLog("[CopiedSyncEngine] unknown event: \(event)")
        }
    }

    @MainActor
    private func updateStatus(_ new: SyncMonitor.SyncStatus) {
        syncMonitor?.applyExternalStatus(new)
    }

    @MainActor
    private func updateStatusIfSyncing(_ new: SyncMonitor.SyncStatus) {
        if case .syncing = syncMonitor?.status {
            syncMonitor?.applyExternalStatus(new)
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // Snapshot the container reference on-actor — the closure below
        // runs on the engine's executor.
        let container = self.modelContainer

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes
        ) { recordID in
            guard let container else {
                // Engine fired before start() completed — drop the
                // change; it'll be re-enqueued on next mutation.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }

            // Serialize access through a fresh ModelContext on a
            // background actor; the engine closure is nonisolated so we
            // can't touch main-actor state directly. Each record gets a
            // dedicated fetch+populate pass.
            return Self.makeRecord(
                for: recordID,
                container: container,
                syncEngine: syncEngine
            )
        }
    }

    /// Look up the local SwiftData row matching `recordID.recordName` and
    /// return a populated CKRecord. Returns nil (and removes the pending
    /// change) if the row has been deleted locally — CKSyncEngine will
    /// translate that into a no-op rather than a delete (we use explicit
    /// `.deleteRecord` enqueues for hard deletes).
    private static func makeRecord(
        for recordID: CKRecord.ID,
        container: ModelContainer,
        syncEngine: CKSyncEngine
    ) -> CKRecord? {
        let recordName = recordID.recordName
        let ctx = ModelContext(container)

        // Try Clipping first (most common).
        let clippingDesc = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.clippingID == recordName }
        )
        if let clipping = try? ctx.fetch(clippingDesc).first {
            let record = CKRecord(recordType: RecordType.clipping, recordID: recordID)
            CKRecordMapper.populate(record, from: clipping)
            return record
        }

        // Then ClipList.
        let listDesc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == recordName }
        )
        if let list = try? ctx.fetch(listDesc).first {
            let record = CKRecord(recordType: RecordType.clipList, recordID: recordID)
            CKRecordMapper.populate(record, from: list)
            return record
        }

        // Not found → local row was hard-deleted after the enqueue.
        // Drop the pending save; an explicit .deleteRecord was (or
        // should have been) enqueued separately.
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    // MARK: - Event handlers

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        // IMPORTANT: do NOT call `engine.fetchChanges()` / `sendChanges()`
        // from within this delegate callback — CKSyncEngine asserts
        // (EXC_BREAKPOINT) if you re-enter it synchronously from its own
        // event-dispatch path. Use `engine.state.add(pendingDatabaseChanges:)`
        // or defer outbound work off this stack via `Task.detached`.
        //
        // For now, just flip the persisted migration flags so the *next*
        // cold launch picks up the right seed state. The engine itself
        // will fetch on its automatic schedule after sign-in.
        switch event.changeType {
        case .signIn:
            persisted.didSeedUpload = false
            persist()
        case .switchAccounts, .signOut:
            persisted.stateSerialization = nil
            persisted.didSeedUpload = false
            persist()
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        guard let modelContainer else { return }

        // Hop onto main actor to mutate SwiftData — ModelContext ops
        // on @Model types require main-actor or per-context isolation.
        // We use a dedicated context created on main so we don't
        // collide with @Query observers on the shared mainContext.
        await MainActor.run {
            let ctx = ModelContext(modelContainer)

            // Modifications — upsert Clipping / ClipList by recordID,
            // LWW on `modifiedDate`.
            for modification in event.modifications {
                let record = modification.record
                let recordName = record.recordID.recordName

                switch record.recordType {
                case RecordType.clipping:
                    upsertClipping(record: record, recordName: recordName, ctx: ctx)
                case RecordType.clipList:
                    upsertClipList(record: record, recordName: recordName, ctx: ctx)
                default:
                    NSLog("[CopiedSyncEngine] unknown recordType: \(record.recordType)")
                }
            }

            // Deletions — hard-delete matching local rows.
            for deletion in event.deletions {
                let recordName = deletion.recordID.recordName
                switch deletion.recordType {
                case RecordType.clipping:
                    let desc = FetchDescriptor<Clipping>(
                        predicate: #Predicate<Clipping> { $0.clippingID == recordName }
                    )
                    if let existing = try? ctx.fetch(desc).first {
                        ctx.delete(existing)
                    }
                case RecordType.clipList:
                    let desc = FetchDescriptor<ClipList>(
                        predicate: #Predicate<ClipList> { $0.listID == recordName }
                    )
                    if let existing = try? ctx.fetch(desc).first {
                        ctx.delete(existing)
                    }
                default:
                    break
                }
            }

            try? ctx.save()

            // Real import landed → honest status.
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                syncMonitor?.applyExternalStatus(SyncMonitor.SyncStatus.synced(Date()))
            }
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        // Clean up outbound blob temp files on successful saves. Failed
        // saves stay on disk so the next retry can re-read them.
        for savedRecord in event.savedRecords {
            cleanupOutboundBlobs(recordName: savedRecord.recordID.recordName)
        }

        // Per-record failure handling. Phase 4 covers the common cases
        // (zoneNotFound → re-enqueue zone create + record save;
        // serverRecordChanged → LWW re-save; unknownItem → drop).
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Conflict: server has a newer/different version.
                // Accept server copy via fetch; drop our pending save.
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .zoneNotFound, .userDeletedZone:
                // Our zone was deleted (user signed out + back in?).
                // Re-enqueue zone create + re-try this record save.
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: Self.zoneID))
                ])
            case .unknownItem:
                // Record was deleted server-side; drop our save.
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                NSLog("[CopiedSyncEngine] unhandled save failure: \(failure.error)")
            }
        }
    }

    // MARK: - Upsert helpers (main-actor bound; called inside MainActor.run)

    @MainActor
    private func upsertClipping(record: CKRecord, recordName: String, ctx: ModelContext) {
        // Defense in depth: refuse to create a local row from an empty
        // CKRecord. If a peer device somehow uploads a shell (pre-purge
        // seed, half-captured mutation, etc.) we drop it on receive so
        // it can't repopulate a list we just cleaned. Also enqueue a
        // .deleteRecord so CloudKit drops the garbage on its next sync.
        // An existing local row with real content is still updated — the
        // shell-check only applies to records we'd be inserting fresh.
        let text = (record["text"] as? String) ?? ""
        let title = (record["title"] as? String) ?? ""
        let url = (record["url"] as? String) ?? ""
        let hasImage = (record["hasImage"] as? Bool) ?? false
        let isShell = text.isEmpty && title.isEmpty && url.isEmpty && !hasImage

        let desc = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.clippingID == recordName }
        )
        let existing = try? ctx.fetch(desc).first

        if isShell, existing == nil {
            // Don't insert garbage; tell CloudKit to forget this record.
            engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(record.recordID)])
            return
        }

        // Cross-device content dedup: if this is a new-to-us record and
        // a local active clipping already has the same text + url +
        // image byte count, don't create a duplicate row. Also enqueue
        // a delete so CloudKit drops the incoming record on the next
        // send. Prevents Mac + iOS both capturing the same Handoff
        // paste from producing two rows on every device.
        if existing == nil, !isShell {
            let incomingText = (record["text"] as? String) ?? ""
            let incomingURL = (record["url"] as? String) ?? ""
            let incomingBytes = (record["imageByteCount"] as? Int) ?? 0
            let activeDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> { $0.deleteDate == nil }
            )
            if let active = try? ctx.fetch(activeDesc) {
                let isDuplicate = active.contains { c in
                    (c.text ?? "") == incomingText &&
                    (c.url ?? "") == incomingURL &&
                    c.imageByteCount == incomingBytes
                }
                if isDuplicate {
                    engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(record.recordID)])
                    return
                }
            }
        }

        let incomingModified = record["modifiedDate"] as? Date

        if let existing {
            // LWW — remote wins if strictly newer. Equal timestamps:
            // remote wins (consistent cross-device convergence).
            if let localModified = existing.modifiedDate,
               let incomingModified,
               localModified > incomingModified {
                return  // local is newer; drop this remote update
            }
            CKRecordMapper.apply(record, to: existing)
            if let listID = CKRecordMapper.listID(from: record) {
                existing.list = fetchClipList(listID: listID, ctx: ctx)
            } else {
                existing.list = nil
            }
        } else {
            let clipping = Clipping()
            clipping.clippingID = recordName
            ctx.insert(clipping)
            CKRecordMapper.apply(record, to: clipping)
            if let listID = CKRecordMapper.listID(from: record) {
                clipping.list = fetchClipList(listID: listID, ctx: ctx)
            }
        }
    }

    @MainActor
    private func upsertClipList(record: CKRecord, recordName: String, ctx: ModelContext) {
        let desc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == recordName }
        )
        let existing = try? ctx.fetch(desc).first
        let incomingModified = record["modifiedDate"] as? Date

        if let existing {
            if let localModified = existing.modifiedDate,
               let incomingModified,
               localModified > incomingModified {
                return
            }
            CKRecordMapper.apply(record, to: existing)
        } else {
            let list = ClipList(name: "")
            list.listID = recordName
            ctx.insert(list)
            CKRecordMapper.apply(record, to: list)
        }
    }

    @MainActor
    private func fetchClipList(listID: String, ctx: ModelContext) -> ClipList? {
        let desc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == listID }
        )
        return try? ctx.fetch(desc).first
    }

    // MARK: - Outbound blob cleanup

    private func cleanupOutboundBlobs(recordName: String) {
        // Temp files for CKAsset uploads live in caches/CopiedSync/
        // outbound-blobs/<recordName>.<key>.bin — remove them once the
        // save is confirmed so we don't re-upload the same data on
        // subsequent change-batch passes.
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("CopiedSync/outbound-blobs", isDirectory: true)
        for key in ["imageData", "richTextData", "htmlData"] {
            let file = dir.appendingPathComponent("\(recordName).\(key).bin")
            try? fm.removeItem(at: file)
        }
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
