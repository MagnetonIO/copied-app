import SwiftUI
import SwiftData
import ServiceManagement
import UniformTypeIdentifiers
import CopiedKit

struct ExcludedApp: Identifiable {
    let id = UUID()
    let bundleID: String
    let name: String
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(SyncMonitor.self) private var syncMonitor
    @AppStorage("maxHistorySize") private var maxHistorySize = 5000
    @AppStorage("showWindowOnLaunch") private var showWindowOnLaunch = false
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("allowDuplicates") private var allowDuplicates = false
    @AppStorage("captureImages") private var captureImages = true
    @AppStorage("captureRichText") private var captureRichText = true
    @AppStorage("pasteAndClose") private var pasteAndClose = true

    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            clipboardTab
                .tabItem { Label("Clipboard", systemImage: "clipboard") }
                .tag(1)

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(2)

            syncTab
                .tabItem { Label("Sync", systemImage: "icloud") }
                .tag(3)
        }
        .frame(width: 480, height: 360)
        .toggleStyle(.switch)
        .tint(.accentColor)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .tint(.blue)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Show main window on launch", isOn: $showWindowOnLaunch)
                .tint(.blue)
            Toggle("Show in Dock", isOn: $showInDock)
                .tint(.blue)
                .onChange(of: showInDock) { _, newValue in
                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                }

            Toggle("Play sounds", isOn: $playSounds)
                .tint(.blue)
            Toggle("Copy and close popover", isOn: $pasteAndClose)
                .tint(.blue)

            Section("History") {
                Picker("Max history size", selection: $maxHistorySize) {
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("2,500").tag(2500)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("Unlimited").tag(Int.max)
                }

                LabeledContent("Trash") {
                    Button("Empty Trash", role: .destructive) {
                        emptyTrash()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Clipboard

    @State private var excludedApps: [ExcludedApp] = {
        let ids = UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return ExcludedApp(bundleID: id, name: name)
        }
    }()

    private var clipboardTab: some View {
        Form {
            Toggle("Allow duplicate clippings", isOn: $allowDuplicates)
                .tint(.blue)
                .onChange(of: allowDuplicates) { _, val in clipboardService.allowDuplicates = val }
            Toggle("Capture images", isOn: $captureImages)
                .tint(.blue)
                .onChange(of: captureImages) { _, val in clipboardService.captureImages = val }
            Toggle("Capture rich text (RTF)", isOn: $captureRichText)
                .tint(.blue)
                .onChange(of: captureRichText) { _, val in clipboardService.captureRichText = val }

            Section("Excluded Apps") {
                if excludedApps.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedApps) { app in
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            Text(app.name)
                            Spacer()
                            Button {
                                excludedApps.removeAll { $0.id == app.id }
                                saveExcludedApps()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("Add App…") {
                    pickApp()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                let name = FileManager.default.displayName(atPath: url.path)
                let app = ExcludedApp(bundleID: id, name: name)
                if !excludedApps.contains(where: { $0.bundleID == id }) {
                    excludedApps.append(app)
                    saveExcludedApps()
                }
            }
        }
    }

    private func saveExcludedApps() {
        let ids = excludedApps.map(\.bundleID)
        UserDefaults.standard.set(ids, forKey: "excludedBundleIDs")
        clipboardService.excludedBundleIDs = Set(ids)
    }

    // MARK: - Appearance

    @AppStorage("popoverItemCount") private var popoverItemCount = 50

    private var appearanceTab: some View {
        Form {
            Section("Popover") {
                Picker("Items shown", selection: $popoverItemCount) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sync

    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true

    private var syncTab: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: $cloudSyncEnabled)
                    .tint(.blue)
                    .onChange(of: cloudSyncEnabled) { _, val in syncMonitor.isEnabled = val }

                if cloudSyncEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.icloud.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        Text("Sync is active")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.icloud")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text("Sync is paused")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Clippings, lists, and assets sync automatically via iCloud.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Both devices must be signed into the same iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func emptyTrash() {
        let descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.deleteDate != nil }
        )
        guard let trashed = try? modelContext.fetch(descriptor) else { return }
        for clip in trashed { modelContext.delete(clip) }
        try? modelContext.save()
    }

    // MARK: - Login Item

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Failed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
