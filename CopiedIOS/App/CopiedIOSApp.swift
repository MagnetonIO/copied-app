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
        #if MAS_STOREFRONT
        // Start the Transaction.updates listener immediately so Ask-to-Buy
        // approvals, refunds, and revocations that arrive after launch are
        // caught. PurchaseManager also re-verifies current entitlements async
        // and flips `iCloudSyncPurchased` if the cached value disagrees with
        // StoreKit. The user is prompted to restart on next settings visit.
        _ = PurchaseManager.shared
        #endif

        // Register for remote notifications so CloudKit's silent pushes
        // can wake the app when another device modifies a record. Without
        // this, continuous sync silently degrades to "only on cold launch".
        // This is safe even without a real APNs token — the token comes
        // back to NSPersistentCloudKitContainer internally via its push
        // listener.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
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
