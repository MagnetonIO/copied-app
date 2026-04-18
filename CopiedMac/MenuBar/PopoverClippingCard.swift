import SwiftUI
import CopiedKit

/// A single clipping card in the popover — clean design matching original Copied style.
struct PopoverClippingCard: View {
    let clipping: Clipping
    let index: Int
    let isHovered: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Numbered shortcut indicator (⌘1–⌘9)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                Spacer()
                    .frame(width: 24)
            }

            // Content type icon
            contentTypeIcon
                .frame(width: 16)

            // Content preview
            contentPreview
                .frame(maxWidth: .infinity, alignment: .leading)

            // Timestamp / quick actions
            ZStack(alignment: .trailing) {
                Text(clipping.addDate.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .opacity(showsQuickActions ? 0 : 1)

                quickActions
                    .opacity(showsQuickActions ? 1 : 0)
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((isHovered || isSelected) ? .white.opacity(0.08) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Content Type Icon

    private var contentTypeIcon: some View {
        Image(systemName: iconForKind)
            .font(.caption2)
            .foregroundStyle(colorForKind)
    }

    private var iconForKind: String {
        switch clipping.contentKind {
        case .text: "doc.text"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .html: "globe"
        case .file: "doc"
        case .unknown: "questionmark.square"
        }
    }

    private var colorForKind: Color {
        switch clipping.contentKind {
        case .link: .blue
        case .code: .green
        case .image: .purple
        case .richText: .orange
        case .html: .cyan
        default: .secondary
        }
    }

    // MARK: - Content Preview

    // Search state for match highlighting
    var searchMatchRanges: [Range<String.Index>]?

    private var showsQuickActions: Bool {
        isHovered || isSelected
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch clipping.contentKind {
        case .image:
            imagePreview
        case .link:
            linkPreview
        case .code:
            codePreview
        default:
            textPreview
        }
    }

    private var textPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let ranges = searchMatchRanges {
                Text(AttributedString.highlighted(clipping.displayTitle, ranges: ranges))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(3)
            } else {
                Text(clipping.displayTitle)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }

            if let title = clipping.title, !title.isEmpty, let text = clipping.text, !text.isEmpty {
                Text(text.prefix(120))
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var codePreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let ranges = searchMatchRanges {
                    Text(AttributedString.highlighted(String(clipping.text?.prefix(200) ?? ""), ranges: ranges))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4)
                } else {
                    Text(clipping.text?.prefix(200) ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                }
            }
            if let lang = clipping.detectedLanguage {
                Text(lang.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        HStack(spacing: 10) {
            if clipping.hasImage {
                #if canImport(AppKit)
                let thumbnail = ThumbnailCache.shared.thumbnail(for: clipping.clippingID, data: clipping.imageData, maxSize: 96)
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 60)
                    .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                #endif
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(clipping.title ?? "Image")
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                if clipping.imageWidth > 0 {
                    Text("\(Int(clipping.imageWidth)) × \(Int(clipping.imageHeight))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(clipping.title ?? clipping.url ?? "Link")
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.tint)
            if let url = clipping.url {
                Text(url)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 6) {
            Button {
                clipping.isFavorite.toggle()
            } label: {
                Image(systemName: clipping.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(clipping.isFavorite ? .yellow : .secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                clipping.moveToTrash()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}
