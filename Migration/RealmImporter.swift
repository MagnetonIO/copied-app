import Foundation
import SwiftData

// MARK: - Realm Binary Reader
// Reads Clipping objects directly from the existing Realm database
// without requiring the Realm framework — parses the SQLite-backed Realm file.
//
// NOTE: This is a REFERENCE IMPLEMENTATION. For production use, add the
// Realm Swift package temporarily and use the proper Realm API to read,
// then remove it. The approach below documents the schema for migration.
//
// To use with Realm Swift (recommended for actual import):
//
// 1. Add to Package.swift: .package(url: "https://github.com/realm/realm-swift", from: "10.0.0")
// 2. Import and read:
//
//   import RealmSwift
//
//   class LegacyClipping: Object {
//       @Persisted(primaryKey: true) var clippingID: String = ""
//       @Persisted var text: String?
//       @Persisted var customTitle: String?
//       @Persisted var url: String?
//       @Persisted var sourceURL: String?
//       @Persisted var image: Data?
//       @Persisted var copiedStyle: String?
//       @Persisted var addDate: Date?
//       @Persisted var copiedDate: Date?
//       @Persisted var deleteDate: Date?
//       @Persisted var modifiedDate: Date?
//       @Persisted var deviceName: String?
//       @Persisted var appName: String?
//       @Persisted var types: String?
//       @Persisted var isFavorite: Bool
//       @Persisted var listIndex: Int
//       @Persisted var imageWidth: Double
//       @Persisted var imageHeight: Double
//       @Persisted var sync: Bool
//   }
//
//   class LegacyList: Object {
//       @Persisted(primaryKey: true) var listID: String = ""
//       @Persisted var name: String = ""
//       @Persisted var color: Int = 0
//       @Persisted var sortBy: Int = 0
//       @Persisted var index: Int = 0
//   }

/// Schema mapping from old Copied Realm → new SwiftData models.
public enum RealmImporter {

    /// Path to the existing Copied Realm database.
    public static let realmPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/3DZ6694B2C.group.udoncode.copied/copied.realm")

    /// Path to the existing assets directory.
    public static let assetsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/3DZ6694B2C.group.udoncode.copied/assets")

    /// Import the last N clippings from the existing Realm database.
    ///
    /// Call this with a temporary Realm dependency, then remove it.
    /// This function documents the field mapping.
    public static func importFieldMapping() -> [(old: String, new: String)] {
        [
            ("clippingID", "clippingID"),
            ("text", "text"),
            ("customTitle", "title"),
            ("url", "url"),
            ("urlSource", "sourceURL"),  // renamed
            ("image", "imageData"),
            ("copiedStyle", "richTextData"),  // repurposed
            ("addDate", "addDate"),
            ("copiedDate", "copiedDate"),
            ("deleteDate", "deleteDate"),
            ("modifiedDate", "modifiedDate"),
            ("deviceName", "deviceName"),
            ("appName", "appName"),
            ("types", "types → split by comma"),
            ("pasteboardIndex", "listIndex"),
            ("imageWidth", "imageWidth"),
            ("imageHeight", "imageHeight"),
        ]
    }

    /// After adding Realm Swift temporarily, call this to perform the actual import.
    ///
    /// ```swift
    /// let modelContext = ModelContext(container)
    /// try await RealmImporter.performImport(into: modelContext, limit: 500)
    /// ```
    ///
    /// Implementation sketch (requires Realm Swift):
    ///
    /// ```swift
    /// public static func performImport(into context: ModelContext, limit: Int = 500) throws {
    ///     let config = Realm.Configuration(
    ///         fileURL: realmPath,
    ///         readOnly: true,
    ///         schemaVersion: 999,
    ///         migrationBlock: { _, _ in }
    ///     )
    ///     let realm = try Realm(configuration: config)
    ///
    ///     // Import lists first
    ///     let legacyLists = realm.objects(LegacyList.self)
    ///     var listMap: [String: ClipList] = [:]
    ///     for legacyList in legacyLists {
    ///         let list = ClipList(name: legacyList.name, colorHex: legacyList.color)
    ///         list.listID = legacyList.listID
    ///         list.sortOrder = legacyList.index
    ///         context.insert(list)
    ///         listMap[legacyList.listID] = list
    ///     }
    ///
    ///     // Import last N clippings (sorted by addDate descending)
    ///     let legacyClippings = realm.objects(LegacyClipping.self)
    ///         .sorted(byKeyPath: "addDate", ascending: false)
    ///         .prefix(limit)
    ///
    ///     for legacy in legacyClippings {
    ///         let clipping = Clipping()
    ///         clipping.clippingID = legacy.clippingID
    ///         clipping.text = legacy.text
    ///         clipping.title = legacy.customTitle
    ///         clipping.url = legacy.url
    ///         clipping.sourceURL = legacy.sourceURL
    ///         clipping.imageData = legacy.image
    ///         clipping.addDate = legacy.addDate ?? Date()
    ///         clipping.copiedDate = legacy.copiedDate
    ///         clipping.deleteDate = legacy.deleteDate
    ///         clipping.modifiedDate = legacy.modifiedDate
    ///         clipping.deviceName = legacy.deviceName ?? ""
    ///         clipping.appName = legacy.appName
    ///         clipping.imageWidth = legacy.imageWidth
    ///         clipping.imageHeight = legacy.imageHeight
    ///         clipping.types = legacy.types?.components(separatedBy: ",") ?? []
    ///
    ///         // TODO: map list relationship using listMap
    ///
    ///         context.insert(clipping)
    ///     }
    ///
    ///     try context.save()
    /// }
    /// ```
}
