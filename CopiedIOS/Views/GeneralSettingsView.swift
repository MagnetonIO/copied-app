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
    @AppStorage("allowDuplicates") private var allowDuplicates = false
    @AppStorage("captureImages") private var captureImages = true
    @AppStorage("captureRichText") private var captureRichText = true
    @AppStorage("maxHistorySize") private var maxHistorySize = 5000
    /// `-1` is the "Forever" sentinel matching the Mac app.
    @AppStorage("retentionDays") private var retentionDays = -1
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 30

    @Environment(\.modelContext) private var modelContext
    @State private var presentsDedupConfirm = false
    @State private var dedupResultMessage: String?

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Allow Duplicates", isOn: $allowDuplicates)
                Toggle("Capture Images", isOn: $captureImages)
                Toggle("Capture Rich Text", isOn: $captureRichText)
            }
            Section("History") {
                Stepper("Max History: \(maxHistorySize)",
                        value: $maxHistorySize, in: 500...50000, step: 500)
                Stepper(retentionDays == -1 ? "Retention: Forever" : "Retention: \(retentionDays) days",
                        value: $retentionDays, in: -1...365, step: 1)
                Stepper("Trash: \(trashRetentionDays) days",
                        value: $trashRetentionDays, in: 1...90, step: 1)
            }
            Section {
                Button {
                    presentsDedupConfirm = true
                } label: {
                    HStack {
                        Text("Remove Duplicates")
                            .foregroundStyle(Color.copiedTeal)
                        Spacer()
                        if let msg = dedupResultMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Scans your history for clippings with identical content and moves all but the earliest copy to Trash. Recoverable for the next \(trashRetentionDays) days.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("General")
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
        .confirmationDialog("Remove duplicates?", isPresented: $presentsDedupConfirm, titleVisibility: .visible) {
            Button("Scan & Move Duplicates to Trash", role: .destructive) {
                let removed = ClipboardService.removeDuplicates(in: modelContext)
                dedupResultMessage = removed == 0
                    ? "No duplicates found"
                    : "Moved \(removed) to Trash"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clippings with identical content will be moved to Trash. The earliest copy of each is kept.")
        }
    }
}
