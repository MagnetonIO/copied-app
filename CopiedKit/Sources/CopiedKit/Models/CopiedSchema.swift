import SwiftData
import Foundation
import CloudKit

public enum CopiedSchema {
    public static let containerIdentifier = "iCloud.com.mlong.copied"

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
            cloudKitDatabase: cloudSync ? .private(containerIdentifier) : .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
