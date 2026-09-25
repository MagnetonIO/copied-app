import Testing
import CloudKit
@testable import CopiedKit

@Suite("Share extension CloudKit upload")
@MainActor
struct SharedClippingCloudUploaderTests {
    @Test("Pending share maps to the canonical clipping record")
    func pendingShareRecord() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = SharedStore.PendingClipping(
            id: "share-test-id",
            createdAt: createdAt,
            text: "Shared note",
            url: "https://example.com",
            title: "Example",
            source: .share
        )

        let record = SharedClippingCloudUploader.makeRecord(
            from: pending,
            deviceName: "Test iPhone"
        )

        #expect(record.recordType == CopiedSyncEngine.RecordType.clipping)
        #expect(record.recordID == CopiedSyncEngine.clippingRecordID("share-test-id"))
        #expect(record["text"] as? String == "Shared note")
        #expect(record["url"] as? String == "https://example.com")
        #expect(record["title"] as? String == "Example")
        #expect(record["deviceName"] as? String == "Test iPhone")
        #expect(record["addDate"] as? Date == createdAt)
        #expect((record["contentHash"] as? String)?.isEmpty == false)
    }
}
