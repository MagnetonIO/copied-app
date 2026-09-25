import Foundation
import CloudKit

/// Saves a share-extension capture directly to Copied's private CloudKit zone.
/// The App Group inbox remains the local source of truth and fallback; this
/// upload lets other devices receive the clipping without waiting for the host
/// iOS app to launch and drain that inbox.
public enum SharedClippingCloudUploader {
    @MainActor
    public static func makeRecord(
        from pending: SharedStore.PendingClipping,
        deviceName: String
    ) -> CKRecord {
        let clipping = Clipping(
            text: pending.text,
            title: pending.title,
            url: pending.url,
            deviceName: pending.deviceName ?? deviceName
        )
        clipping.clippingID = pending.id
        clipping.addDate = pending.createdAt
        clipping.modifiedDate = pending.createdAt

        if let imageData = pending.imageData {
            clipping.imageData = imageData
            clipping.hasImage = true
            clipping.imageByteCount = imageData.count
            clipping.imageFormat = ClipboardService.detectedImageFormat(from: imageData) ?? "tiff"
        }

        clipping.contentHash = clipping.computeContentHash()
        let record = CKRecord(
            recordType: CopiedSyncEngine.RecordType.clipping,
            recordID: CopiedSyncEngine.clippingRecordID(pending.id)
        )
        CKRecordMapper.populate(record, from: clipping)
        return record
    }

    @MainActor
    public static func upload(
        _ pending: SharedStore.PendingClipping,
        deviceName: String
    ) async throws {
        let database = CKContainer(identifier: CopiedSchema.containerIdentifier).privateCloudDatabase
        let record = makeRecord(from: pending, deviceName: deviceName)

        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            _ = try await database.save(CKRecordZone(zoneID: CopiedSyncEngine.zoneID))
            _ = try await database.save(record)
        }
    }
}
