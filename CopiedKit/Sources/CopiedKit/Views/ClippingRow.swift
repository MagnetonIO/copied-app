import SwiftUI
import SwiftData

public struct ClippingRow: View {
    let clipping: Clipping

    public init(clipping: Clipping) {
        self.clipping = clipping
    }

    public var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(clipping.displayTitle)
                    .font(.body)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let appName = clipping.appName {
                        Text(appName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(clipping.addDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if clipping.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            if clipping.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            contentBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch clipping.contentKind {
        case .image:
            if let data = clipping.imageData, let image = makeImage(from: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                fallbackIcon("photo")
            }
        case .link:
            fallbackIcon("link")
        case .richText:
            fallbackIcon("doc.richtext")
        case .code:
            fallbackIcon("chevron.left.forwardslash.chevron.right")
        case .html:
            fallbackIcon("globe")
        case .text:
            fallbackIcon("doc.text")
        case .file:
            fallbackIcon("doc")
        case .unknown:
            fallbackIcon("questionmark.square")
        }
    }

    private func fallbackIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var contentBadge: some View {
        Text(clipping.contentKind.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
    }

    private func makeImage(from data: Data) -> Image? {
        #if canImport(AppKit)
        let nsImage = ThumbnailCache.shared.thumbnail(for: clipping.clippingID, data: data, maxSize: 32)
        return Image(nsImage: nsImage)
        #elseif canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}
