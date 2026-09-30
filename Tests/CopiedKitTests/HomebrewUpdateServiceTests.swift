#if os(macOS)
import Foundation
import Testing
@testable import CopiedKit

@Suite("Homebrew update checks")
struct HomebrewUpdateServiceTests {
    @Test("Recognizes an outdated same-marketing-version build")
    func detectsBuildPatch() throws {
        let data = Data(#"{"casks":[{"full_token":"magnetonio/tap/copied","version":"1.3.3,14","installed":"1.3.3,13","outdated":true}]}"#.utf8)
        let update = try HomebrewUpdateService.parse(data)
        #expect(update.version == "1.3.3,14")
        #expect(update.isOutdated)
    }

    @Test("Recognizes an up-to-date cask")
    func upToDate() throws {
        let data = Data(#"{"casks":[{"full_token":"magnetonio/tap/copied","version":"1.3.3,14","installed":"1.3.3,14","outdated":false}]}"#.utf8)
        #expect(try !HomebrewUpdateService.parse(data).isOutdated)
    }

    @Test("Does not claim uninstalled or malformed casks are up to date")
    func rejectsMissingInstall() {
        for json in [
            #"{"casks":[]}"#,
            #"{"casks":[{"full_token":"magnetonio/tap/copied","version":"1.3.3,14","installed":null,"outdated":false}]}"#,
            #"{"casks":[{"full_token":"other/tap/copied","version":"1","installed":"1","outdated":false}]}"#,
            "invalid JSON"
        ] {
            #expect(throws: (any Error).self) { try HomebrewUpdateService.parse(Data(json.utf8)) }
        }
    }

    @Test("Uses the brew executable belonging to the cask receipt")
    func selectsReceiptPrefix() {
        #expect(HomebrewUpdateService.executable(exists: { _ in true }, receiptExists: {
            $0 == "/usr/local/Caskroom/copied"
        }) == "/usr/local/bin/brew")
        #expect(HomebrewUpdateService.executable(exists: { _ in false }, receiptExists: { _ in true }) == nil)
    }

    @Test("Refreshes Homebrew before querying only Copied; never installs during checks")
    func refreshThenQuery() async throws {
        actor Commands {
            var arguments: [[String]] = []
            func run(_ executable: String, _ args: [String]) throws -> Data {
                #expect(executable == "/opt/homebrew/bin/brew")
                arguments.append(args)
                if args.first == "update" { return Data() }
                #expect(arguments.count == 2)
                return Data(#"{"casks":[{"full_token":"magnetonio/tap/copied","version":"1.3.3,14","installed":"1.3.3,14","outdated":false}]}"#.utf8)
            }
        }
        let commands = Commands()
        let service = HomebrewUpdateService(executable: "/opt/homebrew/bin/brew") { path, args in
            try await commands.run(path, args)
        }
        #expect(try await !service.check().isOutdated)
        #expect(await commands.arguments == [
            ["update", "--quiet"], ["info", "--cask", "--json=v2", "magnetonio/tap/copied"]
        ])
    }

    @Test("Stops if refreshing Homebrew fails")
    func propagatesFailure() async {
        enum Failure: Error { case refresh }
        let service = HomebrewUpdateService(executable: "/opt/homebrew/bin/brew") { _, args in
            #expect(args == ["update", "--quiet"])
            throw Failure.refresh
        }
        await #expect(throws: Failure.self) { try await service.check() }
    }

    @Test("The process runner captures output and reports nonzero exit status")
    func realProcessRunner() async throws {
        let output = try await HomebrewUpdateService.runCommand("/usr/bin/printf", ["test-output"])
        #expect(String(data: output, encoding: .utf8) == "test-output")
        await #expect(throws: (any Error).self) {
            try await HomebrewUpdateService.runCommand("/usr/bin/false", [])
        }
    }
}
#endif
