import Foundation
import CloudKit
import SwiftData
import Observation
import OSLog

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

    private static let profileLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Copied",
        category: "SyncProfile"
    )
    private static let signposter = OSSignposter(logger: profileLogger)

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
        /// recordName → encoded CKRecord system fields (recordChangeTag,
        /// creationDate, modifiedBy, etc). Essential for UPDATE sends:
        /// without a base record carrying the server's current etag,
        /// every save is sent as an INSERT and fails with
        /// `serverRecordChanged` (CKError code 2) once the record
        /// exists. Updated on every successful send + on any fetched
        /// record; rebased from `error.serverRecord` on conflict.
        var lastKnownRecordSystemFields: [String: Data] = [:]
        /// clippingID → listID for Clippings whose ClipList arrived
        /// later than (or before) the Clipping record. CKSyncEngine
        /// batch ordering is non-deterministic; a Clipping referencing
        /// a ClipList that hasn't upserted yet would have
        /// `list = nil` permanently. We record the orphan link here;
        /// `upsertClipList` scans + re-stitches once the target list
        /// upserts. Entry cleared on re-stitch.
        var pendingListReferences: [String: String] = [:]
        /// Encoded `CKServerChangeToken` for our manual zone-changes
        /// fetch path. Independent from the engine's own token
        /// (`stateSerialization`) — kept separately so the manual
        /// pull never corrupts engine state. Used by
        /// `manualInboundFetch` to compensate for macOS withholding
        /// silent pushes from background menu-bar apps.
        var manualPullZoneToken: Data?
    }

    private var persisted: Persisted
    private let stateFileURL: URL
    private let stateQueue = DispatchQueue(label: "com.magneton.copied.syncengine.state")

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
        //
        // NOTE: don't flip `didSeedUpload` here — that's done in
        // `handleSentRecordZoneChanges` after observing at least one
        // successful save. Flipping it eagerly would orphan queued
        // changes if the app crashes / network fails before the first
        // send lands, causing `serverRecordChanged` floods on relaunch.
        if !persisted.didSeedUpload {
            seedLocalData(container: modelContainer)
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
            // Backfill contentHash on any rows captured before the
            // hash field existed (legacy migration). Empty hash would
            // bypass the cross-device dedup, so do this eagerly at
            // seed time for every row we're about to upload.
            var hashed = 0
            for clipping in clippings where clipping.contentHash.isEmpty {
                clipping.contentHash = clipping.computeContentHash()
                hashed += 1
            }
            if hashed > 0 {
                try? ctx.save()
                NSLog("[CopiedSyncEngine] backfilled contentHash on \(hashed) legacy clippings")
            }

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

    /// Guards against overlapping syncNow() calls. Multiple triggers
    /// (timer + didBecomeActive + popover-open + Sync Now button) can
    /// fire within a second of each other; without this flag each
    /// queues a separate fetchChanges/sendChanges pair on CKSyncEngine,
    /// which can interleave mid-batch and lose pending mutations.
    /// `@MainActor`-isolated read/write is the simplest correct pattern.
    @MainActor private var syncInFlight = false
    @MainActor private var fetchInFlight = false
    @MainActor private var manualPullInFlight = false
    @MainActor private var lastManualPullAt: Date?
    @MainActor private static let manualPullCooldown: TimeInterval = 3

    @MainActor
    private struct FetchOutcome {
        var source: String
        var startedAt: Date
        var sawDatabaseChanges = false
        var sawWillFetchRecordZoneChanges = false
        var sawDidFetchRecordZoneChanges = false
        var sawRecordZoneChanges = false
        var modificationCount = 0
        var deletionCount = 0
    }

    @MainActor private var currentFetchOutcome: FetchOutcome?

    /// Manual sync — fetch first (pull inbound), then send (push outbound).
    /// Matches the user's "Sync Now" semantics: one button, both directions.
    /// Concurrent calls are no-ops while a sync is already running.
    @MainActor
    public func syncNow() async {
        guard !syncInFlight else { return }
        guard let engine else { return }
        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval(
            "syncNow",
            id: signpostID,
            "source=manual"
        )
        syncInFlight = true
        defer { syncInFlight = false }
        defer { Self.signposter.endInterval("syncNow", state) }
        do {
            Self.profileLogger.log("syncNow begin source=manual")
            NSLog("[CopiedSyncEngine] syncNow source=manual.fetch begin")
            try await engine.fetchChanges()
            NSLog("[CopiedSyncEngine] syncNow source=manual.send begin")
            try await engine.sendChanges()
            NSLog("[CopiedSyncEngine] syncNow source=manual complete")
            Self.profileLogger.log("syncNow complete source=manual")
        } catch {
            NSLog("[CopiedSyncEngine] syncNow failed: \(error.localizedDescription)")
            Self.profileLogger.error("syncNow failed source=manual error=\(error.localizedDescription, privacy: .public)")
        }
    }

    public func fetchChanges(source: String = "unknown") async {
        let pendingChanges = engine?.state.pendingRecordZoneChanges ?? []
        let pendingSaveCount = pendingChanges.reduce(into: 0) { count, change in
            if case .saveRecord = change { count += 1 }
        }
        let pendingDeleteCount = pendingChanges.reduce(into: 0) { count, change in
            if case .deleteRecord = change { count += 1 }
        }
        let (syncNowInFlight, shouldRun) = await MainActor.run { () -> (Bool, Bool) in
            let syncNowInFlight = self.syncInFlight
            guard !self.fetchInFlight else { return (syncNowInFlight, false) }
            self.fetchInFlight = true
            self.currentFetchOutcome = FetchOutcome(source: source, startedAt: Date())
            return (syncNowInFlight, true)
        }
        guard shouldRun else {
            Self.profileLogger.log("fetchChanges skipped source=\(source, privacy: .public) reason=fetchAlreadyInFlight")
            return
        }
        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval(
            "fetchChanges",
            id: signpostID,
            "source=\(source, privacy: .public)"
        )
        do {
            Self.profileLogger.log(
                "fetchContext source=\(source, privacy: .public) engineReady=\(self.engine != nil) syncInFlight=\(syncNowInFlight) pendingSaves=\(pendingSaveCount) pendingDeletes=\(pendingDeleteCount) hasStateSerialization=\(self.persisted.stateSerialization != nil) didSeedUpload=\(self.persisted.didSeedUpload) pendingListRefs=\(self.persisted.pendingListReferences.count)"
            )
            Self.profileLogger.log("fetchChanges begin source=\(source, privacy: .public)")
            NSLog("[CopiedSyncEngine] fetchChanges source=\(source) begin")
            try await engine?.fetchChanges()
            NSLog("[CopiedSyncEngine] fetchChanges source=\(source) complete")
            Self.profileLogger.log("fetchChanges complete source=\(source, privacy: .public)")
        } catch {
            NSLog("[CopiedSyncEngine] fetchChanges source=\(source) failed: \(error.localizedDescription)")
            Self.profileLogger.error("fetchChanges failed source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        let finishedOutcome = await MainActor.run { () -> FetchOutcome? in
            let outcome = self.currentFetchOutcome
            self.currentFetchOutcome = nil
            self.fetchInFlight = false
            return outcome
        }
        if let finishedOutcome {
            Self.profileLogger.log(
                "fetchOutcome source=\(finishedOutcome.source, privacy: .public) duration=\(Date().timeIntervalSince(finishedOutcome.startedAt)) sawDatabaseChanges=\(finishedOutcome.sawDatabaseChanges) sawWillFetchRecordZoneChanges=\(finishedOutcome.sawWillFetchRecordZoneChanges) sawDidFetchRecordZoneChanges=\(finishedOutcome.sawDidFetchRecordZoneChanges) sawRecordZoneChanges=\(finishedOutcome.sawRecordZoneChanges) modifications=\(finishedOutcome.modificationCount) deletions=\(finishedOutcome.deletionCount)"
            )
        }
        Self.signposter.endInterval("fetchChanges", state)
    }

    public func sendChanges() async {
        do {
            try await engine?.sendChanges()
        } catch {
            NSLog("[CopiedSyncEngine] sendChanges failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual inbound fetch (background-app push compensation)

    /// Real server round-trip via `CKFetchRecordZoneChangesOperation`,
    /// independent of `CKSyncEngine.fetchChanges()`. Needed because
    /// macOS withholds CloudKit silent pushes from background menu-bar
    /// apps until the app activates — without a push, the engine has
    /// nothing to process and `fetchChanges()` is a no-op.
    ///
    /// Uses our own change token (`persisted.manualPullZoneToken`)
    /// rather than the engine's serialized state. Records are routed
    /// through the same `upsertClipping` / `upsertClipList` paths the
    /// engine uses, so a record arriving twice (once via this path,
    /// once via the engine) merges idempotently.
    public func manualInboundFetch(source: String) async {
        guard let _ = engine else {
            Self.profileLogger.log(
                "manualPull skipped source=\(source, privacy: .public) reason=engineNotStarted"
            )
            return
        }

        let shouldRun = await MainActor.run { () -> Bool in
            guard !self.manualPullInFlight else { return false }
            if let last = self.lastManualPullAt,
               Date().timeIntervalSince(last) < Self.manualPullCooldown {
                return false
            }
            self.manualPullInFlight = true
            self.lastManualPullAt = Date()
            return true
        }
        guard shouldRun else {
            Self.profileLogger.log(
                "manualPull skipped source=\(source, privacy: .public) reason=cooldownOrInFlight"
            )
            return
        }
        defer {
            Task { @MainActor in self.manualPullInFlight = false }
        }

        let startedAt = Date()
        let token = decodedManualPullToken()
        Self.profileLogger.log(
            "manualPull begin source=\(source, privacy: .public) hasToken=\(token != nil)"
        )

        do {
            let result = try await fetchZoneChanges(token: token)
            await applyManualPullChanges(
                modifications: result.modifications,
                deletions: result.deletions,
                source: source
            )
            if let newToken = result.newToken {
                encodeManualPullToken(newToken)
            }
            Self.profileLogger.log(
                "manualPull complete source=\(source, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) modifications=\(result.modifications.count) deletions=\(result.deletions.count) moreComing=\(result.moreComing) tokenAdvanced=\(result.newToken != nil)"
            )

            // If the server says there's more, drain immediately
            // (CloudKit caps each response). Cooldown gate is bypassed
            // for the continuation since we're already in-flight.
            if result.moreComing {
                Self.profileLogger.log(
                    "manualPull continuing source=\(source, privacy: .public) reason=moreComing"
                )
                await drainRemainingZoneChanges(source: source)
            }
        } catch {
            // Server-side reset (CloudKit Dashboard "Reset Production
            // Environment", zone delete, or token aging) makes our local
            // change token invalid. CKError reports this as:
            //   .changeTokenExpired      (21) — "client knowledge differs from server knowledge"
            //   .zoneNotFound            (26) — zone got deleted server-side
            //   .userDeletedZone         (28) — user purged via iOS Settings
            // For all three, recovery is the same: clear local token, refetch
            // from scratch (token: nil = full zone replay). One retry only —
            // if it still fails, log + give up so we don't loop forever.
            if shouldResetTokenForError(error) {
                Self.profileLogger.notice(
                    "manualPull token invalid (server reset) — clearing local token + retrying full pull source=\(source, privacy: .public)"
                )
                clearManualPullToken()
                do {
                    let result = try await fetchZoneChanges(token: nil)
                    await applyManualPullChanges(
                        modifications: result.modifications,
                        deletions: result.deletions,
                        source: "\(source).afterReset"
                    )
                    if let newToken = result.newToken {
                        encodeManualPullToken(newToken)
                    }
                    Self.profileLogger.log(
                        "manualPull recovered source=\(source, privacy: .public) modifications=\(result.modifications.count) deletions=\(result.deletions.count)"
                    )
                    if result.moreComing {
                        await drainRemainingZoneChanges(source: "\(source).afterReset")
                    }
                    return
                } catch {
                    Self.profileLogger.error(
                        "manualPull retry-after-reset failed source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            NSLog("[CopiedSyncEngine] manualPull source=\(source) failed: \(error.localizedDescription)")
            Self.profileLogger.error(
                "manualPull failed source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns true if the CloudKit error indicates the server's view of
    /// the zone diverged from our locally-persisted change token —
    /// recoverable by clearing the token and re-fetching the whole zone.
    private func shouldResetTokenForError(_ error: Error) -> Bool {
        let codes: Set<Int> = [
            CKError.changeTokenExpired.rawValue,    // 21
            CKError.zoneNotFound.rawValue,          // 26
            CKError.userDeletedZone.rawValue        // 28
        ]
        if let ck = error as? CKError, codes.contains(ck.code.rawValue) {
            return true
        }
        // CKErrorPartialFailure wraps per-zone errors in a dict; check those too
        if let ck = error as? CKError,
           ck.code == .partialFailure,
           let perZone = ck.partialErrorsByItemID as? [CKRecordZone.ID: Error] {
            return perZone.values.contains { sub in
                if let cksub = sub as? CKError { return codes.contains(cksub.code.rawValue) }
                return false
            }
        }
        // Fallback: inspect the localized description for the canonical phrase
        return error.localizedDescription.contains("client knowledge differs from server knowledge")
    }

    private func drainRemainingZoneChanges(source: String) async {
        var pageIndex = 1
        while true {
            let token = decodedManualPullToken()
            do {
                let result = try await fetchZoneChanges(token: token)
                await applyManualPullChanges(
                    modifications: result.modifications,
                    deletions: result.deletions,
                    source: "\(source).page\(pageIndex)"
                )
                if let newToken = result.newToken {
                    encodeManualPullToken(newToken)
                }
                Self.profileLogger.log(
                    "manualPull page source=\(source, privacy: .public) page=\(pageIndex) modifications=\(result.modifications.count) deletions=\(result.deletions.count) moreComing=\(result.moreComing)"
                )
                if !result.moreComing { return }
                pageIndex += 1
            } catch {
                Self.profileLogger.error(
                    "manualPull page failed source=\(source, privacy: .public) page=\(pageIndex) error=\(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
    }

    private struct ZoneChangesResult {
        var modifications: [CKRecord]
        var deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)]
        var newToken: CKServerChangeToken?
        var moreComing: Bool
    }

    private func fetchZoneChanges(
        token: CKServerChangeToken?
    ) async throws -> ZoneChangesResult {
        try await withCheckedThrowingContinuation { continuation in
            var modifications: [CKRecord] = []
            var deletions: [(CKRecord.ID, CKRecord.RecordType)] = []
            var newToken: CKServerChangeToken? = token
            var moreComing = false
            var firstError: Error?

            let zoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: token
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [Self.zoneID],
                configurationsByRecordZoneID: [Self.zoneID: zoneConfig]
            )

            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    modifications.append(record)
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }

            operation.recordWithIDWasDeletedBlock = { id, type in
                deletions.append((id, type))
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                if let token { newToken = token }
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let response):
                    newToken = response.serverChangeToken
                    moreComing = response.moreComing
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                if let firstError {
                    continuation.resume(throwing: firstError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: ZoneChangesResult(
                        modifications: modifications,
                        deletions: deletions,
                        newToken: newToken,
                        moreComing: moreComing
                    ))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.container.privateCloudDatabase.add(operation)
        }
    }

    @MainActor
    private func applyManualPullChanges(
        modifications: [CKRecord],
        deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)],
        source: String
    ) async {
        guard let modelContainer else { return }
        let ctx = ModelContext(modelContainer)

        for record in modifications {
            let name = record.recordID.recordName
            switch record.recordType {
            case RecordType.clipping:
                upsertClipping(record: record, recordName: name, ctx: ctx)
            case RecordType.clipList:
                upsertClipList(record: record, recordName: name, ctx: ctx)
            default:
                Self.profileLogger.log(
                    "manualPull unknownType source=\(source, privacy: .public) type=\(record.recordType, privacy: .public)"
                )
            }
        }

        var hardDeletedClippings = 0
        var hardDeletedLists = 0
        for (id, type) in deletions {
            let name = id.recordName
            switch type {
            case RecordType.clipping:
                let desc = FetchDescriptor<Clipping>(
                    predicate: #Predicate<Clipping> { $0.clippingID == name }
                )
                if let row = try? ctx.fetch(desc).first {
                    ctx.delete(row)
                    hardDeletedClippings += 1
                    Self.profileLogger.log(
                        "manualPull hardDeleteClipping source=\(source, privacy: .public) id=\(name, privacy: .public)"
                    )
                }
            case RecordType.clipList:
                let desc = FetchDescriptor<ClipList>(
                    predicate: #Predicate<ClipList> { $0.listID == name }
                )
                if let row = try? ctx.fetch(desc).first {
                    ctx.delete(row)
                    hardDeletedLists += 1
                    Self.profileLogger.log(
                        "manualPull hardDeleteList source=\(source, privacy: .public) id=\(name, privacy: .public)"
                    )
                }
            default:
                break
            }
        }

        try? ctx.save()

        if !modifications.isEmpty || !deletions.isEmpty {
            let mainCtx = modelContainer.mainContext
            if mainCtx !== ctx {
                mainCtx.processPendingChanges()
            }

            let activeDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> { $0.deleteDate == nil }
            )
            let trashDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> { $0.deleteDate != nil }
            )
            let activeCount = (try? ctx.fetchCount(activeDesc)) ?? -1
            let trashCount = (try? ctx.fetchCount(trashDesc)) ?? -1
            Self.profileLogger.log(
                "manualPull applied source=\(source, privacy: .public) modifications=\(modifications.count) hardDeletes=\(hardDeletedClippings + hardDeletedLists) active=\(activeCount) trash=\(trashCount)"
            )
            SyncTicker.shared.bump()
            syncMonitor?.applyExternalStatus(SyncMonitor.SyncStatus.synced(Date()))
        }

        for record in modifications {
            rememberSystemFields(of: record)
        }
    }

    private func decodedManualPullToken() -> CKServerChangeToken? {
        let data = stateQueue.sync { persisted.manualPullZoneToken }
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    private func encodeManualPullToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true
        ) else { return }
        stateQueue.sync {
            persisted.manualPullZoneToken = data
        }
        persist()
    }

    /// Wipe the locally-persisted change token. Used after the server reset
    /// the zone (CKErrorChangeTokenExpired etc.); the next fetch passes nil
    /// and replays the entire zone from scratch.
    private func clearManualPullToken() {
        stateQueue.sync {
            persisted.manualPullZoneToken = nil
        }
        persist()
    }

    /// Called by every Clipping / ClipList / Asset mutation site (Phase 3
    /// wires these). Safe to call before the engine has started — changes
    /// buffer up and flush on first `sendChanges`.
    ///
    /// After queueing the change we nudge an immediate `sendChanges()`
    /// on a detached Task. CKSyncEngine de-duplicates overlapping send
    /// cycles internally, so rapid-fire enqueues collapse into a single
    /// upload. Without the explicit nudge the engine's scheduler can
    /// defer the upload by minutes under some network/system-load
    /// conditions — Apple's recommended pattern is "kick upload
    /// immediately when the user has just mutated data."
    public func enqueueChange(recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        Task.detached { [weak self] in await self?.sendChanges() }
    }

    public func enqueueDelete(recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        Task.detached { [weak self] in await self?.sendChanges() }
    }

    /// Nuke-everything path: wipes every local Clipping/ClipList row,
    /// deletes all CloudKit zones the app has touched (current + legacy
    /// orphans), clears the engine's state file, zeroes in-memory
    /// caches. Shared between the Mac Settings → Danger Zone button
    /// and the iOS equivalent. Idempotent — safe to call when already
    /// empty.
    @MainActor
    public func performFullWipe(modelContainer: ModelContainer) async {
        // 1. Wipe local SwiftData rows using the SHARED mainContext so
        //    the view's @Query observers see the deletes immediately.
        //    A fresh ModelContext also saves to the same persistent
        //    store, but the view's main-actor context doesn't auto-
        //    refresh from cross-context writes — user saw stale rows.
        let ctx = modelContainer.mainContext
        if let clippings = try? ctx.fetch(FetchDescriptor<Clipping>()) {
            NSLog("[CopiedSyncEngine] wiping \(clippings.count) clippings")
            for c in clippings { ctx.delete(c) }
        }
        if let lists = try? ctx.fetch(FetchDescriptor<ClipList>()) {
            NSLog("[CopiedSyncEngine] wiping \(lists.count) lists")
            for l in lists { ctx.delete(l) }
        }
        do {
            try ctx.save()
        } catch {
            NSLog("[CopiedSyncEngine] wipe-save failed: \(error)")
        }

        // 2. Delete the CloudKit zones directly — the fastest path to
        //    drop hundreds of MB of server data. We delete:
        //    - "Copied" (current CKSyncEngine custom zone)
        //    - "copied" (legacy lowercase, in case any data remains)
        //    - "com.apple.coredata.cloudkit.zone" (legacy NSPCKC auto-zone)
        let db = container.privateCloudDatabase
        let zones: [CKRecordZone.ID] = [
            Self.zoneID,
            CKRecordZone.ID(zoneName: "copied", ownerName: CKCurrentUserDefaultName),
            CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        ]
        for zoneID in zones {
            do {
                _ = try await db.deleteRecordZone(withID: zoneID)
                NSLog("[CopiedSyncEngine] deleted zone \(zoneID.zoneName)")
            } catch {
                // Zone may not exist — that's fine.
                NSLog("[CopiedSyncEngine] deleteRecordZone \(zoneID.zoneName) failed (OK if zone didn't exist): \(error.localizedDescription)")
            }
        }

        // 3. Clear persisted engine state + every sibling file (outbound
        //    blob cache) so the next launch starts from zero.
        //    stateQueue.sync guards the dict reset against concurrent
        //    reads in baseRecord.
        stateQueue.sync {
            persisted = Persisted()
        }
        let parent = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)

        // Bump SyncTicker so every @Observable-bound view (popover
        // especially) recomputes against the now-empty store even if
        // it was not focused during the wipe.
        SyncTicker.shared.bump()
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
            Self.profileLogger.log(
                "event stateUpdate hasStateSerialization=\(self.persisted.stateSerialization != nil) didSeedUpload=\(self.persisted.didSeedUpload) pendingListRefs=\(self.persisted.pendingListReferences.count)"
            )
            persist()

        case .accountChange(let e):
            await handleAccountChange(e)

        case .fetchedDatabaseChanges(let e):
            await MainActor.run {
                self.currentFetchOutcome?.sawDatabaseChanges = true
            }
            // Zone create/delete events. We only care about our `copied`
            // zone; Phase 4 fills in zone-deletion handling (user signed
            // out + back in → need to reseed).
            Self.profileLogger.log(
                "event fetchedDatabaseChanges payload=\(String(describing: e), privacy: .public)"
            )

        case .fetchedRecordZoneChanges(let e):
            await MainActor.run {
                self.currentFetchOutcome?.sawRecordZoneChanges = true
                self.currentFetchOutcome?.modificationCount += e.modifications.count
                self.currentFetchOutcome?.deletionCount += e.deletions.count
            }
            Self.profileLogger.log(
                "event fetchedRecordZoneChanges modifications=\(e.modifications.count) deletions=\(e.deletions.count)"
            )
            await handleFetchedRecordZoneChanges(e)

        case .sentRecordZoneChanges(let e):
            await handleSentRecordZoneChanges(e)

        case .willFetchChanges:
            Self.profileLogger.log("event willFetchChanges")
            await updateStatus(SyncMonitor.SyncStatus.syncing(direction: "Checking…"))

        case .willSendChanges:
            Self.profileLogger.log("event willSendChanges")
            await updateStatus(SyncMonitor.SyncStatus.syncing(direction: "Uploading…"))

        case .didFetchChanges:
            Self.profileLogger.log("event didFetchChanges")
            // If we didn't flip to `.synced(...)` from the modifications
            // path, fall back to `.available` so the label doesn't lie
            // with a stale "Synced Xm ago".
            await updateStatusIfSyncing(SyncMonitor.SyncStatus.available)

        case .didSendChanges:
            Self.profileLogger.log("event didSendChanges")
            await updateStatusIfSyncing(SyncMonitor.SyncStatus.available)

        case .sentDatabaseChanges(let e):
            Self.profileLogger.log(
                "event sentDatabaseChanges payload=\(String(describing: e), privacy: .public)"
            )

        case .willFetchRecordZoneChanges(let e):
            await MainActor.run {
                self.currentFetchOutcome?.sawWillFetchRecordZoneChanges = true
            }
            Self.profileLogger.log(
                "event willFetchRecordZoneChanges payload=\(String(describing: e), privacy: .public)"
            )

        case .didFetchRecordZoneChanges(let e):
            await MainActor.run {
                self.currentFetchOutcome?.sawDidFetchRecordZoneChanges = true
            }
            Self.profileLogger.log(
                "event didFetchRecordZoneChanges payload=\(String(describing: e), privacy: .public)"
            )

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

    /// Maximum records per outbound batch. Keeps memory bounded when the
    /// pending queue is large (e.g. after a reclassification migration that
    /// dirtied many records, or after a copy storm). CKSyncEngine will call
    /// us again for the next slice when this batch completes.
    private static let maxBatchRecords = 50

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let allChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !allChanges.isEmpty else { return nil }
        // Cap per-call batch size so we don't spike RSS by materializing
        // every pending CKRecord (with its CKAsset blob references) at once.
        let changes = Array(allChanges.prefix(Self.maxBatchRecords))
        let saveCount = changes.reduce(into: 0) { count, change in
            if case .saveRecord = change { count += 1 }
        }
        let deleteCount = changes.reduce(into: 0) { count, change in
            if case .deleteRecord = change { count += 1 }
        }
        Self.profileLogger.log(
            "nextRecordZoneChangeBatch scope=\(String(describing: scope), privacy: .public) total=\(changes.count) saves=\(saveCount) deletes=\(deleteCount)"
        )

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
            // Base on cached system fields (etag) if we have them,
            // otherwise construct fresh for the first-time INSERT.
            // `shared` singleton safe here — setup happens on MainActor
            // during app launch, inbound/outbound mutations happen on
            // the engine's serial queue.
            let record = Self.shared.baseRecord(
                for: recordName, type: RecordType.clipping
            )
            CKRecordMapper.populate(record, from: clipping)
            return record
        }

        // Then ClipList.
        let listDesc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == recordName }
        )
        if let list = try? ctx.fetch(listDesc).first {
            let record = Self.shared.baseRecord(
                for: recordName, type: RecordType.clipList
            )
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
        // collide with SwiftUI's view-tree render cycle against
        // mainContext (mid-render mainContext writes were correlated
        // with degraded @Query refresh reliability — reverted after
        // a short experiment).
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

            // Deletions — hard-delete matching local rows unconditionally.
            //
            // Earlier versions had a 5-second "recent local edit"
            // skip guard, but `modifiedDate` is also set every time an
            // inbound record applies locally — so the very-recent value
            // is almost always from a fetch, not a user action. The
            // guard caused deletions to be silently dropped and records
            // to resurrect, which is the opposite of what users expect
            // ("deleted on Mac but keeps coming back on iOS"). Honor
            // every delete. The rare concurrent-recover race is an
            // acceptable tradeoff.
            for deletion in event.deletions {
                let recordName = deletion.recordID.recordName
                NSLog("[CopiedSyncEngine] apply delete type=\(deletion.recordType) id=\(recordName)")
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

            // Cross-context refresh bridge. SwiftData normally auto-merges
            // saves between contexts backed by the same ModelContainer, but
            // the receiving context only processes the merge at its own
            // `processPendingChanges()` tick. Calling it explicitly on
            // mainContext after the detached import saves is what makes
            // main-window @Query observers pick up iOS-side deletes in
            // real time — regardless of whether the window is visible,
            // minimized, or hidden.
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                let mainCtx = modelContainer.mainContext
                if mainCtx !== ctx {
                    NSLog("[CopiedSyncEngine] processPendingChanges modifications=\(event.modifications.count) deletions=\(event.deletions.count)")
                    mainCtx.processPendingChanges()
                }
            }

            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                let activeDesc = FetchDescriptor<Clipping>(
                    predicate: #Predicate<Clipping> { $0.deleteDate == nil }
                )
                let trashDesc = FetchDescriptor<Clipping>(
                    predicate: #Predicate<Clipping> { $0.deleteDate != nil }
                )
                let activeCount = (try? ctx.fetchCount(activeDesc)) ?? -1
                let trashCount = (try? ctx.fetchCount(trashDesc)) ?? -1
                Self.profileLogger.log(
                    "postImportCounts active=\(activeCount) trash=\(trashCount) modifications=\(event.modifications.count) deletions=\(event.deletions.count)"
                )
            }

            // Real import landed → bump SyncTicker so the popover's
            // @Observable-bound recompute runs, and honest-up the status.
            // With NSPCKC disabled (Q1), `NSPersistentStoreRemoteChange`
            // doesn't fire for CKSyncEngine's private-context saves — so
            // the only way the popover learns a delete landed is this
            // explicit bump. The main window's @Query observers pick up
            // changes natively via SwiftData's coordinator, so this bump
            // is harmless there but critical for popover refresh when
            // the main window is closed.
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                NSLog("[CopiedSyncEngine] bump SyncTicker modifications=\(event.modifications.count) deletions=\(event.deletions.count)")
                SyncTicker.shared.bump()
                syncMonitor?.applyExternalStatus(SyncMonitor.SyncStatus.synced(Date()))
            }
        }

        // Cache the server's system fields for each fetched modification
        // so the next outbound save for this record uses the correct
        // etag and doesn't collide.
        for mod in event.modifications {
            rememberSystemFields(of: mod.record)
        }
        // Deletions: drop any cached system fields so future saves of the
        // same ID (e.g. restore flow) start fresh.
        for del in event.deletions {
            persisted.lastKnownRecordSystemFields.removeValue(
                forKey: del.recordID.recordName
            )
        }
        persist()
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        Self.profileLogger.log(
            "handleSentRecordZoneChanges saved=\(event.savedRecords.count) deleted=\(event.deletedRecordIDs.count) failed=\(event.failedRecordSaves.count)"
        )
        // Successful save → record's system fields now carry the
        // server-assigned etag. Cache for the next UPDATE cycle AND
        // clean up the outbound CKAsset blob temp files.
        for savedRecord in event.savedRecords {
            rememberSystemFields(of: savedRecord)
            cleanupOutboundBlobs(recordName: savedRecord.recordID.recordName)
        }
        // Deletions also update the cache — drop the entry.
        for deletedID in event.deletedRecordIDs {
            persisted.lastKnownRecordSystemFields.removeValue(
                forKey: deletedID.recordName
            )
        }
        // First successful save confirms CKSyncEngine actually delivered
        // something — safe to mark the seed migration done. Guarding on
        // `savedRecords.isEmpty == false` ensures we don't flip the
        // flag on a batch with only failures.
        if !persisted.didSeedUpload && !event.savedRecords.isEmpty {
            persisted.didSeedUpload = true
        }
        persist()

        // Per-record failure handling.
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // The server has a newer etag than what we sent. Do
                // three things, per the canonical pattern (Apple's
                // sample-cloudkit-sync-engine + WWDC'23 guidance):
                // 1. Cache server's system fields (etag) for next send
                // 2. Merge server's field values into local row (LWW)
                // 3. Re-enqueue the pending change to force a fresh
                //    nextRecordZoneChangeBatch cycle that's guaranteed
                //    to pick up the updated etag cache
                if let serverRecord = failure.error.serverRecord {
                    rememberSystemFields(of: serverRecord)
                    await mergeServerIntoLocal(serverRecord: serverRecord)
                    engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .zoneNotFound, .userDeletedZone:
                // Our zone was deleted (user signed out + back in?).
                // Re-enqueue zone create + re-try this record save.
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: Self.zoneID))
                ])
            case .unknownItem:
                // Record was deleted server-side; drop our save + cache.
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                persisted.lastKnownRecordSystemFields.removeValue(
                    forKey: recordID.recordName
                )
                persist()
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
        // Shell = no content AT ALL. Must check every content signal
        // or we'll wrongly delete legitimate rich-text / HTML rows
        // (text/title/url are empty for those but hasRichText/hasHTML
        // is true, and extractedText carries the plain-text preview).
        let text = (record["text"] as? String) ?? ""
        let title = (record["title"] as? String) ?? ""
        let url = (record["url"] as? String) ?? ""
        let sourceURL = (record["sourceURL"] as? String) ?? ""
        let extractedText = (record["extractedText"] as? String) ?? ""
        let hasImage = (record["hasImage"] as? Bool) ?? false
        let hasRichText = (record["hasRichText"] as? Bool) ?? false
        let hasHTML = (record["hasHTML"] as? Bool) ?? false
        let isShell = text.isEmpty && title.isEmpty && url.isEmpty
            && sourceURL.isEmpty && extractedText.isEmpty
            && !hasImage && !hasRichText && !hasHTML

        let desc = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.clippingID == recordName }
        )
        let existing = try? ctx.fetch(desc).first

        if isShell, existing == nil {
            // Don't insert garbage; tell CloudKit to forget this record.
            engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(record.recordID)])
            return
        }

        // Cross-device content-hash dedup — SAFE version.
        //
        // When a record arrives with a recordName we've never seen, but
        // a local clipping already has the same `contentHash`, both
        // devices independently captured the same content (typically
        // via Handoff). Without this check we'd accumulate duplicates
        // across the pair.
        //
        // The fix avoids the "destroy canonical" trap that the previous
        // simpler content-dedup had. Rule: the lex-min UUID wins.
        // Both devices compare IDs the same way and independently
        // converge on the same survivor. The loser is hard-deleted
        // locally AND removed from the cloud, so all peers drop it on
        // their next fetch.
        //
        // Skips if either side's hash is empty (pre-migration data) —
        // those get backfilled by `ensureContentHash` / seedLocalData
        // and the dedup fires on next sync pass.
        if existing == nil, !isShell,
           let incomingHash = record["contentHash"] as? String,
           !incomingHash.isEmpty {
            let hashMatchDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> {
                    $0.contentHash == incomingHash && $0.deleteDate == nil
                }
            )
            if let local = try? ctx.fetch(hashMatchDesc).first {
                // Q6: mixed-version fleets — a row created before the
                // contentHash migration stays with an empty hash until
                // something populates it. The lookup above keyed on
                // matching-hash couldn't have reached a row whose hash
                // is still empty, but in case upstream widens the
                // predicate we still want local's hash adopted so the
                // tiebreak reasons over a consistent key.
                if local.contentHash.isEmpty {
                    local.contentHash = incomingHash
                }
                if local.clippingID < recordName {
                    // Local UUID wins — drop the incoming from cloud.
                    engine?.state.add(pendingRecordZoneChanges: [
                        .deleteRecord(record.recordID)
                    ])
                    return
                } else {
                    // Incoming UUID wins — replace local with incoming.
                    // Delete local + enqueue cloud delete of local's ID.
                    let loserID = local.clippingID
                    ctx.delete(local)
                    engine?.state.add(pendingRecordZoneChanges: [
                        .deleteRecord(Self.clippingRecordID(loserID))
                    ])
                    // Fall through to insert the incoming as a new row.
                }
            }
        }

        let incomingModified = record["modifiedDate"] as? Date
        let incomingDeleteDate = record["deleteDate"] as? Date
        Self.profileLogger.log(
            "upsertClipping id=\(recordName, privacy: .public) existing=\(existing != nil) incomingDeleted=\(incomingDeleteDate != nil) incomingModified=\(String(describing: incomingModified), privacy: .public)"
        )

        if let existing {
            // deleteDate override: trash is one-way. If EITHER side has
            // deleteDate set, trash state wins regardless of modifiedDate.
            // Prevents a peer's concurrent pin/favorite edit (with a
            // newer modifiedDate) from un-trashing a clipping the user
            // just deleted.
            let localDeleted = existing.deleteDate != nil
            let incomingDeleted = incomingDeleteDate != nil
            Self.profileLogger.log(
                "upsertClipping existing id=\(recordName, privacy: .public) localDeleted=\(localDeleted) incomingDeleted=\(incomingDeleted) localModified=\(String(describing: existing.modifiedDate), privacy: .public)"
            )
            if !localDeleted && incomingDeleted {
                // Remote trashed it; accept the delete state.
                Self.profileLogger.log(
                    "upsertClipping branch=remoteTrashWins id=\(recordName, privacy: .public)"
                )
                CKRecordMapper.apply(record, to: existing)
                resolveListReference(
                    for: existing, record: record, recordName: recordName, ctx: ctx
                )
                return
            }
            if localDeleted && !incomingDeleted {
                // Local already in trash; ignore incoming un-trashed
                // version (means peer hasn't yet seen our trash).
                Self.profileLogger.log(
                    "upsertClipping branch=keepLocalTrash id=\(recordName, privacy: .public)"
                )
                return
            }
            // Both sides trashed (Q4). Canonical rule: preserve the
            // EARLIEST `deleteDate` so the `trashRetentionDays` purge
            // window converges on both devices. Without this, a later
            // LWW apply would overwrite local's earlier trash timestamp
            // with a newer one, resetting the auto-purge countdown.
            if localDeleted, incomingDeleted,
               let localDelete = existing.deleteDate,
               let incomingDelete = incomingDeleteDate,
               localDelete < incomingDelete {
                Self.profileLogger.log(
                    "upsertClipping branch=preserveEarliestTrashDate id=\(recordName, privacy: .public) localDelete=\(String(describing: localDelete), privacy: .public) incomingDelete=\(String(describing: incomingDelete), privacy: .public)"
                )
                CKRecordMapper.apply(record, to: existing)
                existing.deleteDate = localDelete
                resolveListReference(
                    for: existing, record: record, recordName: recordName, ctx: ctx
                )
                return
            }

            // Standard LWW on modifiedDate. Equal timestamps: remote
            // wins (consistent cross-device convergence).
            if let localModified = existing.modifiedDate,
               let incomingModified,
               localModified > incomingModified {
                Self.profileLogger.log(
                    "upsertClipping branch=dropOlderRemote id=\(recordName, privacy: .public)"
                )
                return  // local is newer; drop this remote update
            }
            Self.profileLogger.log(
                "upsertClipping branch=applyRemote id=\(recordName, privacy: .public)"
            )
            CKRecordMapper.apply(record, to: existing)
            resolveListReference(
                for: existing, record: record, recordName: recordName, ctx: ctx
            )
        } else {
            Self.profileLogger.log(
                "upsertClipping branch=insertNew id=\(recordName, privacy: .public) incomingDeleted=\(incomingDeleteDate != nil)"
            )
            let clipping = Clipping()
            clipping.clippingID = recordName
            ctx.insert(clipping)
            CKRecordMapper.apply(record, to: clipping)
            resolveListReference(
                for: clipping, record: record, recordName: recordName, ctx: ctx
            )
        }
    }

    /// Apply the ClipList reference from an inbound Clipping record.
    /// If the ClipList doesn't exist locally yet, record a pending link
    /// in `persisted.pendingListReferences`; `upsertClipList` re-stitches
    /// the relationship when the list eventually arrives.
    @MainActor
    private func resolveListReference(
        for clipping: Clipping,
        record: CKRecord,
        recordName: String,
        ctx: ModelContext
    ) {
        if let listID = CKRecordMapper.listID(from: record) {
            if let list = fetchClipList(listID: listID, ctx: ctx) {
                clipping.list = list
                persisted.pendingListReferences.removeValue(forKey: recordName)
            } else {
                // ClipList hasn't arrived yet. Remember the desired
                // relationship; upsertClipList will restitch below.
                clipping.list = nil
                persisted.pendingListReferences[recordName] = listID
                persist()
            }
        } else {
            clipping.list = nil
            persisted.pendingListReferences.removeValue(forKey: recordName)
        }
    }

    @MainActor
    private func upsertClipList(record: CKRecord, recordName: String, ctx: ModelContext) {
        let desc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == recordName }
        )
        let existing = try? ctx.fetch(desc).first
        let incomingModified = record["modifiedDate"] as? Date

        let list: ClipList
        if let existing {
            if let localModified = existing.modifiedDate,
               let incomingModified,
               localModified > incomingModified {
                return
            }
            CKRecordMapper.apply(record, to: existing)
            list = existing
        } else {
            let newList = ClipList(name: "")
            newList.listID = recordName
            ctx.insert(newList)
            CKRecordMapper.apply(record, to: newList)
            list = newList
        }

        // Orphan re-stitch: any Clippings that referenced this listID
        // while it was missing can now be linked.
        let orphanClippingIDs = persisted.pendingListReferences
            .filter { $0.value == recordName }
            .map(\.key)
        for cid in orphanClippingIDs {
            let orphanDesc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> { $0.clippingID == cid }
            )
            if let orphan = try? ctx.fetch(orphanDesc).first {
                orphan.list = list
            }
            persisted.pendingListReferences.removeValue(forKey: cid)
        }
        if !orphanClippingIDs.isEmpty {
            persist()
        }
    }

    @MainActor
    private func fetchClipList(listID: String, ctx: ModelContext) -> ClipList? {
        let desc = FetchDescriptor<ClipList>(
            predicate: #Predicate<ClipList> { $0.listID == listID }
        )
        return try? ctx.fetch(desc).first
    }

    /// On `serverRecordChanged` conflict: merge the server's field
    /// values into the local row. Canonical LWW:
    ///   - either-side `deleteDate != nil` wins (tombstone beats edit)
    ///   - otherwise newer `modifiedDate` wins (whole-record granularity)
    ///   - earliest `deleteDate` preserved (consistent purge-window)
    /// Runs via MainActor.run so SwiftData + @Query observers stay safe.
    private func mergeServerIntoLocal(serverRecord: CKRecord) async {
        guard let modelContainer else { return }
        let recordName = serverRecord.recordID.recordName
        await MainActor.run {
            let ctx = ModelContext(modelContainer)
            let desc = FetchDescriptor<Clipping>(
                predicate: #Predicate<Clipping> { $0.clippingID == recordName }
            )
            guard let local = try? ctx.fetch(desc).first else { return }
            let serverModified = serverRecord["modifiedDate"] as? Date
            let serverDeleteDate = serverRecord["deleteDate"] as? Date
            let localDeleted = local.deleteDate != nil
            let serverDeleted = serverDeleteDate != nil
            if serverDeleted && !localDeleted {
                CKRecordMapper.apply(serverRecord, to: local)
            } else if !serverDeleted && localDeleted {
                // Keep local deletion; don't let server un-trash
            } else if let localMod = local.modifiedDate,
                      let serverMod = serverModified,
                      localMod > serverMod {
                // Local is newer; keep our version as-is
            } else {
                CKRecordMapper.apply(serverRecord, to: local)
            }
            try? ctx.save()
        }
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

    // MARK: - CKRecord system-fields cache (fixes serverRecordChanged)

    /// Serialize a record's system fields (etag, zone, created-by, …)
    /// for later rehydration. Stored per-recordName in `persisted` so
    /// we survive app restarts.
    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Rehydrate a CKRecord from cached system-fields data. Returns nil
    /// if data is corrupt or absent — caller falls back to a fresh
    /// `CKRecord(recordType:, recordID:)`.
    private static func decodeRecord(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    /// Produce a base CKRecord for `recordName` / `recordType` — using
    /// the cached system fields if we have them (so the outbound save
    /// is an UPDATE at the correct etag) or a fresh record otherwise
    /// (first-time INSERT).
    ///
    /// Called from `makeRecord` inside `nextRecordZoneChangeBatch`'s
    /// record-provider closure (nonisolated, on the CKSyncEngine
    /// queue), while `rememberSystemFields` writes to the same dict
    /// from both the engine queue AND MainActor-isolated paths. The
    /// read/write pair must be serialized — we use `stateQueue.sync`
    /// since the queue is already a serial DispatchQueue independent
    /// of main, no deadlock risk.
    fileprivate func baseRecord(for recordName: String, type: String) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
        let cachedData = stateQueue.sync {
            persisted.lastKnownRecordSystemFields[recordName]
        }
        if let data = cachedData, let rehydrated = Self.decodeRecord(from: data) {
            return rehydrated
        }
        return CKRecord(recordType: type, recordID: recordID)
    }

    /// Cache the system fields of a record we've either successfully
    /// sent or fetched. Writes `persisted` to disk via the async queue.
    /// The in-memory dict write is guarded by `stateQueue.sync` to
    /// serialize against `baseRecord`'s read path.
    fileprivate func rememberSystemFields(of record: CKRecord) {
        let data = Self.encodeSystemFields(record)
        let key = record.recordID.recordName
        stateQueue.sync {
            persisted.lastKnownRecordSystemFields[key] = data
        }
        persist()
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
