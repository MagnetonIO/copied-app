import CopiedKit
import SwiftUI

enum SharedIOSData {
    static let requiresRelaunchForSync = false
}

@main
struct IOSCaptureApp: App {
    init() {
        UserDefaults.standard.set(false, forKey: PurchaseManager.purchasedKey)
        UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SyncScreen()
            }
            .preferredColorScheme(.dark)
        }
    }
}
