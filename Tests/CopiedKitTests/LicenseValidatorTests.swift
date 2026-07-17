import CryptoKit
import Foundation
import Testing
@testable import CopiedKit

@Suite("License Validator")
struct LicenseValidatorTests {
    @Test("Accepts production Stripe license product")
    func acceptsProductionStripeLicenseProduct() throws {
        let fixture = try LicenseFixture(product: "copied-mac-icloud")

        let payload = try LicenseValidator.verify(
            license: fixture.license,
            publicKeyHex: fixture.publicKeyHex
        )

        #expect(payload.product == "copied-mac-icloud")
        #expect(payload.email == "customer@example.com")
        #expect(payload.deviceLimit == 3)
    }

    @Test("Rejects unknown signed license product")
    func rejectsUnknownSignedLicenseProduct() throws {
        let fixture = try LicenseFixture(product: "other-product")

        #expect(throws: LicenseValidator.VerifyError.wrongProduct) {
            try LicenseValidator.verify(
                license: fixture.license,
                publicKeyHex: fixture.publicKeyHex
            )
        }
    }
}

private struct LicenseFixture {
    let license: String
    let publicKeyHex: String

    init(product: String) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = LicensePayload(
            product: product,
            email: "customer@example.com",
            purchasedAt: Date(timeIntervalSince1970: 1_781_956_800),
            deviceLimit: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)
        let signature = try privateKey.signature(for: payloadData)

        license = "\(payloadData.base64URLEncoded).\(signature.base64URLEncoded)"
        publicKeyHex = privateKey.publicKey.rawRepresentation.hexEncoded
    }

    private struct LicensePayload: Encodable {
        let product: String
        let email: String
        let purchasedAt: Date
        let deviceLimit: Int
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
