import SwiftUI
import CopiedKit

/// User-configurable enable/disable list for the `TextTransform` pipeline.
///
/// Enabled formatters show up in each Clipping's context menu ("Transform
/// ▸ …"), letting the user apply any one of them on demand to rewrite the
/// clipping's text in place. The selection is persisted under the
/// `textFormatters.enabled` app-group key as a comma-separated list of
/// `TextTransform.rawValue` strings, so it survives across devices via
/// `NSUbiquitousKeyValueStore` (future) and is visible to the share-ext
/// pipeline when we expand it to run transforms on capture.
struct TextFormattersSettingsView: View {
    @AppStorage("textFormatters.enabled", store: SharedStore.defaults) private var enabledRaw: String = TextFormatters.defaultRaw
    @State private var previewInput: String = "  Hello, World!  \nThis is a sample string."

    private var enabled: Set<String> {
        get { Set(enabledRaw.split(separator: ",").map(String.init)) }
        set { /* no-op: Bindings write via update() */ }
    }

    var body: some View {
        List {
            Section {
                ForEach(TextTransform.allCases) { transform in
                    Toggle(isOn: binding(for: transform)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transform.label)
                                .font(.body)
                            Text(preview(for: transform))
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.copiedSecondaryLabel)
                                .lineLimit(1)
                        }
                    }
                    .tint(.copiedTeal)
                }
            } header: {
                Text("Available formatters")
            } footer: {
                Text("Enabled formatters appear in each clipping's Transform menu. Tap one to rewrite the clipping text in place.")
            }

            Section {
                TextEditor(text: $previewInput)
                    .frame(minHeight: 80)
                    .font(.callout.monospaced())
            } header: {
                Text("Preview input")
            } footer: {
                Text("Change the text above to preview how each formatter will rewrite it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("Text Formatters")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
    }

    private func binding(for transform: TextTransform) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(transform.rawValue) },
            set: { isOn in
                var set = enabled
                if isOn { set.insert(transform.rawValue) } else { set.remove(transform.rawValue) }
                enabledRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    private func preview(for transform: TextTransform) -> String {
        let out = transform.apply(previewInput)
        return out.replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}

/// Module-scope helpers for reading the user's enabled-formatter set from
/// anywhere in the iOS app. The raw UserDefaults key is kept in one place
/// so the detail screen's `Transform ▸` menu and future share-extension
/// capture pipelines stay in sync.
enum TextFormatters {
    /// Defaults: trimWhitespace is the only one enabled out of the box
    /// because it's the least destructive / most universally desired.
    static let defaultRaw: String = TextTransform.trimWhitespace.rawValue

    @MainActor
    static func enabled() -> [TextTransform] {
        let raw = SharedStore.defaults.string(forKey: "textFormatters.enabled") ?? defaultRaw
        let ids = Set(raw.split(separator: ",").map(String.init))
        return TextTransform.allCases.filter { ids.contains($0.rawValue) }
    }
}
