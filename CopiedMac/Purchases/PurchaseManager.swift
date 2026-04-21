#if MAS_BUILD
import Foundation
import StoreKit
import Observation

/// Wraps StoreKit 2 for the single non-consumable iCloud Sync unlock.
/// Compiled into MAS builds only (see SWIFT_ACTIVE_COMPILATION_CONDITIONS=MAS_BUILD
/// in fastlane/Fastfile mas_build/mas_debug_build lanes). The OSS/Developer-ID build
/// doesn't link StoreKit — CloudKit is always on there.
@Observable
@MainActor
public final class PurchaseManager {
    public static let shared = PurchaseManager()

    /// Keep in sync with the product record in App Store Connect and Copied.storekit.
    nonisolated public static let iCloudSyncProductID = "com.mlong.copied.icloud_sync"

    /// UserDefaults cache so `SharedData.container` can make a sync-or-not decision
    /// synchronously at app launch without awaiting StoreKit. Verified async on launch
    /// via `refreshEntitlements()`; if it disagrees, the user is prompted to restart.
    nonisolated public static let purchasedKey = "iCloudSyncPurchased"

    public private(set) var product: Product?
    public var isPremium: Bool {
        UserDefaults.standard.bool(forKey: Self.purchasedKey)
    }
    public private(set) var purchaseInFlight = false
    public private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
        Task { await refreshEntitlements() }
        Task { await loadProduct() }
    }

    // Singleton lifetime == app lifetime; no deinit needed. The Transaction.updates
    // listener is expected to run until the process exits.

    /// Fetch the product metadata (display price, localized name) from the App Store
    /// or the attached StoreKit config file (local dev).
    public func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.iCloudSyncProductID])
            self.product = products.first
        } catch {
            self.lastError = "Couldn't load product: \(error.localizedDescription)"
        }
    }

    /// Present the Apple Pay sheet. Returns true if the purchase succeeded and the
    /// premium flag is now set (caller can then prompt restart).
    @discardableResult
    public func purchase() async -> Bool {
        guard let product else {
            lastError = "Product not loaded"
            return false
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                setPremium(true)
                await transaction.finish()
                lastError = nil
                return true
            case .userCancelled:
                return false
            case .pending:
                // e.g. Ask to Buy approval required — premium stays off; listener will
                // catch the approval or rejection later.
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Hit the App Store to re-pull entitlements (for "Restore Purchases" button).
    @discardableResult
    public func restore() async -> Bool {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isPremium {
                lastError = nil
                return true
            } else {
                lastError = "No previous purchase found for this Apple ID."
                return false
            }
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Iterate `Transaction.currentEntitlements` and update the cached premium flag.
    /// Called at init (after cache-based boot) and after AppStore.sync().
    public func refreshEntitlements() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.iCloudSyncProductID,
                  transaction.revocationDate == nil else { continue }
            found = true
        }
        setPremium(found)
    }

    private func setPremium(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.purchasedKey)
    }

    /// Long-lived listener for post-launch purchases, Ask-to-Buy approvals, refunds,
    /// and revocations. Mutates the same UserDefaults flag; on mismatch vs. runtime
    /// CloudKit state the settings UI shows a restart prompt.
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result,
                      transaction.productID == Self.iCloudSyncProductID else { continue }
                await MainActor.run {
                    self?.setPremium(transaction.revocationDate == nil)
                }
                await transaction.finish()
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw PurchaseError.unverified
        case .verified(let value): return value
        }
    }
}

public enum PurchaseError: Error {
    case unverified
}
#endif
