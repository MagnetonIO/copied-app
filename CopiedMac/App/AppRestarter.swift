#if MAS_BUILD
import AppKit
import Foundation

/// Auto-restart helper for the post-purchase flow.
///
/// SwiftData's CloudKit configuration is fixed at `ModelContainer` init, so flipping
/// the `iCloudSyncPurchased` flag doesn't activate sync live — the process must be
/// restarted. Rather than asking the user to manually quit + re-open, this helper
/// spawns a fresh instance of the app via Launch Services and terminates the current
/// one after the new instance reports it's launching. End-user perception: the window
/// briefly disappears and the app comes back with Sync active.
///
/// Before terminating we write `settingsTabOnNextOpen=3` (Sync tab) and
/// `_restartedFromPurchase=true`, which the next launch's AppDelegate reads to
/// automatically open the Settings window on the Sync tab so the user sees the
/// unlocked state immediately.
@MainActor
enum AppRestarter {
    static let restartedFromPurchaseKey = "_restartedFromPurchase"
    private static let syncTabTag = 3

    /// Call after a successful purchase or restore. Writes the one-shot flags that
    /// tell the next launch to open Settings → Sync, then relaunches the app.
    static func restartAfterPurchase() {
        UserDefaults.standard.set(syncTabTag, forKey: "settingsTabOnNextOpen")
        UserDefaults.standard.set(true, forKey: restartedFromPurchaseKey)
        UserDefaults.standard.synchronize()
        relaunch()
    }

    /// Spawns a new instance of the current app bundle via NSWorkspace with
    /// `createsNewApplicationInstance = true` so macOS allows the new process to start
    /// before the current one has fully exited, avoiding the user ever seeing "no Copied".
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
#endif
