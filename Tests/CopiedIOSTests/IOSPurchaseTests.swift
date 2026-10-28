import Foundation
import StoreKitTest
import Testing
import UIKit
import CopiedKit
@testable import Copied

@MainActor
@Suite("iOS StoreKit-only unlock", .serialized)
struct IOSPurchaseTests {
    private let session: SKTestSession

    init() throws {
        let url = try #require(Bundle(for: ResourceLocator.self).url(forResource: "Copied", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        try #require(session.disableDialogs, "StoreKit testing must be active; do not fall back to the real sandbox")
        session.clearTransactions()
        UserDefaults.standard.removeObject(forKey: "_skipStoreKitReconcile")
        UserDefaults.standard.removeObject(forKey: PurchaseManager.purchasedKey)
        UserDefaults.standard.removeObject(forKey: "iCloudSyncPurchased")
        UserDefaults.standard.set(true, forKey: "cloudSyncEnabled")
        SharedStore.updateExtensionCloudSyncAccess(purchased: false, enabled: true)
    }

    @Test("A legacy license cache cannot unlock sync before StoreKit reconciliation")
    func ignoresLegacyLicenseCache() async {
        let manager = PurchaseManager.shared
        await manager.refreshEntitlements()
        UserDefaults.standard.set(true, forKey: "iCloudSyncPurchased")
        SharedStore.defaults.set(true, forKey: "extensionCloudSyncPurchased")

        #expect(!manager.isPremium)
        #expect(!SharedIOSData.requiresRelaunchForSync)
        #expect(!SharedStore.extensionCloudSyncEnabled)
    }

    @Test("An App Store purchase unlocks sync for the app and extensions")
    func purchasesSync() async throws {
        let manager = PurchaseManager.shared
        await manager.refreshEntitlements()
        await manager.loadProduct()
        let product = try #require(manager.product)
        #expect(product.id == "com.magneton.copied.icloud_sync")
        try await waitForPurchaseWindow()

        let purchased = await manager.purchase()

        #expect(purchased)
        #expect(manager.isPremium)
        #expect(SharedStore.extensionCloudSyncEnabled)
        #expect(SharedIOSData.requiresRelaunchForSync)
    }

    @Test("Restore Purchases restores a StoreKit entitlement without a license")
    func restoresSync() async throws {
        let manager = PurchaseManager.shared
        _ = try await session.buyProduct(identifier: "com.magneton.copied.icloud_sync")
        await manager.refreshEntitlements()
        UserDefaults.standard.set(false, forKey: PurchaseManager.purchasedKey)
        SharedStore.updateExtensionCloudSyncAccess(purchased: false, enabled: true)

        let restored = await manager.restore()

        #expect(restored)
        #expect(manager.isPremium)
        #expect(SharedStore.extensionCloudSyncEnabled)
    }

    @Test("Without an App Store entitlement, restore leaves sync locked")
    func restoreWithoutPurchaseStaysLocked() async {
        let manager = PurchaseManager.shared
        await manager.refreshEntitlements()

        let restored = await manager.restore()

        #expect(!restored)
        #expect(!manager.isPremium)
        #expect(!SharedStore.extensionCloudSyncEnabled)
    }

    @Test("Refunded StoreKit purchases no longer unlock sync")
    func refundedPurchaseStaysLocked() async throws {
        let manager = PurchaseManager.shared
        let transaction = try await session.buyProduct(identifier: "com.magneton.copied.icloud_sync")
        await manager.refreshEntitlements()
        #expect(manager.isPremium)

        try session.refundTransaction(identifier: UInt(transaction.id))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            await manager.refreshEntitlements()
            if !manager.isPremium && !SharedStore.extensionCloudSyncEnabled { break }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline

        #expect(!manager.isPremium)
        #expect(!SharedStore.extensionCloudSyncEnabled)
    }

    private func waitForPurchaseWindow() async throws {
        func hasWindow() -> Bool {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .contains { scene in
                    scene.activationState == .foregroundActive && scene.windows.contains { $0.isKeyWindow }
                }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !hasWindow() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(hasWindow(), "StoreKit purchase requires a visible foreground app window")
    }
}

private final class ResourceLocator: NSObject {}
