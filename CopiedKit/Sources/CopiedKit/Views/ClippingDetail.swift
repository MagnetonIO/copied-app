import SwiftUI
import SwiftData

public struct ClippingDetail: View {
    @Bindable var clipping: Clipping
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    public init(clipping: Clipping) {
        self.clipping = clipping
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                content
                Divider()
                metadata
            }
            .padding()
        }
        .toolbar {
            toolbarContent
        }
        // Title is edited via a live `TextField` binding — we don't save
        // on every keystroke (CloudKit rate-limits mutations), but we
        // must commit when the view disappears so the final value is
        // durable and propagates to other devices.
        .onDisappear {
            clipping.persist()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: titleBinding, prompt: Text("Add title…"))
                    .font(.title2.bold())
                    .textFieldStyle(.plain)

                HStack(spacing: 8) {
                    Label(clipping.contentKind.rawValue.capitalized, systemImage: kindIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let appName = clipping.appName {
                        Label(appName, systemImage: "app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(clipping.addDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { clipping.title ?? "" },
            set: { clipping.title = $0.isEmpty ? nil : $0 }
        )
    }

    private var kindIcon: String {
        switch clipping.contentKind {
        case .text: "doc.text"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .video: "play.rectangle.fill"
        case .link: "link"
        case .file: "doc"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.alignleft"
        case .html: "globe"
        case .unknown: "questionmark.square"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch clipping.contentKind {
        case .code, .html:
            codeContent
        case .markdown:
            markdownContent
        case .text, .richText:
            textContent
        case .image:
            imageContent
        case .link:
            linkContent
        default:
            Text("No preview available")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if let text = clipping.text {
            VStack(alignment: .leading, spacing: 8) {
                if let lang = clipping.detectedLanguage {
                    Text(lang.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }

                HStack(alignment: .top, spacing: 0) {
                    // Line numbers gutter
                    let lines = text.components(separatedBy: .newlines)
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                            Text("\(idx + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                    }
                    .padding(.trailing, 8)

                    Divider()

                    // Code text
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                .padding()
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if let text = clipping.text {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var markdownContent: some View {
        if let text = clipping.text {
            // `inlineOnlyPreservingWhitespace` keeps line breaks intact
            // and renders **bold** / *italic* / `code` / [text](url)
            // natively. Block-level constructs (headings, lists, fenced
            // code) come through as their source markers — good enough
            // for a preview without pulling in a markdown-rendering dep.
            let attributed = (try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )) ?? AttributedString(text)
            VStack(alignment: .leading, spacing: 8) {
                Text("markdown")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)

                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let data = clipping.imageData {
            #if canImport(AppKit)
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #elseif canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #endif
        }
    }

    @ViewBuilder
    private var linkContent: some View {
        if let urlStr = clipping.url, let url = URL(string: urlStr) {
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: url) {
                    Label(urlStr, systemImage: "arrow.up.right.square")
                        .lineLimit(1)
                }
                if let text = clipping.text, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Metadata")
                .font(.headline)

            LabeledContent("Added", value: clipping.addDate.formatted())
            if let copied = clipping.copiedDate {
                LabeledContent("Copied", value: copied.formatted())
            }
            LabeledContent("Device", value: clipping.deviceName)
            if let bundleID = clipping.appBundleID {
                LabeledContent("Bundle ID", value: bundleID)
            }
            if !clipping.types.isEmpty {
                LabeledContent("UTI Types", value: clipping.types.joined(separator: ", "))
            }
        }
        .font(.caption)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if clipping.text != nil {
                #if canImport(AppKit)
                Menu {
                    ForEach(TextTransform.allCases) { transform in
                        Button(transform.label) {
                            guard let text = clipping.text else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transform.apply(text), forType: .string)
                            clipping.markUsed()
                        }
                    }
                } label: {
                    Label("Copy As…", systemImage: "doc.on.doc")
                }
                #endif
            }

            Button {
                clipping.isFavorite.toggle()
                clipping.persist()
            } label: {
                Image(systemName: clipping.isFavorite ? "star.fill" : "star")
            }

            Button {
                clipping.isPinned.toggle()
                clipping.persist()
            } label: {
                Image(systemName: clipping.isPinned ? "pin.fill" : "pin")
            }

            Button(role: .destructive) {
                // Set deleteDate, persist the change, and pop the detail
                // view so the user returns to the list and sees the row
                // removed. Without dismiss() the navigation stack would
                // leave them staring at a trashed clipping with no
                // visible change.
                clipping.moveToTrash()
                try? modelContext.save()
                dismiss()
            } label: {
                Image(systemName: "trash")
            }
        }
    }
}
