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
    public static let containerIdentifier = "iCloud.com.magneton.Copied"

    public static let models: [any PersistentModel.Type] = [
        Clipping.self,
        ClipList.self,
        Asset.self
    ]

    public static func makeContainer(inMemory: Bool = false, cloudSync: Bool = true) throws -> ModelContainer {
        // NSPersistentCloudKitContainer mirror DISABLED — CKSyncEngine
        // (CopiedSyncEngine.shared) is the sole sync path. Passing
        // `.private(...)` here causes NSPCKC to run a parallel mirror
        // into the legacy `com.apple.coredata.cloudkit.zone`, generating
        // `cloudkit.activity.export` log spam and racing CKSyncEngine
        // for bandwidth/etag state. See plan Q1.
        //
        // `cloudSync` parameter retained for API compatibility but no
        // longer affects CloudKit mirroring — CopiedSyncEngine gates
        // on its own `initialCloudSyncEnabled`.
        _ = cloudSync
        let schema = Schema(models)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
