import SwiftUI
import SwiftData
import UIKit
import CopiedKit

/// Shared container — same gating logic as the Mac MAS build. The
/// `iCloudSyncPurchased` and `cloudSyncEnabled` UserDefaults keys round-trip
/// via `NSUbiquitousKeyValueStore`, so a user who's unlocked on Mac sees it
/// on iOS (and vice versa) without a second purchase.
enum SharedIOSData {
    /// Snapshot of the cloudSync gate at container-construction time.
    /// `requiresRelaunchForSync` compares this to live state to decide
    /// whether the user needs to restart the app for a purchase/restore/
    /// license unlock to actually start using CloudKit.
    @MainActor
    static let initialCloudSyncEnabled: Bool = computeCloudSyncEnabled()

    @MainActor
    private static func computeCloudSyncEnabled() -> Bool {
        let userToggle = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        #if MAS_BUILD
        let purchased = UserDefaults.standard.bool(forKey: "iCloudSyncPurchased")
        return userToggle && purchased
        #else
        return userToggle
        #endif
    }

    /// True when the purchase / toggle state has changed since the
    /// container was built — meaning writes are still going to a
    /// local-only store and the user needs to force-quit and reopen
    /// for iCloud sync to kick in. Surfaced in `SyncScreen` as a banner.
    @MainActor
    static var requiresRelaunchForSync: Bool {
        computeCloudSyncEnabled() != initialCloudSyncEnabled
    }

    @MainActor
    static let container: ModelContainer = {
        let cloudSyncEnabled = initialCloudSyncEnabled
        do {
            return try CopiedSchema.makeContainer(cloudSync: cloudSyncEnabled)
        } catch {
            NSLog("CloudKit container failed: \(error). Falling back to local-only.")
            do {
                return try CopiedSchema.makeContainer(cloudSync: false)
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }()
}

@main
struct CopiedIOSApp: App {
    @State private var clipboardService = ClipboardService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Tighter defaults for v1.3.0 — match the Mac side. `register`
        // only applies when the key was never set, so users with explicit
        // choices keep them. One-shot `didApplyV130Cleanup` below forces
        // new values + sweeps Empty Clipping rows.
        UserDefaults.standard.register(defaults: [
            "maxHistorySize": 500,
            "retentionDays": 30,
            "trashRetentionDays": 30
        ])

        #if MAS_STOREFRONT
        // Start the Transaction.updates listener immediately so Ask-to-Buy
        // approvals, refunds, and revocations that arrive after launch are
        // caught. PurchaseManager also re-verifies current entitlements async
        // and flips `iCloudSyncPurchased` if the cached value disagrees with
        // StoreKit. The user is prompted to restart on next settings visit.
        _ = PurchaseManager.shared
        #endif

        // One-shot v1.3.0 cleanup runs in `body`'s `.task` below — Swift
        // structs can't capture `self` into escaping closures from `init`.

        // Register for remote notifications so CloudKit's silent pushes
        // can wake the app when another device modifies a record. Without
        // this, continuous sync silently degrades to "only on cold launch".
        // This is safe even without a real APNs token — the token comes
        // back to NSPersistentCloudKitContainer internally via its push
        // listener.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }

        // CKSyncEngine (iOS 17+) — replaces NSPCKC automatic mirroring.
        // Starts only when the user's cloudSync gate is on. iOS doesn't
        // currently bind SyncScreen to a SyncMonitor instance; it'll
        // pull engine state directly via `CopiedSyncEngine.shared.*`
        // once SyncScreen is updated in Phase 5+.
        Task { @MainActor in
            if SharedIOSData.initialCloudSyncEnabled {
                CopiedSyncEngine.shared.start(modelContainer: SharedIOSData.container)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environment(clipboardService)
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    // CloudKit just imported changes. Ping the main context
                    // so SwiftData @Query observers re-evaluate their
                    // predicates (iOS 18+ sometimes misses field-update
                    // imports for soft-deletes like `deleteDate = now`).
                    SharedIOSData.container.mainContext.processPendingChanges()
                }
                .task {
                    // One-shot v1.3.0 cleanup — tighten retention defaults
                    // + purge Empty Clipping rows. Matches Mac side.
                    guard !UserDefaults.standard.bool(forKey: "didApplyV130Cleanup") else { return }
                    UserDefaults.standard.set(500, forKey: "maxHistorySize")
                    UserDefaults.standard.set(30, forKey: "retentionDays")
                    UserDefaults.standard.set(30, forKey: "trashRetentionDays")
                    let ctx = ModelContext(SharedIOSData.container)
                    clipboardService.purgeEmptyClippings(in: ctx)
                    UserDefaults.standard.set(true, forKey: "didApplyV130Cleanup")
                }
        }
        .modelContainer(SharedIOSData.container)
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                // Forcing a process-pending-changes on foreground catches any
                // CloudKit imports that arrived while backgrounded — the
                // common path for "Mac deleted a clipping, iPhone came
                // back and still shows it" reports.
                SharedIOSData.container.mainContext.processPendingChanges()
            }
        }
    }
}
