import Foundation
import CloudKit
import CoreData
import Observation

/// Monitors real CloudKit sync activity via NSPersistentCloudKitContainer event notifications.
@Observable
@MainActor
public final class SyncMonitor {
    public enum SyncStatus: Sendable, Equatable {
        case notStarted
        case available        // iCloud account exists but no sync has occurred yet
        case noAccount
        case syncing(direction: String)
        case synced(Date)     // Only set after a real sync event completes
        case error(String)

        public var label: String {
            switch self {
            case .notStarted: return "Not syncing"
            case .available: return "Up to date"
            case .noAccount: return "No iCloud"
            case .syncing(let dir): return dir
            case .synced(let date):
                let ago = RelativeDateTimeFormatter()
                ago.unitsStyle = .abbreviated
                return "Synced \(ago.localizedString(for: date, relativeTo: Date()))"
            case .error(let msg): return msg
            }
        }

        public var isActive: Bool {
            switch self {
            case .available, .synced, .syncing: true
            default: false
            }
        }
    }

    public private(set) var status: SyncStatus = .notStarted
    public private(set) var importCount: Int = 0
    public private(set) var exportCount: Int = 0

    /// Allow `CopiedSyncEngine` (the real owner of sync state post-
    /// migration) to push status updates without exposing the setter
    /// everywhere. Public-module-visibility; intended only for the
    /// engine's delegate event handlers.
    public func applyExternalStatus(_ new: SyncStatus) {
        status = new
    }
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cloudSyncEnabled") != false }
        set {
            UserDefaults.standard.set(newValue, forKey: "cloudSyncEnabled")
            if newValue {
                checkAccountStatus()
            } else {
                status = .notStarted
            }
        }
    }

    private let containerIdentifier: String
    private var observers: [Any] = []
    private var accountCheckTask: Task<Void, Never>?

    public init(containerIdentifier: String = CopiedSchema.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public func start() {
        checkAccountStatus()

        // The real sync event notification from NSPersistentCloudKitContainer
        let eventNotification = NSNotification.Name("NSPersistentCloudKitContainer.eventChangedNotification")
        let eventObserver = NotificationCenter.default.addObserver(
            forName: eventNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract values on this queue before crossing actor boundary
            let event = notification.userInfo?["event"] as? NSObject
            let type = event?.value(forKey: "type") as? Int ?? -1
            let succeeded = event?.value(forKey: "succeeded") as? Bool ?? false
            let endDate = event?.value(forKey: "endDate") as? Date
            let error = event?.value(forKey: "error") as? NSError
            Task { @MainActor in
                self?.handleCloudKitEvent(type: type, succeeded: succeeded, endDate: endDate, error: error)
            }
        }
        observers.append(eventObserver)

        // NOTE: intentionally do NOT observe `.NSPersistentStoreRemoteChange`
        // here. That notification fires on any coordinator change — including
        // local saves we trigger ourselves via `mirrorPoke` — which would
        // falsely bump `importCount` and flip status to `.synced`. The only
        // authoritative "iOS data arrived" signal is the `.import` event in
        // `eventChangedNotification`, handled above. `SyncTicker` has its own
        // remote-change observer for UI refresh; we don't duplicate it here.

        // Periodic account check
        accountCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                self?.checkAccountStatus()
            }
        }
    }

    public func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        accountCheckTask?.cancel()
        accountCheckTask = nil
    }

    private func handleCloudKitEvent(type: Int, succeeded: Bool, endDate: Date?, error: NSError?) {
        // type: 0 = setup, 1 = import, 2 = export
        //
        // Only `.import` with `succeeded == true` updates status to
        // `.synced(date)` — that's the sole event that means "iOS data
        // actually arrived in the local store." Setup and export success
        // fall back to `.available` ("iCloud On") so the label never lies
        // with a stale "Synced Xm ago" when nothing inbound happened.
        switch type {
        case 0: // setup
            if succeeded {
                status = .available
            } else {
                status = .syncing(direction: "Setting up…")
            }
        case 1: // import (remote → local) — the only honest "synced" path
            if succeeded {
                importCount += 1
                status = .synced(endDate ?? Date())
            } else if endDate == nil {
                status = .syncing(direction: "Importing…")
            }
        case 2: // export (local → remote)
            if succeeded {
                exportCount += 1
                if case .syncing = status {
                    status = .available
                }
            } else if endDate == nil {
                status = .syncing(direction: "Exporting…")
            }
        default:
            break
        }

        // Check for errors
        if let error {
            // Don't show transient "partial failure" errors that auto-resolve
            if error.code != 4010 { // CKPartialFailure
                status = .error(error.localizedDescription.prefix(40) + "…")
            }
        }
    }

    public func checkAccountStatus() {
        guard isEnabled else {
            status = .notStarted
            return
        }
        let container = CKContainer(identifier: containerIdentifier)
        container.accountStatus { [weak self] accountStatus, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = .error(String(error.localizedDescription.prefix(40)))
                    return
                }
                switch accountStatus {
                case .available:
                    // Only set .available — real .synced requires an actual sync event
                    if case .notStarted = self.status {
                        self.status = .available
                    }
                    if case .noAccount = self.status {
                        self.status = .available
                    }
                case .noAccount:
                    self.status = .noAccount
                case .restricted, .couldNotDetermine:
                    self.status = .error("iCloud restricted")
                case .temporarilyUnavailable:
                    self.status = .error("iCloud unavailable")
                @unknown default:
                    break
                }
            }
        }
    }

    /// User-triggered / event-driven sync. Debounced — if a sync is
    /// already in-flight this is a no-op. Currently issues a raw
    /// `CKFetchRecordZoneChangesOperation` for reachability + status;
    /// the Phase 2 CKSyncEngine migration replaces this entirely with
    /// `CopiedSyncEngine.shared.syncNow()`.
    public func triggerSync() {
        if case .syncing = status { return }
        status = .syncing(direction: "Syncing…")
        runRawZoneFetch()
    }

    private func runRawZoneFetch() {
        let container = CKContainer(identifier: containerIdentifier)
        let db = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )
        op.qualityOfService = .userInitiated

        op.fetchRecordZoneChangesResultBlock = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failure(let err) = result {
                    self.status = .error(String(err.localizedDescription.prefix(60)))
                    return
                }
                // Give the mirror ~1.5s to drain any imports our poke
                // kicked loose. A real `.import` event will have already
                // flipped status to `.synced(date)` via handleCloudKitEvent;
                // if not, fall back to `.available` rather than claim a
                // sync that didn't happen.
                try? await Task.sleep(for: .milliseconds(1500))
                if case .syncing = self.status {
                    self.status = .available
                }
                SyncTicker.shared.bump()
            }
        }

        db.add(op)
    }
}
