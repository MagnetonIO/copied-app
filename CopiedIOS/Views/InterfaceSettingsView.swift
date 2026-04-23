import SwiftUI
import CopiedKit

/// Interface / appearance preferences. The design (and `images/IMG_0978.png`)
/// is dark-only, but we expose the toggle for users who want system-follow.
struct InterfaceSettingsView: View {
    @AppStorage("followsSystemAppearance") private var followsSystem = false

    var body: some View {
        Form {
            Section {
                Toggle("Follow System Appearance", isOn: $followsSystem)
            } footer: {
                Text("Off keeps Copied in dark mode regardless of system setting.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("Interface")
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
    }
}
