import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import CopiedKit

/// Live preview of whatever's currently on `UIPasteboard.general`.
///
/// Per `images/IMG_1014.png`: this screen is NOT a history list — it's a
/// single-item inspector for the one current Apple clipboard item. It
/// shows a metadata header (type + size), a preview of the content
/// (text / image / URL), and a prominent teal "Save to Copied" button
/// that persists the current payload into the Copied history.
///
/// Reading the pasteboard triggers iOS' "pasted from <app>" banner — so
/// we only read on `.onAppear` and on `ScenePhase.active`, never in a
/// tight loop.
struct ClipboardScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var snapshot: ClipboardSnapshot = .empty
    @State private var savedToast: SaveToast = .idle

    /// One frozen read of the system pasteboard. We snapshot on foreground
    /// so the preview is stable even if the pasteboard changes while the
    /// user is looking at it.
    struct ClipboardSnapshot {
        enum Kind { case text, url, image, empty }
        let kind: Kind
        let text: String?
        let url: URL?
        let imageData: Data?
        let title: String?
        let byteCount: Int
        let image: UIImage?

        static let empty = ClipboardSnapshot(
            kind: .empty, text: nil, url: nil, imageData: nil,
            title: nil, byteCount: 0, image: nil
        )

        static func read() -> ClipboardSnapshot {
            let pb = UIPasteboard.general
            // Order matters — URL before text so a pasted link doesn't
            // show as a plain string. Image wins over both when present.
            if let img = pb.image {
                let data = img.pngData() ?? Data()
                let size = "\(Int(img.size.width * img.scale)) × \(Int(img.size.height * img.scale))"
                return ClipboardSnapshot(
                    kind: .image, text: nil, url: nil, imageData: data,
                    title: size, byteCount: data.count, image: img
                )
            }
            if let url = pb.url {
                return ClipboardSnapshot(
                    kind: .url, text: url.absoluteString, url: url,
                    imageData: nil, title: url.host ?? url.absoluteString,
                    byteCount: url.absoluteString.utf8.count, image: nil
                )
            }
            if let text = pb.string, !text.isEmpty {
                return ClipboardSnapshot(
                    kind: .text, text: text, url: nil,
                    imageData: nil, title: nil,
                    byteCount: text.utf8.count, image: nil
                )
            }
            return .empty
        }
    }

    enum SaveToast { case idle, saved, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Color.copiedCanvas.opacity(0.5))
                .overlay(alignment: .bottom) { Color.copiedSeparator.frame(height: 1) }

            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            saveButton
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(Color.copiedCanvas)
        .navigationTitle("Clipboard")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { snapshot = .read() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.copiedTeal)
                }
            }
        }
        .onAppear { snapshot = .read() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { snapshot = .read() }
        }
        .preferredColorScheme(.dark)
        .tint(.copiedTeal)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleLine)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text(metadataLine)
                .font(.footnote)
                .foregroundStyle(Color.copiedSecondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: String {
        switch snapshot.kind {
        case .url:  return snapshot.url?.host ?? "Link"
        case .image: return snapshot.title ?? "Image"
        case .text: return firstLine(of: snapshot.text) ?? "Untitled"
        case .empty: return "Clipboard is empty"
        }
    }

    private var metadataLine: String {
        switch snapshot.kind {
        case .url:
            return "Link · \(snapshot.byteCount) byte\(snapshot.byteCount == 1 ? "" : "s")"
        case .image:
            return "PNG — \(snapshot.title ?? "Image") (\(formattedBytes))"
        case .text:
            let chars = snapshot.text?.count ?? 0
            let words = snapshot.text?.split(whereSeparator: \.isWhitespace).count ?? 0
            return "Text · \(chars) character\(chars == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s")"
        case .empty:
            return "Copy something to preview it here"
        }
    }

    private var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file)
    }

    private func firstLine(of text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    }

    // MARK: - Preview

    @ViewBuilder
    private var contentPreview: some View {
        switch snapshot.kind {
        case .empty:
            emptyPlaceholder
        case .text, .url:
            textPreview
        case .image:
            imagePreview
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.copiedSecondaryLabel)
            Text("Nothing on the clipboard")
                .font(.body)
                .foregroundStyle(Color.copiedSecondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var textPreview: some View {
        ScrollView {
            Text(snapshot.text ?? "")
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var imagePreview: some View {
        ScrollView {
            if let img = snapshot.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Save CTA

    private var saveButton: some View {
        Button(action: saveToCopied) {
            HStack {
                if case .saved = savedToast {
                    Image(systemName: "checkmark")
                    Text("Saved to Copied")
                } else {
                    Text("Save to Copied")
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(snapshot.kind == .empty ? Color.copiedTeal.opacity(0.3) : Color.copiedTeal)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(snapshot.kind == .empty)
    }

    private func saveToCopied() {
        let clip: Clipping
        switch snapshot.kind {
        case .text:
            clip = Clipping(text: snapshot.text, title: nil, url: nil)
        case .url:
            clip = Clipping(text: snapshot.text, title: snapshot.title, url: snapshot.url?.absoluteString)
        case .image:
            clip = Clipping(text: nil, title: snapshot.title, url: nil)
            if let data = snapshot.imageData {
                clip.imageData = data
                clip.hasImage = true
                clip.imageByteCount = data.count
            }
        case .empty:
            return
        }
        modelContext.insert(clip)
        do {
            try modelContext.save()
            savedToast = .saved
            // Revert the button label after a short window so the user
            // can save again if the clipboard changes.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if case .saved = savedToast { savedToast = .idle }
            }
        } catch {
            modelContext.delete(clip)
            savedToast = .failed(error.localizedDescription)
        }
    }
}
