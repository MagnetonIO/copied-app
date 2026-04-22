import Foundation
import CryptoKit

/// Offline verifier for Stripe-issued license keys. The private key lives on
/// the webhook server that runs after `checkout.session.completed`; the public
/// key is baked into the app below. No network calls — verification is
/// Ed25519 signature check + JSON decode.
///
/// License format: `<base64url(payload_json)>.<base64url(sig)>`
/// Signature: Ed25519 over the raw payload bytes (not the base64 string).
public enum LicenseValidator {
    /// Ed25519 public key (raw 32 bytes, hex). Matches `.keys/license/signing.pub.pem`.
    /// Regenerate both halves together; private half is gitignored under `.keys/`.
    static let publicKeyHex = "47cbf96653e629edc20829ec4eb3c83e3f01fd52035b728c1d0d73e328e65b3a"

    public struct LicensePayload: Codable, Sendable {
        public let product: String
        public let email: String
        public let purchasedAt: Date
        public let deviceLimit: Int
    }

    public enum VerifyError: Error {
        case malformed
        case badSignature
        case badPayload
    }

    public static func verify(license: String) throws -> LicensePayload {
        let parts = license.split(separator: ".")
        guard parts.count == 2,
              let payloadData = Data(base64URLEncoded: String(parts[0])),
              let signatureData = Data(base64URLEncoded: String(parts[1])),
              let publicKeyBytes = Data(hex: publicKeyHex)
        else { throw VerifyError.malformed }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw VerifyError.badSignature
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(LicensePayload.self, from: payloadData)
        } catch {
            throw VerifyError.badPayload
        }
    }
}

// MARK: - Helpers

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    init?(base64URLEncoded: String) {
        var s = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !s.count.isMultiple(of: 4) { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
