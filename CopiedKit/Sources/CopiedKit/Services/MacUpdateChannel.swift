#if os(macOS)
import Foundation

public enum MacUpdateChannel: Equatable, Sendable {
    case directDownload
    case homebrew

    public static func detect(
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    ) -> MacUpdateChannel {
        let caskRoots = [
            "/opt/homebrew/Caskroom/copied",
            "/usr/local/Caskroom/copied"
        ]
        return caskRoots.contains(where: directoryExists) ? .homebrew : .directDownload
    }
}
#endif
