import SwiftData
import Foundation
import CloudKit

public enum CopiedSchema {
    /// Capitalized "Copied" so iOS Settings → iCloud Storage displays
    /// the brand-cased label. Must match an iCloud container identifier
    /// created in the Apple Developer portal and listed in every
    /// target's `com.apple.developer.icloud-container-identifiers`
    /// entitlement. Prior identifier `iCloud.com.mlong.copied` is dead
    /// — any data there is orphaned and can be deleted from the
    /// portal or iOS Settings.
    public static let containerIdentifier = "iCloud.com.mlong.Copied"

    public static let models: [any PersistentModel.Type] = [
        Clipping.self,
        ClipList.self,
        Asset.self
    ]

    public static func makeContainer(inMemory: Bool = false, cloudSync: Bool = true) throws -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            // Phase 7 cutover point: flip to `.none` unconditionally to
            // disable NSPersistentCloudKitContainer's automatic mirror.
            // CKSyncEngine (CopiedSyncEngine.shared) then becomes the
            // sole sync layer. Left enabled during early verification
            // of the CKSyncEngine migration so the app has a fallback
            // if the new engine misbehaves — pending a round of real
            // two-device testing before the flip.
            cloudKitDatabase: cloudSync ? .private(containerIdentifier) : .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
