import SwiftData
import Foundation

@Model
public final class ClipList {
    public var listID: String = UUID().uuidString

    public var name: String = ""
    public var colorHex: Int = 0x007AFF // default blue
    public var sortOrder: Int = 0
    public var isDefault: Bool = false
    public var isSmartList: Bool = false
    public var smartPredicate: String?

    public var createdDate: Date = Date()
    public var modifiedDate: Date?

    @Relationship(deleteRule: .nullify, inverse: \Clipping.list)
    public var clippings: [Clipping]?

    public init(name: String, colorHex: Int = 0x007AFF) {
        self.listID = UUID().uuidString
        self.name = name
        self.colorHex = colorHex
        self.createdDate = Date()
    }
}

extension ClipList {
    public var clippingCount: Int { clippings?.count ?? 0 }

    /// Soft-delete every clipping in the list, then delete the list itself.
    /// Called from both iOS (swipe-trailing) and Mac (context menu) so the
    /// semantics stay identical: users recover items from Trash, not from
    /// a phantom "deleted list" sidebar.
    @MainActor
    public func deleteTrashingClippings(in context: ModelContext) {
        for clipping in clippings ?? [] {
            clipping.moveToTrash()
        }
        context.delete(self)
        try? context.save()
    }
}
