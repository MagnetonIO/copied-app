import SwiftUI
import CopiedKit

/// Custom bottom-sheet action list for the Clippings screen — matches
/// `images/IMG_9.png`. Four rows (New Clipping · Select Clippings · Hide
/// List Clippings · Sort List) each with a teal rounded-square icon tile
/// + label, separator, and a dark rounded-pill Cancel button. Presented
/// via `.sheet` with a compact `.presentationDetents` height so it sits
/// at the bottom like a native iOS confirmation dialog but styled to
/// match Copied's design language.
struct ClippingActionSheet: View {
    @Binding var multiSelectMode: Bool
    @Binding var selectedIDs: Set<String>
    let isListHidden: Bool
    /// Hide/Show List Clippings only makes sense on the main Copied view
    /// (it filters out clippings assigned to user-created lists). We hide
    /// the row entirely on per-list or Trash selections so the toggle
    /// never appears where it does nothing useful.
    let showHideRow: Bool
    let onNewClipping: () -> Void
    let onToggleHide: () -> Void
    let onSortList: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Action rows card
            VStack(spacing: 0) {
                row(
                    icon: "plus",
                    title: "New Clipping",
                    action: {
                        onNewClipping()
                        dismiss()
                    }
                )
                Divider().background(Color.copiedSeparator)

                row(
                    icon: multiSelectMode ? "checkmark.circle.fill" : "checkmark.circle",
                    title: multiSelectMode ? "Done Selecting" : "Select Clippings",
                    action: {
                        multiSelectMode.toggle()
                        if !multiSelectMode { selectedIDs.removeAll() }
                        dismiss()
                    }
                )
                Divider().background(Color.copiedSeparator)

                if showHideRow {
                    row(
                        icon: isListHidden ? "eye" : "list.bullet.rectangle",
                        title: isListHidden ? "Show List Clippings" : "Hide List Clippings",
                        action: {
                            onToggleHide()
                            dismiss()
                        }
                    )
                    Divider().background(Color.copiedSeparator)
                }

                row(
                    icon: "arrow.up.arrow.down",
                    title: "Sort List",
                    action: {
                        onSortList()
                        dismiss()
                    }
                )
            }
            .background(Color.copiedCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 14)

            // Cancel button — dark rounded pill, full-width minus inset
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.copiedCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.top, 20)
        .background(Color.copiedCanvas)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    /// Single action row — leading teal-tinted icon tile, label, full-row
    /// tap target.
    @ViewBuilder
    private func row(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.copiedTeal.opacity(0.25))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.copiedTeal)
                }
                .frame(width: 34, height: 34)

                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
