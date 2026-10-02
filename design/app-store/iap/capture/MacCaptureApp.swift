import CopiedKit
import SwiftData
import SwiftUI

// This isolated capture host never launches the production app delegate.
@MainActor
enum SharedData {
    static let requiresRelaunchForSync = false
    static let container = try! CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
}

@main
struct MacCaptureApp: App {
    init() {
        UserDefaults.standard.set(false, forKey: PurchaseManager.purchasedKey)
        UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
        SettingsNavigation.shared.selectedTab = 3
    }

    var body: some Scene {
        WindowGroup {
            SettingsView()
                .environment(ClipboardService())
                .environment(SyncMonitor())
                .modelContainer(SharedData.container)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}
