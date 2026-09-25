#if DIRECT_DOWNLOAD
import AppKit
import CopiedKit
import Sparkle

@MainActor
final class UpdateManager {
    static let shared = UpdateManager()
    static let homebrewUpgradeCommand = "brew upgrade --cask magnetonio/tap/copied"

    let channel: MacUpdateChannel
    private let updaterController: SPUStandardUpdaterController?

    private init() {
        channel = MacUpdateChannel.detect()

        guard channel == .directDownload else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        updaterController = controller
        controller.startUpdater()
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set { updaterController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func copyHomebrewUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewUpgradeCommand, forType: .string)
    }
}
#endif
