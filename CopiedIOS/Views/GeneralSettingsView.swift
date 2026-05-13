import SwiftUI
import CopiedKit

/// General preferences — the iOS equivalent of the Mac Settings "General"
/// + "Clipboard" tabs. Same `@AppStorage` keys as the Mac app so a user who's
/// synced both sees consistent defaults via UserDefaults-in-iCloud (NSUbiquitous).
struct GeneralSettingsView: View {
    // Defaults here MUST match `CopiedMac/App/CopiedMacApp.swift._registerDefaults`
    // and `CopiedMac/Views/SettingsView.swift` — the `@AppStorage` keys round-trip
    // through iCloud's NSUbiquitousKeyValueStore, so whichever platform writes
    // first wins. Divergent defaults create silent settings drift.
    // Q7: `allowDuplicates` removed. Dedup runs unconditionally via
    // contentHash at `ClipboardService.insertOrMerge` time, so there is
    // no user-facing toggle and no "Remove Duplicates" button.
    @AppStorage("captureImages") private var captureImages = true
    @AppStorage("captureRichText") private var captureRichText = true
    @AppStorage("maxHistorySize") private var maxHistorySize = 5000
    /// `-1` is the "Forever" sentinel matching the Mac app.
    @AppStorage("retentionDays") private var retentionDays = -1
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 30

    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @State private var presentsDeleteAllConfirm = false
    @State private var presentsDeleteAllComplete = false

    // MARK: - Sections

    private var captureSection: some View {
        Section("Capture") {
            Toggle("Capture Images", isOn: $captureImages)
            Toggle("Capture Rich Text", isOn: $captureRichText)
        }
    }

    private var historySection: some View {
        Section("History") {
            Stepper("Max History: \(maxHistorySize)",
                    value: $maxHistorySize, in: 500...50000, step: 500)
                .onChange(of: maxHistorySize) { _, _ in
                    clipboardService.trimHistoryNow()
                }
            Stepper(retentionDays == -1 ? "Retention: Forever" : "Retention: \(retentionDays) days",
                    value: $retentionDays, in: -1...365, step: 1)
            Stepper("Trash: \(trashRetentionDays) days",
                    value: $trashRetentionDays, in: 1...90, step: 1)
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                presentsDeleteAllConfirm = true
            } label: {
                Text("Delete All Data")
                    .foregroundStyle(Color.red)
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Removes every clipping and list from this iPhone, all paired devices via CloudKit, and the Copied iCloud zone. Irreversible.")
        }
    }

    var body: some View {
        // Split into computed Section properties — SwiftUI's
        // type-checker times out on a single Form with 4+ Sections
        // containing Toggles / Steppers / conditional labels.
        Form {
            captureSection
            historySection
            dangerZoneSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("General")
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Delete all Copied data?",
            isPresented: $presentsDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task {
                    await CopiedSyncEngine.shared.performFullWipe(
                        modelContainer: SharedIOSData.container
                    )
                    presentsDeleteAllComplete = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes all local clippings, lists, and iCloud records for Copied. Other devices will see their clippings disappear on their next sync. This cannot be undone.")
        }
        .alert(
            "Data deleted",
            isPresented: $presentsDeleteAllComplete
        ) {
            Button("Quit Copied", role: .destructive) {
                // iOS has no NSApplication.terminate. `exit(0)` is the
                // pragmatic nuke-and-relaunch path; the user re-opens
                // from the Home Screen to start fresh.
                exit(0)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("All local data removed. CloudKit zones scheduled for deletion — iCloud storage will reflect the drop within ~15 minutes. Quit and relaunch for a clean slate.")
        }
    }
}
