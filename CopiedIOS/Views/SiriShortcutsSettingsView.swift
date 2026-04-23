import SwiftUI
import UIKit

/// Replaces the Phase 2 "Coming Soon" placeholder. Lists the AppIntents
/// Copied exposes to Siri + Shortcuts and offers a one-tap button to
/// jump into the Shortcuts app. We deliberately avoid `ShortcutsLink`
/// (iOS 17+ SwiftUI helper) because its availability on our target SDK
/// drifted during Phase 8a's first build attempt — a plain UIKit
/// `shortcuts://` URL open is universal.
struct SiriShortcutsSettingsView: View {
    @Environment(\.openURL) private var openURL

    private struct IntentRow: Identifiable {
        let id: String
        let title: String
        let description: String
        let systemImage: String
    }

    private let intents: [IntentRow] = [
        IntentRow(
            id: "save",
            title: "Save Clipboard to Copied",
            description: "Captures whatever is on the system clipboard right now and saves it to your Copied history.",
            systemImage: "doc.on.clipboard"
        ),
        IntentRow(
            id: "last",
            title: "Copy Last Clipping",
            description: "Copies your most recent Copied clipping back to the system clipboard.",
            systemImage: "arrow.up.doc"
        ),
        IntentRow(
            id: "open",
            title: "Open Copied",
            description: "Opens the Copied app.",
            systemImage: "app.badge.clock"
        )
    ]

    var body: some View {
        List {
            Section {
                ForEach(intents) { intent in
                    HStack(spacing: 14) {
                        Image(systemName: intent.systemImage)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.copiedTeal)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(intent.title)
                                .font(.body.weight(.medium))
                            Text(intent.description)
                                .font(.footnote)
                                .foregroundStyle(Color.copiedSecondaryLabel)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Available actions")
            } footer: {
                Text("These actions appear in the Shortcuts app and can be voice-triggered with Siri. Open Shortcuts to assign a phrase or combine them into a workflow.")
            }

            Section {
                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Shortcuts app", systemImage: "square.and.arrow.up.on.square")
                }
                .foregroundStyle(Color.copiedTeal)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("Siri Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
    }
}
