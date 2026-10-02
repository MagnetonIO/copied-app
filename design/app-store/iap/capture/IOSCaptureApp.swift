import CopiedKit
import SwiftUI

enum SharedIOSData {
    static let requiresRelaunchForSync = false
}

@main
struct IOSCaptureApp: App {
    @State private var presentsLicenseEntry = false
    @State private var licenseBanner: String?

    init() {
        UserDefaults.standard.set(false, forKey: PurchaseManager.purchasedKey)
        UserDefaults.standard.set(false, forKey: "cloudSyncEnabled")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SyncScreen(presentsLicenseEntry: $presentsLicenseEntry,
                           licenseBanner: $licenseBanner)
            }
            .preferredColorScheme(.dark)
        }
    }
}
