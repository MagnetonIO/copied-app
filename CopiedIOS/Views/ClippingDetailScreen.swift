import SwiftUI
import CopiedKit

/// iOS detail container. Reuses `ClippingDetail` from CopiedKit for the body,
/// adds an "Edit" button and a "Transform" menu in the trailing toolbar —
/// the Transform menu pulls the user's enabled `TextTransform` list from
/// the Text Formatters settings, so only the formatters the user cares
/// about appear here. Tapping one rewrites `clipping.text` in place.
struct ClippingDetailScreen: View {
    let clipping: Clipping
    @Environment(\.modelContext) private var modelContext
    @State private var editing: Clipping?
    @State private var transformError: String?

    var body: some View {
        ClippingDetail(clipping: clipping)
            .navigationTitle(clipping.displayTitle.isEmpty ? "Clipping" : clipping.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    transformMenu
                    Button("Edit") { editing = clipping }
                        .foregroundStyle(Color.copiedTeal)
                }
            }
            .sheet(item: $editing) { clip in
                ClippingEditSheet(clipping: clip)
            }
            .alert(
                "Couldn't transform",
                isPresented: Binding(
                    get: { transformError != nil },
                    set: { if !$0 { transformError = nil } }
                ),
                presenting: transformError
            ) { _ in
                Button("OK", role: .cancel) { transformError = nil }
            } message: { error in
                Text(error)
            }
            .background(Color.copiedCanvas)
            .preferredColorScheme(.dark)
            .tint(.copiedTeal)
    }

    /// Hidden entirely when (a) the clipping has no text, or (b) the user
    /// hasn't enabled any formatters. This keeps the toolbar uncluttered
    /// for image clippings and default-config users.
    @ViewBuilder
    private var transformMenu: some View {
        let formatters = TextFormatters.enabled()
        if !formatters.isEmpty, let _ = clipping.text {
            Menu {
                ForEach(formatters) { formatter in
                    Button(formatter.label) { apply(formatter) }
                }
            } label: {
                Image(systemName: "textformat.alt")
                    .foregroundStyle(Color.copiedTeal)
            }
        }
    }

    private func apply(_ formatter: TextTransform) {
        guard let input = clipping.text else { return }
        let output = formatter.apply(input)
        clipping.text = output
        do {
            try modelContext.save()
        } catch {
            // Roll back so the detail view doesn't show a stale local edit
            // that never hit CloudKit.
            clipping.text = input
            transformError = error.localizedDescription
        }
    }
}
