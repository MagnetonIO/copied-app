#if os(macOS)
import Foundation

public struct HomebrewUpdateService: Sendable {
    public struct Update: Equatable, Sendable {
        public let version: String
        public let isOutdated: Bool
    }

    public typealias Runner = @Sendable (String, [String]) async throws -> Data
    private let executable: String
    private let run: Runner

    public init(executable: String, run: @escaping Runner = Self.runCommand) {
        self.executable = executable
        self.run = run
    }

    public func check() async throws -> Update {
        _ = try await run(executable, ["update", "--quiet"])
        let data = try await run(executable, ["info", "--cask", "--json=v2", "magnetonio/tap/copied"])
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> Update {
        struct Info: Decodable {
            struct Cask: Decodable {
                let full_token: String
                let version: String
                let installed: String?
                let outdated: Bool
            }
            let casks: [Cask]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard let cask = info.casks.first(where: { $0.full_token == "magnetonio/tap/copied" }),
              cask.installed != nil else {
            throw CheckError.notInstalled
        }
        return Update(version: cask.version, isOutdated: cask.outdated)
    }

    public static func executable(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        receiptExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let prefixes = ["/opt/homebrew", "/usr/local"]
        return prefixes.first(where: {
            receiptExists("\($0)/Caskroom/copied") && exists("\($0)/bin/brew")
        }).map { "\($0)/bin/brew" }
    }

    public static func runCommand(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try runBlocking(executable, arguments)
        }.value
    }

    private static func runBlocking(_ executable: String, _ arguments: [String]) throws -> Data {
        // Files avoid pipe-buffer deadlocks while brew refreshes taps. Never run
        // upgrade here: this worker has no terminal for installer authorization.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(URL(fileURLWithPath: executable).deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw CheckError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? ""
            throw CheckError.commandFailed(String(detail.suffix(1200)))
        }
        return try Data(contentsOf: outputURL)
    }

    private enum CheckError: LocalizedError {
        case notInstalled, timedOut, commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Copied is not registered as installed in Homebrew."
            case .timedOut: "Homebrew took too long to respond. Try again."
            case .commandFailed(let detail): "Homebrew could not check for updates. \(detail)"
            }
        }
    }
}
#endif
