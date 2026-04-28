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

/// Receives APNs silent-push callbacks and forwards them to CKSyncEngine
/// so inbound CloudKit changes fetch without requiring the user to open
/// the app. Without this hook, `UIApplication.registerForRemoteNotifications()`
/// succeeds but pushes arrive and are discarded — the engine only syncs
/// on launch / foreground, which is why the user saw "nothing syncs on
/// iOS" until the app was refocused.
final class CopiedIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await CopiedSyncEngine.shared.fetchChanges()
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NSLog("[CopiedIOSApp] registered for remote notifications, token=\(deviceToken.count) bytes")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[CopiedIOSApp] remote notification registration failed: \(error.localizedDescription)")
    }
}

@main
struct CopiedIOSApp: App {
    @UIApplicationDelegateAdaptor(CopiedIOSAppDelegate.self) private var appDelegate
    @State private var clipboardService = ClipboardService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Tighter defaults for v1.3.0 — match the Mac side. `register`
        // only applies when the key was never set, so users with explicit
        // choices keep them. One-shot `didApplyV130CleanupV3` below forces
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

        // Pre-warm CopiedSyncEngine.shared OFF the SwiftUI render path.
        // Without this, the first SwiftUI body that touches .shared (in our
        // case a ScenePhase.active onChange that calls
        // ClipboardService.checkForPasteboardChanges → insertOrMerge → .shared)
        // triggers dispatch_once → CKContainer.init → CKOncePerBoot, which
        // synchronously posts an NSNotification → SwiftUI's UserDefaultObserver
        // tries to grab the SwiftUI MovableLock that the main thread is
        // already holding mid-render → 8s deadlock → FrontBoard SIGKILL.
        // Touching .shared here, before App.body ever runs, makes
        // dispatch_once complete on a background dispatcher safely.
        Task.detached(priority: .userInitiated) {
            _ = CopiedSyncEngine.shared
        }

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
                    guard !UserDefaults.standard.bool(forKey: "didApplyV130CleanupV3") else { return }
                    UserDefaults.standard.set(500, forKey: "maxHistorySize")
                    UserDefaults.standard.set(30, forKey: "retentionDays")
                    UserDefaults.standard.set(30, forKey: "trashRetentionDays")
                    let ctx = ModelContext(SharedIOSData.container)
                    clipboardService.purgeEmptyClippings(in: ctx)
                    UserDefaults.standard.set(true, forKey: "didApplyV130CleanupV3")
                }
        }
        .modelContainer(SharedIOSData.container)
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                // Forcing a process-pending-changes on foreground catches any
                // CloudKit imports that arrived while backgrounded.
                SharedIOSData.container.mainContext.processPendingChanges()
                // Two-pronged fetch:
                //   1. syncNow() drives CKSyncEngine through its normal path
                //      (incremental token, observed records).
                //   2. manualInboundFetch() bypasses CKSyncEngine and uses
                //      CKFetchRecordZoneChangesOperation directly with our
                //      own change token — same pattern as the Mac side. This
                //      catches changes that CKSyncEngine misses when its
                //      subscription state is stale (notably right after a
                //      bundle ID change, app reinstall, or CloudKit
                //      Production wipe — none of which CKSyncEngine resyncs
                //      on its own without a silent push).
                Task.detached {
                    await CopiedSyncEngine.shared.syncNow()
                    await CopiedSyncEngine.shared.manualInboundFetch(source: "ios.scenePhase.active")
                }
            }
        }
    }
}
