import Foundation
import Security

/// Persists a verified Stripe license JWT in the macOS Keychain so the unlock
/// survives app reinstall (Keychain entries outlive the app bundle). Paired
/// with `UserDefaults("iCloudSyncPurchased")` which is the fast-path flag the
/// rest of the app reads — Keychain is the source of truth; UserDefaults is
/// a mirror maintained by this store.
public enum LicenseStore {
    private static let service = "com.mlong.copied.license"
    private static let account = "icloud-sync"
    private static let purchasedFlagKey = "iCloudSyncPurchased"

    /// Verify a license, and if valid, persist it + flip the purchased flag.
    /// Returns the decoded payload on success.
    @discardableResult
    public static func storeAndVerify(license: String) throws -> LicenseValidator.LicensePayload {
        let payload = try LicenseValidator.verify(license: license)
        try save(license: license)
        UserDefaults.standard.set(true, forKey: purchasedFlagKey)
        return payload
    }

    /// Re-check the Keychain on launch. Mirrors the result into UserDefaults
    /// so the rest of the app can gate sync off a plain bool without touching
    /// Keychain on the hot path.
    @discardableResult
    public static func refreshFromKeychain() -> Bool {
        guard let license = load(), let _ = try? LicenseValidator.verify(license: license) else {
            UserDefaults.standard.set(false, forKey: purchasedFlagKey)
            return false
        }
        UserDefaults.standard.set(true, forKey: purchasedFlagKey)
        return true
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: purchasedFlagKey)
    }

    // MARK: - Keychain primitives

    private static func save(license: String) throws {
        guard let data = license.data(using: .utf8) else { throw NSError(domain: service, code: -1) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: service, code: Int(status)) }
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
