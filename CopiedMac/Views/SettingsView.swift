import SwiftUI
import SwiftData
import ServiceManagement
import UniformTypeIdentifiers
import CloudKit
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
    @AppStorage("captureImages") private var captureImages = true
    @AppStorage("captureRichText") private var captureRichText = true
    @AppStorage("pasteAndClose") private var pasteAndClose = true
    @AppStorage("stripURLTrackingParams") private var stripURLTrackingParams = true
    @AppStorage("retentionDays") private var retentionDays = -1
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 30

    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    @State private var selectedTab = 0

    /// One-shot: if set, the Settings window opens to this tag on next appear.
    /// `AppRestarter.restartAfterPurchase()` writes this before relaunching so the
    /// user lands on the Sync tab and immediately sees the unlocked state.
    @AppStorage("settingsTabOnNextOpen") private var pendingTab: Int = -1

    var body: some View {
        tabView
        #if MAS_BUILD
            .overlay {
                if isActivatingSync {
                    ZStack {
                        // Note: no .ignoresSafeArea() — the tinted background stays
                        // within content bounds so the NSWindow title bar remains
                        // draggable even while the overlay is active.
                        Color.black.opacity(0.35)
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Activating iCloud Sync…")
                                .font(.headline)
                            Text("Copied will restart")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
        // No body-level `.animation(_:value:)` modifier. A body-level animation here
        // makes SwiftUI animate the NSWindow content-size feedback loop during
        // title-bar drag, which makes the window snap back to its original origin
        // when the drag releases. Transition on the overlay itself is enough.
        #endif
    }

    private var tabView: some View {
        VStack(spacing: 0) {
            // Custom top tab bar. Matches the native macOS prefs tabs (icon above
            // label, centered at the top) — SwiftUI's TabView drops that styling
            // when it's not inside a `Settings { }` scene, so we render it by hand.
            settingsTabBar
                .padding(.top, 6)
                .padding(.bottom, 4)

            Divider()

            // Swap the tab content based on selection. Using a switch keeps only
            // one tab's views in memory at a time (matches prior TabView behavior).
            Group {
                switch selectedTab {
                case 0: generalTab
                case 1: clipboardTab
                case 2: appearanceTab
                case 3: syncTab
                default: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 500)
        .toggleStyle(.switch)
        .tint(.accentColor)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if pendingTab >= 0 {
                selectedTab = pendingTab
                pendingTab = -1
            }
        }
    }

    private var settingsTabBar: some View {
        HStack(spacing: 2) {
            Spacer()
            settingsTabButton(tag: 0, label: "General", icon: "gearshape")
            settingsTabButton(tag: 1, label: "Clipboard", icon: "clipboard")
            settingsTabButton(tag: 2, label: "Appearance", icon: "paintbrush")
            settingsTabButton(tag: 3, label: "Sync", icon: "icloud")
            settingsTabButton(tag: 4, label: "About", icon: "info.circle")
            Spacer()
        }
    }

    private func settingsTabButton(tag: Int, label: String, icon: String) -> some View {
        let isSelected = selectedTab == tag
        return Button {
            selectedTab = tag
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .tint(.accentColor)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Show main window on launch", isOn: $showWindowOnLaunch)
                .tint(.accentColor)

            Toggle("Copy and close popover", isOn: $pasteAndClose)
                .tint(.accentColor)

            Section {
                Picker("Max history size", selection: $maxHistorySize) {
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("2,500").tag(2500)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("Unlimited").tag(Int.max)
                }
                .onChange(of: maxHistorySize) { _, _ in
                    clipboardService.trimHistoryNow()
                }

                Picker("Auto-delete after", selection: $retentionDays) {
                    Text("Never").tag(-1)
                    Text("30 days").tag(30)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                    Text("2 years").tag(730)
                }
                .onChange(of: retentionDays) { _, _ in
                    clipboardService.trimByAge()
                }

                Picker("Auto-empty trash after", selection: $trashRetentionDays) {
                    Text("Never").tag(-1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .onChange(of: trashRetentionDays) { _, _ in
                    clipboardService.purgeOldTrash()
                }

                LabeledContent("Trash") {
                    Button("Empty Trash", role: .destructive) {
                        emptyTrash()
                    }
                }

            } header: {
                Text("History")
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
            Toggle("Capture images", isOn: $captureImages)
                .tint(.accentColor)
                .onChange(of: captureImages) { _, val in clipboardService.captureImages = val }
            Toggle("Capture rich text (RTF)", isOn: $captureRichText)
                .tint(.accentColor)
                .onChange(of: captureRichText) { _, val in clipboardService.captureRichText = val }
            Toggle("Strip URL tracking parameters (utm_*, fbclid, gclid…)", isOn: $stripURLTrackingParams)
                .tint(.accentColor)

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

            Section("Danger Zone") {
                Button("Delete All Clippings and iCloud Data…", role: .destructive) {
                    showDeleteAllConfirm = true
                }
                Text("Removes every clipping and list from this Mac, all paired devices via CloudKit, and both CKSyncEngine zones. Irreversible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Delete all Copied data?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await performDeleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes all local clippings, lists, and iCloud records for Copied. Other devices will see their clippings disappear on their next sync. This cannot be undone.")
        }
        .alert(
            "Deletion started",
            isPresented: $showDeleteAllComplete
        ) {
            Button("Quit Copied") { NSApplication.shared.terminate(nil) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("All local data removed. CloudKit zones scheduled for deletion — iCloud storage will reflect the drop within ~15 minutes. Quit and relaunch to start fresh.")
        }
    }

    @State private var showDeleteAllConfirm = false
    @State private var showDeleteAllComplete = false

    /// Thin wrapper around the shared `CopiedSyncEngine.performFullWipe`
    /// so both platforms go through identical nuke-everything logic.
    @MainActor
    private func performDeleteAll() async {
        await CopiedSyncEngine.shared.performFullWipe(
            modelContainer: SharedData.container
        )
        showDeleteAllComplete = true
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
    #if MAS_BUILD
    @AppStorage(PurchaseManager.purchasedKey) private var iCloudSyncPurchased = false
    /// Shown briefly between a successful purchase/restore and the auto-restart,
    /// so the user gets a beat of visual confirmation before the window disappears.
    @State private var isActivatingSync = false
    #endif

    #if LICENSE_STRIPE
    @State private var showLicenseEntrySheet = false
    @State private var licenseError: String?
    #endif

    private var syncTab: some View {
        Form {
            // R-2 HIGH-1: if the cloudSync gate has changed mid-session
            // (mid-session IAP unlock, license paste, toggle flip) the
            // ModelContainer is stale and writes still go to a local-only
            // store. Banner prompts a relaunch with a one-click Quit.
            if SharedData.requiresRelaunchForSync {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Restart required")
                                .font(.headline)
                            Text("iCloud Sync unlocked. Quit and reopen Copied so new clippings start syncing to iCloud.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Quit Copied") {
                                NSApp.terminate(nil)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                // In MAS builds the toggle is force-displayed OFF and disabled until the
                // IAP is purchased. This avoids the confusing "toggle ON but Sync is
                // locked" state users were seeing. The Unlock button below is the only
                // interactive control until then.
                #if MAS_BUILD
                let syncToggleBinding = Binding<Bool>(
                    get: { iCloudSyncPurchased && cloudSyncEnabled },
                    set: { newValue in
                        guard iCloudSyncPurchased else { return }
                        cloudSyncEnabled = newValue
                        syncMonitor.isEnabled = newValue
                    }
                )
                Toggle("iCloud Sync", isOn: syncToggleBinding)
                    .tint(.accentColor)
                    .disabled(!iCloudSyncPurchased)
                #else
                Toggle("iCloud Sync", isOn: $cloudSyncEnabled)
                    .tint(.accentColor)
                    .onChange(of: cloudSyncEnabled) { _, newValue in
                        syncMonitor.isEnabled = newValue
                    }
                #endif

                #if MAS_BUILD
                if !iCloudSyncPurchased {
                    purchaseCTA
                } else if cloudSyncEnabled {
                    activeStateRow
                } else {
                    pausedStateRow
                }
                #else
                if cloudSyncEnabled {
                    activeStateRow
                } else {
                    pausedStateRow
                }
                #endif
            }

            Section {
                Text("Clippings, lists, and assets sync automatically via iCloud.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Both devices must be signed into the same iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                #if MAS_BUILD
                Text("iCloud Sync is a one-time in-app purchase. Local clipboard history remains free.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                #endif
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var activeStateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.green)
                .font(.callout)
            Text("Sync is active")
                .foregroundStyle(.secondary)
        }
    }

    private var pausedStateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.icloud")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text("Sync is paused")
                .foregroundStyle(.secondary)
        }
    }

    #if MAS_BUILD
    /// App Store listing URL for Copied App. `macappstore://` opens directly in the
    /// App Store app (vs. `https://apps.apple.com/` which bounces through Safari first).
    private static let copiedAppStoreURL = URL(string: "macappstore://apps.apple.com/app/id6762879815")!

    /// Stripe Checkout entry point for the License variant.
    /// - `LICENSE_STRIPE_LOCAL` compile flag routes to the local webhook-dev
    ///   server on :3000 for end-to-end testing against the Stripe CLI harness.
    /// - Without it, points at production getcopied.app (which redirects to
    ///   the real Checkout URL on Vercel).
    private static let stripeCheckoutURL: URL = {
        #if LICENSE_STRIPE_LOCAL
        return URL(string: "http://localhost:3000/buy?app=mac")!
        #else
        return URL(string: "https://getcopied.app/buy?app=mac")!
        #endif
    }()

    @ViewBuilder
    private var purchaseCTA: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.icloud")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("Sync is locked")
                    .foregroundStyle(.secondary)
            }
            HStack {
                #if MAS_STOREFRONT
                // Mac App Store build — real StoreKit IAP.
                Button {
                    Task {
                        let bought = await PurchaseManager.shared.purchase()
                        if bought {
                            cloudSyncEnabled = true
                            isActivatingSync = true
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            AppRestarter.restartAfterPurchase()
                        }
                    }
                } label: {
                    if let price = PurchaseManager.shared.product?.displayPrice {
                        Text("Unlock iCloud Sync — \(price)")
                    } else {
                        Text("Unlock iCloud Sync")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(PurchaseManager.shared.purchaseInFlight || PurchaseManager.shared.product == nil)

                Button("Restore Purchases") {
                    Task {
                        let restored = await PurchaseManager.shared.restore()
                        if restored {
                            cloudSyncEnabled = true
                            isActivatingSync = true
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            AppRestarter.restartAfterPurchase()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(PurchaseManager.shared.purchaseInFlight)
                #elseif LICENSE_STRIPE
                // Direct-download build with Stripe-backed licensing. Opens Checkout in
                // the user's browser; successful payment redirects back via
                // copied://unlock?key=<signed-jwt> which the app verifies offline
                // against a baked-in Ed25519 public key.
                Button {
                    NSWorkspace.shared.open(Self.stripeCheckoutURL)
                } label: {
                    Label("Unlock iCloud Sync — $4.99", systemImage: "bag.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button("Enter License Key…") {
                    showLicenseEntrySheet = true
                }
                .buttonStyle(.bordered)
                #else
                #error("MAS_BUILD requires either MAS_STOREFRONT or LICENSE_STRIPE. Check fastlane lane xcargs.")
                #endif
            }
            #if MAS_STOREFRONT
            if let error = PurchaseManager.shared.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            #elseif LICENSE_STRIPE
            if let error = licenseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("One-time purchase. Paid via Stripe; license is stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        #if MAS_STOREFRONT
        .task { await PurchaseManager.shared.loadProduct() }
        #endif
        #if LICENSE_STRIPE
        .sheet(isPresented: $showLicenseEntrySheet) {
            LicenseEntrySheet(onSubmit: { key in
                do {
                    _ = try LicenseStore.storeAndVerify(license: key)
                    licenseError = nil
                    showLicenseEntrySheet = false
                    cloudSyncEnabled = true
                    isActivatingSync = true
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        AppRestarter.restartAfterPurchase()
                    }
                } catch {
                    licenseError = "Invalid license key."
                }
            })
        }
        #endif
    }
    #endif

    // MARK: - About

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        #if MAS_BUILD
        let variant = "Paid"
        #else
        let variant = "OSS"
        #endif
        // `#if DEBUG` is a compile-time flag — Release binaries don't even
        // carry the "Debug" string. Lets users tell at a glance whether
        // they're running the optimized build or a dev build.
        #if DEBUG
        let config = " · Debug"
        #else
        let config = " · Release"
        #endif
        return "\(short) (\(build)) · \(variant)\(config)"
    }

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copied")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Version \(appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("by Magneton Labs, LLC")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("© 2026 Magneton Labs, LLC. All rights reserved.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Support") {
                Button { openSupportEmail() } label: {
                    LabeledContent("Email") {
                        Text("support@getcopied.app").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)

                Button { openURL("https://getcopied.app") } label: {
                    LabeledContent("Website") {
                        Text("getcopied.app").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)

                Button { openURL("https://getcopied.app/support") } label: {
                    LabeledContent("Help Center") {
                        Text("getcopied.app/support").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("Legal") {
                Button { openURL("https://getcopied.app/privacy") } label: {
                    LabeledContent("Privacy Policy") {
                        Text("getcopied.app/privacy").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)

                Button { openURL("https://getcopied.app/terms") } label: {
                    LabeledContent("Terms of Use") {
                        Text("getcopied.app/terms").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }

            #if MAS_BUILD
            Section("iCloud Sync") {
                HStack(spacing: 6) {
                    Image(systemName: iCloudSyncPurchased ? "checkmark.icloud.fill" : "lock.icloud")
                        .foregroundStyle(iCloudSyncPurchased ? .green : .secondary)
                    Text(iCloudSyncPurchased ? "Unlocked" : "Not unlocked")
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .padding()
    }

    private func openSupportEmail() {
        let body = "\n\n\n—\nApp version: \(appVersion)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let subject = "Copied Support".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:support@getcopied.app?subject=\(subject)&body=\(body)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
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

#if LICENSE_STRIPE
/// Paste-in license key sheet for users who close the browser before the
/// deep-link fires, or who want to move a license to a second Mac.
private struct LicenseEntrySheet: View {
    let onSubmit: (String) -> Void
    @State private var key: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter License Key")
                .font(.headline)
            Text("Paste the license key from your purchase confirmation email.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $key)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Unlock") {
                    onSubmit(key.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
#endif
