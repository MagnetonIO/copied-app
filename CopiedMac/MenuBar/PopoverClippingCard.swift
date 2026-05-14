import SwiftUI
import SwiftData
import CopiedKit

/// A single clipping card in the popover — clean design matching original Copied style.
struct PopoverClippingCard: View {
    @Environment(\.modelContext) private var modelContext

    let clipping: Clipping
    let index: Int
    let isSelected: Bool
    let isKeyboardNavigating: Bool
    /// Called once, only on genuine cursor movement into the row. Parent uses this
    /// to clear its `isKeyboardNavigating` flag so mouse reclaims control.
    var onMouseMoved: (() -> Void)? = nil

    /// All user lists (sorted), passed in from PopoverView so we reuse the parent's
    /// `@Query` instead of re-fetching per row.
    var availableLists: [ClipList] = []

    /// Invoked when the user picks "+ New List…" from the per-row picker. PopoverView
    /// owns the naming alert (sheets dismiss the MenuBarExtra popover, per COP-98)
    /// and uses this clipping as the auto-assign target once the user names the list.
    var onRequestNewList: ((Clipping) -> Void)? = nil

    /// Apply a list assignment (or clear, when `nil`) for this row's clipping.
    /// Routed through the parent because `freshAllClippings` Clippings live in
    /// a fresh ephemeral ModelContext per refresh — assigning a `ClipList`
    /// (which lives in mainContext) directly onto them crashes SwiftData.
    /// PopoverView re-fetches the clipping in mainContext before writing.
    var onAssignList: ((String, ClipList?) -> Void)? = nil

    /// Bumped after a list assignment / clear so the parent can refresh its
    /// `freshAllClippings` snapshot — otherwise the row would appear unchanged
    /// until the next sync tick.
    var onLocalMutation: (() -> Void)? = nil

    /// Hover is row-local: writes stay inside this view and don't re-render the parent
    /// popover or other rows. Previously the parent held `hoveredID` and every `.onHover`
    /// fired a state write there, cascading into a full popover body rebuild each time
    /// the mouse moved during scroll.
    @State private var isHovered: Bool = false
    @State private var lastMouseLocation: CGPoint = .zero

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

            // Pin indicator — orange `pin.fill` shown only when pinned, so a
            // pinned row is recognisable at a glance even before reading
            // its content. Mirrors the main-window `ClippingRow` treatment.
            if clipping.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(45))
                    .accessibilityLabel("Pinned")
            }

            // Content preview
            contentPreview
                .frame(maxWidth: .infinity, alignment: .leading)

            // Timestamp / quick actions. The favorite ★ inside `quickActions`
            // owns its own opacity so it stays visible whenever the row is
            // favorited (even when not hovered) — without that, a starred
            // row's yellow indicator vanishes the moment the cursor leaves.
            // The timestamp hides whenever ★ would be drawn so they don't
            // overlap inside the 76-pt trailing slot.
            ZStack(alignment: .trailing) {
                Text(clipping.addDate.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .opacity((showsQuickActions || clipping.isFavorite) ? 0 : 1)

                quickActions
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            // Show at most one highlight at a time.
            // Keyboard mode: highlight follows `isSelected` (arrow-key cursor).
            // Mouse mode:    highlight follows `isHovered` only — the stale
            //                 selectedIndex is not shown, so the user never sees
            //                 two rows highlighted.
            RoundedRectangle(cornerRadius: 8)
                .fill(showsHighlight ? .white.opacity(0.08) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            if hovering {
                // Only flip hover state when the mouse actually moves. Without the
                // mouseMoved gate, SwiftUI fires .onHover on every render, and during
                // scroll the render rate compounds with cursor-under-row to thrash
                // the flag constantly.
                let m = NSEvent.mouseLocation
                let moved = abs(m.x - lastMouseLocation.x) > 2 ||
                            abs(m.y - lastMouseLocation.y) > 2
                lastMouseLocation = m
                if moved {
                    onMouseMoved?()
                    if !isKeyboardNavigating { isHovered = true }
                }
            } else {
                isHovered = false
            }
        }
        .onChange(of: isKeyboardNavigating) { _, kb in
            if kb { isHovered = false }
        }
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
        case .video: "play.rectangle.fill"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.alignleft"
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
        case .video: .pink
        case .richText: .orange
        case .markdown: .indigo
        case .html: .cyan
        default: .secondary
        }
    }

    // MARK: - Content Preview

    // Search state for match highlighting
    var searchMatchRanges: [Range<String.Index>]?

    /// Mirrors `showsHighlight`'s mode-aware rule. The OR-form (`isHovered ||
    /// isSelected`) leaked the stale keyboard cursor's `isSelected` into the
    /// trailing icons in mouse mode — the top row appeared to "always" show
    /// ★/➕/🗑 because `selectedIndex` defaults to 0 on popover open.
    private var showsQuickActions: Bool {
        isKeyboardNavigating ? isSelected : isHovered
    }

    /// Single-highlight rule for the row background.
    /// - Keyboard mode (arrow keys): highlight follows the selection cursor.
    /// - Mouse mode: highlight follows the mouse; the stale keyboard selection
    ///   is not drawn, so the user never sees two rows highlighted.
    /// Matches the Spotlight/Raycast behaviour for menu-bar pickers.
    private var showsHighlight: Bool {
        isKeyboardNavigating ? isSelected : isHovered
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch clipping.contentKind {
        case .image:
            imagePreview
        case .video:
            videoPreview
        case .link:
            linkPreview
        case .code, .markdown, .html:
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
                AsyncThumbnailImage(
                    clippingID: clipping.clippingID,
                    dataProvider: { [clippingID = clipping.clippingID] in
                        ClipboardService.readBlob(
                            in: SharedData.container,
                            clippingID: clippingID,
                            key: \Clipping.imageData
                        )
                    },
                    maxSize: 96
                )
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

    @ViewBuilder
    private var videoPreview: some View {
        HStack(spacing: 10) {
            ZStack {
                #if canImport(AppKit)
                if clipping.hasImage {
                    AsyncThumbnailImage(
                        clippingID: clipping.clippingID,
                        dataProvider: { [clippingID = clipping.clippingID] in
                        ClipboardService.readBlob(
                            in: SharedData.container,
                            clippingID: clippingID,
                            key: \Clipping.imageData
                        )
                    },
                        maxSize: 96
                    )
                    .frame(width: 96, height: 60)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.black.opacity(0.5))
                        .frame(width: 96, height: 60)
                        .overlay(
                            Image(systemName: "video")
                                .foregroundStyle(.white.opacity(0.6))
                        )
                }
                #endif
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.55), in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(clipping.title ?? "Video")
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text("Video")
                    .font(.caption)
                    .foregroundStyle(.pink)
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
            // Favorite ★ stays visible whenever the row is favorited so the
            // yellow indicator is glanceable across the whole list — not just
            // on the hovered/selected row. ➕ and 🗑 stay hover/select-gated.
            Button {
                clipping.isFavorite.toggle()
                clipping.persist()
                onLocalMutation?()
            } label: {
                Image(systemName: clipping.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(clipping.isFavorite ? .yellow : .secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(clipping.isFavorite || showsQuickActions ? 1 : 0)

            // Menu (not a sheet) because sheets dismiss the MenuBarExtra popover
            // by losing key window status (per COP-98 discovery).
            addToListMenu
                .opacity(showsQuickActions ? 1 : 0)

            Button {
                clipping.moveToTrash()
                onLocalMutation?()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsQuickActions ? 1 : 0)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private var addToListMenu: some View {
        Menu {
            Button {
                onRequestNewList?(clipping)
            } label: {
                Label("New List…", systemImage: "folder.badge.plus")
            }
            if !availableLists.isEmpty {
                Divider()
                ForEach(availableLists) { list in
                    Button {
                        // Route through the parent — re-fetches the clipping
                        // in mainContext before the relationship write to
                        // avoid a cross-context SwiftData crash.
                        onAssignList?(clipping.clippingID, list)
                    } label: {
                        HStack {
                            Text(list.name)
                            if clipping.list?.listID == list.listID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if clipping.list != nil {
                Divider()
                Button(role: .destructive) {
                    onAssignList?(clipping.clippingID, nil)
                } label: {
                    Label("Remove from List", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Image(systemName: clipping.list != nil ? "text.badge.checkmark" : "text.badge.plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(clipping.list != nil ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

#if canImport(AppKit)
/// Image view that resolves its thumbnail off the main thread AND defers the
/// `@Attribute(.externalStorage)` blob fault until after initial layout.
///
/// - Cache hit at init: `@State image` is seeded synchronously from `ThumbnailCache`
///   so no placeholder flash on scroll-back / row recycling.
/// - Cache miss: `dataProvider()` is called inside `.task` (not during body), which
///   defers the sync disk read for `clipping.imageData` to after the first layout.
///   The decode itself runs on a background Task, so scroll never blocks.
struct AsyncThumbnailImage: View {
    let clippingID: String
    let dataProvider: () -> Data?
    let maxSize: CGFloat

    @State private var image: NSImage?

    init(clippingID: String, dataProvider: @escaping () -> Data?, maxSize: CGFloat) {
        self.clippingID = clippingID
        self.dataProvider = dataProvider
        self.maxSize = maxSize
        _image = State(initialValue: ThumbnailCache.shared.cachedThumbnail(for: clippingID, maxSize: maxSize))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: clippingID) {
            if image != nil { return }
            let resolvedData = dataProvider()
            image = await ThumbnailCache.shared.decodeThumbnail(for: clippingID, data: resolvedData, maxSize: maxSize)
        }
    }
}
#endif
