import SwiftUI
import SwiftData
import UIKit
import CopiedKit

/// Phase 14 — "Save Clipping" panel, triggered from the bottom-left
/// clip icon in `ClippingsListScreen`. Snapshots whatever is currently
/// on `UIPasteboard.general` once on appear, pre-fills editable title
/// and text fields, and persists a new `Clipping` in the model context
/// on Save. Matches the shape of `ClippingEditSheet` (dark form, teal
/// Save trailing, Cancel leading) plus a small kind badge + optional
/// image thumbnail so the user can confirm what they're about to save.
struct SaveClippingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ClipList.sortOrder) private var lists: [ClipList]

    /// Frozen snapshot of the pasteboard taken once on appear. Reading
    /// `UIPasteboard.general` triggers the iOS "pasted from <app>"
    /// banner, so we never re-read inside the view body.
    @State private var snapshot: Snapshot = .empty
    @State private var titleDraft: String = ""
    @State private var textDraft: String = ""
    @State private var selectedListID: String = ""

    enum Kind { case text, link, image, empty }

    struct Snapshot {
        let kind: Kind
        let text: String?
        let url: URL?
        let imageData: Data?
        let image: UIImage?

        static let empty = Snapshot(kind: .empty, text: nil, url: nil, imageData: nil, image: nil)

        /// Priority: image → URL → string, mirroring `ClipboardScreen`'s
        /// precedence so the two screens agree on what "the clipboard
        /// currently is".
        static func read() -> Snapshot {
            let pb = UIPasteboard.general
            if let img = pb.image {
                let data = img.pngData() ?? Data()
                return Snapshot(kind: .image, text: nil, url: nil, imageData: data, image: img)
            }
            if let url = pb.url {
                return Snapshot(kind: .link, text: url.absoluteString, url: url, imageData: nil, image: nil)
            }
            if let text = pb.string, !text.isEmpty {
                return Snapshot(kind: .text, text: text, url: nil, imageData: nil, image: nil)
            }
            return .empty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if snapshot.kind == .empty {
                    emptyState
                } else {
                    form
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Save Clipping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.copiedTeal)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.copiedTeal)
                        .disabled(snapshot.kind == .empty)
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            let snap = Snapshot.read()
            snapshot = snap
            // Pre-fill the text editor with the pasteboard content so
            // the user sees what they're saving and can tweak before
            // commit. Title starts empty — let the user pick one.
            textDraft = snap.text ?? ""
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: kindIcon)
                        .foregroundStyle(Color.copiedTeal)
                    Text(kindLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                }
            }

            if snapshot.kind == .image, let image = snapshot.image {
                Section("Preview") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Section("Title") {
                TextField("Optional title", text: $titleDraft)
                    .textInputAutocapitalization(.sentences)
            }

            if snapshot.kind == .text || snapshot.kind == .link {
                Section(snapshot.kind == .link ? "Link" : "Text") {
                    TextEditor(text: $textDraft)
                        .frame(minHeight: 160)
                        .font(.body.monospaced())
                }
            }

            Section {
                Picker("List", selection: $selectedListID) {
                    Text("No list").tag("")
                    ForEach(lists) { list in
                        Text(list.name).tag(list.listID)
                    }
                }
            } header: {
                Text("List")
            } footer: {
                Text("Assign this clipping to one of your custom lists, or keep it unfiled.")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.copiedSecondaryLabel)
            Text("Nothing on your clipboard")
                .font(.headline)
            Text("Copy some text, a link, or an image, then come back to save it.")
                .font(.footnote)
                .foregroundStyle(Color.copiedSecondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.copiedCanvas)
    }

    // MARK: - Badge helpers

    private var kindIcon: String {
        switch snapshot.kind {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .empty: return "questionmark.square"
        }
    }

    private var kindLabel: String {
        switch snapshot.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .empty: return "Empty"
        }
    }

    // MARK: - Save

    private func save() {
        guard snapshot.kind != .empty else { return }

        let clip: Clipping
        switch snapshot.kind {
        case .text:
            clip = Clipping(text: textDraft, title: nil, url: nil)
        case .link:
            clip = Clipping(
                text: textDraft,
                title: nil,
                url: snapshot.url?.absoluteString
            )
        case .image:
            clip = Clipping(text: nil, title: nil, url: nil)
            if let data = snapshot.imageData {
                clip.imageData = data
                clip.hasImage = true
                clip.imageByteCount = data.count
                clip.imageFormat = "png"
            }
        case .empty:
            return
        }

        if !titleDraft.isEmpty {
            clip.title = titleDraft
        }
        if !selectedListID.isEmpty {
            clip.list = lists.first { $0.listID == selectedListID }
        }

        modelContext.insert(clip)
        try? modelContext.save()
        dismiss()
    }
}
