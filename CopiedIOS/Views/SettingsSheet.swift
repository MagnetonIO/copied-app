import SwiftUI
import StoreKit
import CopiedKit

/// Settings modal sheet — matches `images/IMG_0978.png`:
///   Card 1: General · Interface (chevrons)
///   Card 2: iCloud Sync → status value ("Disabled" / "Active") + chevron
///   Card 3: Siri Shortcuts · Rules · Text Formatters · Merge Scripts
///           (placeholders — Mac doesn't implement these either)
///   Card 4: Documentation (external link)
///   Card 5: Rate Copied · Email Support · Licenses · Privacy Policy
///   Footer: "Copied X.Y.Z (B)"
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// In-app review prompt (iOS 16+). Apple throttles this to ≤3 per year
    /// per Apple ID — spamming it is a no-op, not a bug.
    @Environment(\.requestReview) private var requestReview
    @AppStorage("iCloudSyncPurchased") private var purchased = false
    // Default must match `SyncScreen` and `CopiedIOSApp`'s container
    // gate — otherwise this view reports "Disabled" right after unlock
    // while the sync screen reports "Active", because an unset key
    // resolves to each view's local default.
    @AppStorage("cloudSyncEnabled") private var cloudSyncToggle = true
    /// Lifted up from `SyncScreen` — iOS 26 won't reliably present a
    /// `.sheet` attached to a view that lives inside a `NavigationStack`
    /// inside another sheet; moving the modifier to the NavigationStack
    /// root makes the presentation deterministic.
    @State private var presentsLicenseEntry = false
    @State private var licenseBanner: String?

    private var syncStatusLabel: String {
        if purchased && cloudSyncToggle { return "Active" }
        return "Disabled"
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        // Include build config so users can tell at a glance whether they
        // are running a dev Debug build or the optimized Release binary.
        // Compiled out — `#if DEBUG` is a compile-time flag, so Release
        // builds don't even carry the "Debug" string.
        #if DEBUG
        let config = " · Debug"
        #else
        let config = " · Release"
        #endif
        return "Copied \(short) (\(build))\(config)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("General") { GeneralSettingsView() }
                    NavigationLink("Interface") { InterfaceSettingsView() }
                }

                Section {
                    NavigationLink {
                        SyncScreen(
                            presentsLicenseEntry: $presentsLicenseEntry,
                            licenseBanner: $licenseBanner
                        )
                    } label: {
                        HStack {
                            Text("iCloud Sync")
                            Spacer()
                            Text(syncStatusLabel)
                                .foregroundStyle(Color.copiedSecondaryLabel)
                        }
                    }
                }

                Section {
                    NavigationLink("Siri Shortcuts") { SiriShortcutsSettingsView() }
                    NavigationLink("Rules") { RulesSettingsView() }
                    NavigationLink("Text Formatters") { TextFormattersSettingsView() }
                    NavigationLink("Merge Scripts") { MergeScriptsSettingsView() }
                }

                Section {
                    Link("Documentation", destination: URL(string: "https://getcopied.app/docs")!)
                        .foregroundStyle(.primary)
                }

                Section {
                    Button("Rate Copied") { requestReview() }
                        .foregroundStyle(.primary)
                    Link("Email Support",
                         destination: URL(string: "mailto:support@getcopied.app?subject=Copied%20iOS")!)
                        .foregroundStyle(.primary)
                    NavigationLink("Licenses") { LicensesView() }
                    Link("Privacy Policy",
                         destination: URL(string: "https://getcopied.app/privacy")!)
                        .foregroundStyle(.primary)
                }

                Section {
                    Text(versionString)
                        .font(.footnote)
                        .foregroundStyle(Color.copiedSecondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.copiedTeal)
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $presentsLicenseEntry) {
            LicenseEntrySheet(onSuccess: { email in
                licenseBanner = "License verified for \(email). iCloud Sync is now unlocked."
            })
        }
    }
}

/// Placeholder row for features visible in the 4.0.x screenshot but not yet
/// implemented on Mac either. Keeps the UI parity while deferring the feature.
private struct ComingSoonLink: View {
    let title: String
    var body: some View {
        NavigationLink(title) {
            ContentUnavailableView(
                "Coming Soon",
                systemImage: "hourglass",
                description: Text("\(title) will arrive in a future update.")
            )
            .preferredColorScheme(.dark)
        }
    }
}

private struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open-source licenses")
                    .font(.title2.weight(.semibold))
                Text("Copied uses Apple frameworks and the CopiedKit source distributed with the app. No third-party OSS licenses require attribution at this time.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Licenses")
    }
}
