#if DIRECT_DOWNLOAD
import AppKit
import CopiedKit
import Observation
import Sparkle

enum MacUpdateStatus: Equatable {
    case idle, checking, upToDate
    case available(String), failed(String), unavailable(String)
}

@MainActor
@Observable
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()
    static let homebrewUpgradeCommand = "brew upgrade --cask magnetonio/tap/copied"

    let channel: MacUpdateChannel
    private(set) var status: MacUpdateStatus = .idle
    private(set) var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false {
        didSet { updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { updaterController?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?

    init(channel: MacUpdateChannel = MacUpdateChannel.detect(), startUpdater: Bool = true) {
        self.channel = channel
        super.init()

        guard channel == .directDownload else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updaterController = controller
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = available }
        }
        if startUpdater { controller.startUpdater() }
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = .checking
        if channel == .directDownload {
            updaterController?.checkForUpdates(nil)
        } else {
            canCheckForUpdates = false
            Task {
                defer { canCheckForUpdates = true }
                guard let executable = HomebrewUpdateService.executable() else {
                    status = .failed("Homebrew could not be found for this installation.")
                    return
                }
                do {
                    let update = try await HomebrewUpdateService(executable: executable).check()
                    status = update.isOutdated ? .available(update.version.replacingOccurrences(of: ",", with: " build ")) : .upToDate
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func installHomebrewUpdate() {
        guard channel == .homebrew, case .available = status,
              let executable = HomebrewUpdateService.executable() else { return }
        // Homebrew's PKG installer needs an interactive terminal for sudo.
        // A fixed command avoids feeding any remote metadata into the shell.
        let command = "\(executable) upgrade --cask magnetonio/tap/copied && open /Applications/Copied.app"
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("Update Copied.command")
            try "#!/bin/sh\ntrap 'rm -f -- \"$0\"; rmdir -- \"$(dirname \"$0\")\"' EXIT\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            status = .unavailable("Opening Terminal…")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    if let error {
                        try? FileManager.default.removeItem(at: directory)
                        self?.status = .failed(error.localizedDescription)
                    } else {
                        self?.status = .unavailable("Finish installation in Terminal, then reopen Copied.")
                    }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available("\(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if let reason, [Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue),
                        Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue)].contains(reason.intValue) {
            status = .upToDate
        } else {
            status = .unavailable(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard (error as NSError).code != SUError.noUpdateError.rawValue else { return }
        if (error as NSError).code == SUError.installationCanceledError.rawValue {
            status = .idle
        } else {
            status = .failed(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if case .checking = status {
            status = error.map { .failed($0.localizedDescription) } ?? .idle
        }
    }

    func copyHomebrewUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewUpgradeCommand, forType: .string)
    }
}
#endif
