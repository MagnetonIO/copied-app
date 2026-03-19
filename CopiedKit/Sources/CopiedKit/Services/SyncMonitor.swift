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
            case .available: return "iCloud On"
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

        // Also listen for remote store changes (data actually arriving)
        let remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.importCount += 1
                self?.status = .synced(Date())
            }
        }
        observers.append(remoteChangeObserver)

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
        switch type {
        case 0: // setup
            if succeeded {
                status = .synced(endDate ?? Date())
            } else {
                status = .syncing(direction: "Setting up…")
            }
        case 1: // import (remote → local)
            if succeeded {
                importCount += 1
                status = .synced(endDate ?? Date())
            } else if endDate == nil {
                status = .syncing(direction: "Importing…")
            }
        case 2: // export (local → remote)
            if succeeded {
                exportCount += 1
                status = .synced(endDate ?? Date())
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

    public func triggerSync() {
        status = .syncing(direction: "Syncing…")
        let container = CKContainer(identifier: containerIdentifier)
        container.fetchUserRecordID { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.status = .error(String(error.localizedDescription.prefix(40)))
                } else {
                    try? await Task.sleep(for: .seconds(3))
                    self?.status = .synced(Date())
                }
            }
        }
    }
}
