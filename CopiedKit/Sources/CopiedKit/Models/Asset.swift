import SwiftData
import Foundation

@Model
public final class Asset {
    public var assetID: String = UUID().uuidString

    public var filename: String = ""
    public var uti: String = ""
    @Attribute(.externalStorage) public var data: Data?
    public var byteCount: Int = 0

    public var createdDate: Date = Date()
    public var modifiedDate: Date?

    public var clipping: Clipping?

    public init(filename: String, uti: String, data: Data?) {
        self.assetID = UUID().uuidString
        self.filename = filename
        self.uti = uti
        self.data = data
        self.byteCount = data?.count ?? 0
        self.createdDate = Date()
    }
}
