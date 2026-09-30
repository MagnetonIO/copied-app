#if DIRECT_DOWNLOAD
import SwiftUI

struct MacUpdatesView: View {
    @State private var updater: UpdateManager

    init(updater: UpdateManager = .shared) {
        _updater = State(initialValue: updater)
    }

    var body: some View {
        @Bindable var updater = updater
        if updater.channel == .directDownload {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Download updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
        } else {
            LabeledContent("Managed by", value: "Homebrew")
        }

        HStack {
            Text("Version \(version)")
            Spacer()
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)
        }

        switch updater.status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            Label("Copied is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .available(let version):
            VStack(alignment: .leading, spacing: 8) {
                Label("Copied \(version) is available", systemImage: "arrow.down.circle")
                if updater.channel == .homebrew {
                    Button {
                        updater.installHomebrewUpdate()
                    } label: {
                        Label("Install with Homebrew…", systemImage: "terminal")
                    }
                    .help("Opens Terminal for the installer password prompt")
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable(let message):
            Label(message, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if updater.channel == .homebrew {
            HStack(spacing: 10) {
                Text(UpdateManager.homebrewUpgradeCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    updater.copyHomebrewUpgradeCommand()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("Copy upgrade command")
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}
#endif
