import SwiftUI
import CopiedKit

struct ClippingEditSheet: View {
    @Bindable var clipping: Clipping
    @Environment(\.dismiss) private var dismiss
    @State private var editedText: String = ""
    @State private var editedTitle: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Clipping")
                .font(.headline)

            TextField("Title (optional)", text: $editedTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $editedText)
                .font(.body.monospaced())
                .frame(minHeight: 150)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    clipping.title = editedTitle.isEmpty ? nil : editedTitle
                    clipping.text = editedText
                    clipping.modifiedDate = Date()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
        .onAppear {
            editedText = clipping.text ?? ""
            editedTitle = clipping.title ?? ""
        }
    }
}
