#if os(macOS)
import Testing
@testable import CopiedKit

@Suite("Mac update channel")
struct MacUpdateChannelTests {
    @Test("Direct download is the default")
    func defaultsToDirectDownload() {
        #expect(MacUpdateChannel.detect(directoryExists: { _ in false }) == .directDownload)
    }

    @Test("Apple Silicon Homebrew cask is detected")
    func detectsAppleSiliconHomebrew() {
        #expect(MacUpdateChannel.detect(directoryExists: {
            $0 == "/opt/homebrew/Caskroom/copied"
        }) == .homebrew)
    }

    @Test("Intel Homebrew cask is detected")
    func detectsIntelHomebrew() {
        #expect(MacUpdateChannel.detect(directoryExists: {
            $0 == "/usr/local/Caskroom/copied"
        }) == .homebrew)
    }
}
#endif
