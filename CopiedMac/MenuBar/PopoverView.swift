import SwiftUI
import SwiftData
import CopiedKit

struct PopoverView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(AppState.self) private var appState
    @Environment(SyncMonitor.self) private var syncMonitor

    @Query(
        filter: #Predicate<Clipping> { $0.deleteDate == nil },
        sort: \Clipping.addDate,
        order: .reverse
    )
    private var allClippings: [Clipping]

    @AppStorage("pasteAndClose") private var pasteAndClose = true

    #if MAS_BUILD
    @AppStorage("iCloudSyncPurchased") private var iCloudSyncPurchased = false
    #endif
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true

    /// How many of the most recent clippings are currently materialized in the
    /// popover. Starts at 100 and grows by 100 as the user scrolls near the
    /// bottom, capped at `maxVisibleCount` so memory stays bounded.
    @State private var visibleCount: Int = 100
    private let pageSize: Int = 100
    private let maxVisibleCount: Int = 500

    @State private var searchText = ""
    @State private var selectedIndex: Int = 0
    @State private var isKeyboardNavigating: Bool = false
    @State private var editingClipID: String?
    @State private var editText: String = ""
    @State private var previewClipID: String?
    @FocusState private var searchFocused: Bool

    /// Whether more rows can be materialized without hitting the cap. Paging
    /// works in all modes (recent list, search, filter) because the ForEach
    /// caps at `visibleCount` regardless of source.
    private var canLoadMore: Bool {
        visibleCount < maxVisibleCount && visibleCount < filtered.count
    }

    /// Filter/sort result stored as @State instead of being recomputed on every body render.
    /// The previous computed-property design called an async `Task { @MainActor in ... }` to
    /// update its cache, which meant multiple body re-renders within a single frame all missed
    /// the cache and recomputed the full filter/sort — visible as progressive slowdown on
    /// repeated scrolls. Now `recomputeFiltered()` runs only when inputs actually change.
    @State private var filtered: [Clipping] = []
    @State private var matchRanges: [String: [Range<String.Index>]] = [:]

    private func recomputeFiltered() {
        // Always sort the full `allClippings`. The view caps rendering at
        // `visibleCount` via `.prefix(visibleCount)` in the ForEach, so
        // paging never needs a re-sort — scrolling just reveals more of the
        // already-sorted list. This eliminates the per-page-scroll resort that
        // was causing mid-scroll jank.
        let source = Array(allClippings)

        var result = source.sorted { $0.addDate > $1.addDate }

        if let kind = appState.filterKind {
            result = result.filter { $0.contentKind == kind }
        }

        var newRanges: [String: [Range<String.Index>]] = [:]

        if !searchText.isEmpty {
            if searchText.count > 2 {
                var scored: [(Clipping, Int, [Range<String.Index>])] = []

                for clip in result {
                    var bestScore = Int.min
                    var bestRanges: [Range<String.Index>] = []

                    let candidates: [String?] = [
                        clip.text.map { String($0.prefix(500)) },
                        clip.title,
                        clip.url,
                        clip.appName,
                        clip.extractedText.map { String($0.prefix(500)) }
                    ]

                    let minimumFuzzyScore = max(8, searchText.count * 2)

                    for candidate in candidates.compactMap({ $0 }) {
                        if let range = candidate.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) {
                            let score = 1_000 + searchText.count
                            if score > bestScore {
                                bestScore = score
                                bestRanges = [range]
                            }
                        } else if let m = FuzzyMatcher.match(query: searchText, in: candidate),
                                  m.score >= minimumFuzzyScore,
                                  m.score > bestScore {
                            bestScore = m.score
                            bestRanges = m.matchedRanges
                        }
                    }

                    if bestScore > Int.min {
                        scored.append((clip, bestScore, bestRanges))
                        newRanges[clip.clippingID] = bestRanges
                    }
                }

                scored.sort { $0.1 > $1.1 }
                result = scored.map(\.0)
            } else {
                result = result.filter { clip in
                    clip.text?.localizedCaseInsensitiveContains(searchText) == true ||
                    clip.title?.localizedCaseInsensitiveContains(searchText) == true ||
                    clip.url?.localizedCaseInsensitiveContains(searchText) == true ||
                    clip.appName?.localizedCaseInsensitiveContains(searchText) == true ||
                    clip.extractedText?.localizedCaseInsensitiveContains(searchText) == true
                }
            }
        }

        // Pinned to top — only applied to the default recent list, not searches.
        if searchText.isEmpty {
            let pinned = result.filter { $0.isPinned }
            let unpinned = result.filter { !$0.isPinned }
            result = pinned + unpinned
        }

        filtered = result
        matchRanges = newRanges
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            clippingList
            Divider()
            statusBar
        }
        .frame(width: 400, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { imagePreviewOverlay }
        .onKeyPress(.escape) {
            if previewClipID != nil {
                previewClipID = nil
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            guard editingClipID == nil else { return .ignored }
            if selectedIndex < filtered.count {
                copyAndPaste(filtered[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard editingClipID == nil else { return .ignored }
            isKeyboardNavigating = true
            selectedIndex = min(selectedIndex + 1, filtered.count - 1)
            if filtered.indices.contains(selectedIndex) {
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollProxy?.scrollTo(filtered[selectedIndex].clippingID, anchor: nil)
                }
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard editingClipID == nil else { return .ignored }
            isKeyboardNavigating = true
            selectedIndex = max(selectedIndex - 1, 0)
            if filtered.indices.contains(selectedIndex) {
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollProxy?.scrollTo(filtered[selectedIndex].clippingID, anchor: nil)
                }
            }
            return .handled
        }
        // ⌘1–⌘9 quick paste
        .onKeyPress(characters: .init(charactersIn: "123456789"), phases: .down) { press in
            guard editingClipID == nil else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            guard let char = press.characters.first, let digit = Int(String(char)) else { return .ignored }
            let index = digit - 1
            if index < filtered.count {
                copyAndPaste(filtered[index])
            }
            return .handled
        }
        .onAppear {
            recomputeFiltered()
        }
        .onChange(of: appState.popoverIsVisible) { _, visible in
            guard visible else { return }
            searchFocused = true
            selectedIndex = 0
            visibleCount = pageSize
            recomputeFiltered()
            // Defer so SwiftUI has rendered the re-computed `filtered` list
            // before scrolling. Scrolling synchronously scrolls the stale
            // list and lands at the wrong row (or no-ops).
            DispatchQueue.main.async {
                guard let first = filtered.first else { return }
                scrollProxy?.scrollTo(first.clippingID, anchor: .top)
            }
        }
        .onChange(of: appState.filterKind) { _, _ in
            recomputeFiltered()
        }
        .onChange(of: searchText) { _, _ in
            recomputeFiltered()
        }
        .onChange(of: allClippings.count) { _, _ in
            recomputeFiltered()
        }
        // Note: no onChange(of: visibleCount) — paging is a view-layer concern,
        // not a filter concern. Growing visibleCount doesn't need a full re-sort;
        // the ForEach below just reveals more of the already-sorted `filtered`.
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Search clippings…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
                .onKeyPress(.downArrow) {
                    guard editingClipID == nil else { return .ignored }
                    isKeyboardNavigating = true
                    selectedIndex = min(selectedIndex + 1, filtered.count - 1)
                    if filtered.indices.contains(selectedIndex) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy?.scrollTo(filtered[selectedIndex].clippingID, anchor: nil)
                        }
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard editingClipID == nil else { return .ignored }
                    isKeyboardNavigating = true
                    selectedIndex = max(selectedIndex - 1, 0)
                    if filtered.indices.contains(selectedIndex) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy?.scrollTo(filtered[selectedIndex].clippingID, anchor: nil)
                        }
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard editingClipID == nil else { return .ignored }
                    if selectedIndex < filtered.count {
                        copyAndPaste(filtered[selectedIndex])
                    }
                    return .handled
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            filterMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                appState.filterKind = nil
            } label: {
                HStack {
                    Text("All Types")
                    if appState.filterKind == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach([ContentKind.text, .richText, .image, .video, .link, .code], id: \.self) { kind in
                Button {
                    appState.filterKind = kind
                } label: {
                    HStack {
                        Text(kind.rawValue.capitalized)
                        if appState.filterKind == kind { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Image(systemName: appState.filterKind != nil
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.callout)
                .foregroundStyle(appState.filterKind != nil ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Clipping List

    @State private var scrollProxy: ScrollViewProxy?

    private var clippingList: some View {
        // NSTableView-backed SwiftUI List — gives us the same native scroll physics
        // as the main window's lists. LazyVStack+ScrollView didn't match the native feel
        // (momentum, rubber-band, row recycling) even after per-render work was cleaned up.
        // Transparent row styling preserves the custom PopoverClippingCard look.
        ScrollViewReader { proxy in
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clipboard")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty && appState.filterKind == nil
                         ? "Copy something to get started"
                         : "No matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                List {
                    // Cap rendered rows at visibleCount — SwiftUI List is
                    // NSTableView-backed and virtualizes cells, but the ForEach
                    // still materializes Views for every element it iterates.
                    // At 500+ clippings the per-render diff cost shows up as
                    // scroll jank. visibleCount grows as the user scrolls
                    // toward the bottom (see .onAppear below).
                    ForEach(Array(filtered.prefix(visibleCount).enumerated()), id: \.element.clippingID) { index, clipping in
                        Group {
                            if editingClipID == clipping.clippingID {
                                inlineEditor(for: clipping)
                            } else {
                                PopoverClippingCard(
                                    clipping: clipping,
                                    index: index,
                                    isSelected: selectedIndex == index,
                                    isKeyboardNavigating: isKeyboardNavigating,
                                    onMouseMoved: {
                                        if isKeyboardNavigating { isKeyboardNavigating = false }
                                    },
                                    searchMatchRanges: matchRanges[clipping.clippingID]
                                )
                                .onAppear {
                                    // Grow the rendered prefix when the user
                                    // scrolls within 10 rows of the current cap.
                                    if canLoadMore, index >= visibleCount - 10 {
                                        visibleCount = min(visibleCount + pageSize, maxVisibleCount)
                                    }
                                    // Prefetch the next few thumbnails so
                                    // scroll-back and scroll-forward both hit
                                    // warm cache instead of re-decoding.
                                    prefetchAdjacentThumbnails(around: index)
                                }
                                .onTapGesture(count: 2) { handleDoubleClick(clipping) }
                                .onTapGesture { selectClipping(at: index) }
                                .contextMenu {
                                    Button("Copy") { copyToClipboard(clipping) }
                                    if let text = clipping.text, !text.isEmpty {
                                        Button("Copy as Plain Text") {
                                            clipboardService.skipNextCapture = true
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(text, forType: .string)
                                            clipping.markUsed()
                                            try? modelContext.save()
                                        }
                                    }
                                    if clipping.hasRichText {
                                        Button("Copy as Rich Text") { copyAsRichText(clipping) }
                                    }
                                    if clipping.hasHTML {
                                        Button("Copy as HTML") { copyAsHTML(clipping) }
                                    }
                                    if clipping.text != nil {
                                        Menu("Copy As…") {
                                            ForEach(TextTransform.allCases) { transform in
                                                Button(transform.label) {
                                                    copyTransformed(clipping, transform: transform)
                                                }
                                            }
                                        }
                                    }
                                    if clipping.contentKind == .link, let urlStr = clipping.url, let url = URL(string: urlStr) {
                                        Button("Open Link") {
                                            NSWorkspace.shared.open(url)
                                            StatusBarController.shared.closePopover()
                                        }
                                    }
                                    if clipping.contentKind == .code, let text = clipping.text {
                                        Button("Open in Editor") {
                                            openInEditor(text: text, language: clipping.detectedLanguage)
                                            StatusBarController.shared.closePopover()
                                        }
                                    }
                                    if clipping.contentKind == .image, clipping.hasImage {
                                        Button("Open in Default Viewer") {
                                            openImageInDefaultViewer(clipping)
                                            StatusBarController.shared.closePopover()
                                        }
                                    }
                                    if let videoURL = videoFileURL(for: clipping) {
                                        Button("Open Video") {
                                            NSWorkspace.shared.open(videoURL)
                                            StatusBarController.shared.closePopover()
                                        }
                                    }
                                    Divider()
                                    Button(clipping.contentKind == .image ? "Rename…" : "Edit…") {
                                        if clipping.contentKind == .image {
                                            editText = clipping.title ?? "Image"
                                        } else {
                                            editText = clipping.text ?? clipping.url ?? ""
                                        }
                                        editingClipID = clipping.clippingID
                                        // Collapse the "selected row" highlight onto the row
                                        // being edited so the user doesn't see two
                                        // highlighted rows (the editor form + the old
                                        // selection somewhere else).
                                        selectedIndex = index
                                        // Pin the editor to the top so replacing the
                                        // short card with the taller editor form doesn't
                                        // push neighboring rows down (perceived as an
                                        // unwanted scroll, especially on the top row).
                                        DispatchQueue.main.async {
                                            scrollProxy?.scrollTo(clipping.clippingID, anchor: .top)
                                        }
                                    }
                                    Divider()
                                    Button(clipping.isFavorite ? "Unfavorite" : "Favorite") {
                                        clipping.isFavorite.toggle()
                                    }
                                    Button(clipping.isPinned ? "Unpin" : "Pin") {
                                        clipping.isPinned.toggle()
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        clipping.moveToTrash()
                                    }
                                }
                            }
                        }
                        .id(clipping.clippingID)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .onAppear { scrollProxy = proxy }
            }
        }
    }

    // MARK: - Inline Editor

    @ViewBuilder
    private func inlineEditor(for clipping: Clipping) -> some View {
        let isImage = clipping.contentKind == .image
        VStack(alignment: .leading, spacing: 8) {
            if isImage {
                TextField("Image name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.15)))
            } else {
                TextEditor(text: $editText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 160)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.15)))
            }

            HStack(spacing: 8) {
                if !isImage {
                    Button("Save & Copy") {
                        clipping.text = editText
                        clipping.modifiedDate = Date()
                        copyToClipboard(clipping)
                        editingClipID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if isImage {
                    Button("Save") {
                        clipping.title = editText
                        clipping.modifiedDate = Date()
                        editingClipID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Save") {
                        clipping.text = editText
                        clipping.modifiedDate = Date()
                        editingClipID = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button("Cancel") { editingClipID = nil }
                    .buttonStyle(.plain)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
        .id("edit-\(clipping.clippingID)")
    }

    // MARK: - Content Preview Overlay

    @ViewBuilder
    private var imagePreviewOverlay: some View {
        if let clipID = previewClipID,
           let clip = filtered.first(where: { $0.clippingID == clipID }) {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { previewClipID = nil }

                if clip.contentKind == .image, let data = clip.imageData, let nsImage = NSImage(data: data) {
                    // Image preview
                    VStack(spacing: 12) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 10)

                        if clip.imageWidth > 0 {
                            Text("\(Int(clip.imageWidth)) × \(Int(clip.imageHeight))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        Text("Click or press Escape to dismiss")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(20)
                } else if clip.contentKind == .code, let text = clip.text {
                    // Code preview
                    VStack(spacing: 12) {
                        if let lang = clip.detectedLanguage {
                            Text(lang.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.2), in: Capsule())
                                .foregroundStyle(.white)
                        }

                        ScrollView {
                            Text(text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxWidth: 360, maxHeight: 380)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                        HStack(spacing: 16) {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                previewClipID = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Open in Editor") {
                                openInEditor(text: text, language: clip.detectedLanguage)
                                previewClipID = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Click or press Escape to dismiss")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(20)
                }
            }
            .transition(.opacity)
        }
    }

    private func openInEditor(text: String, language: String?) {
        let ext: String
        switch language {
        case "swift": ext = "swift"
        case "python": ext = "py"
        case "javascript": ext = "js"
        case "typescript": ext = "ts"
        case "rust": ext = "rs"
        case "go": ext = "go"
        case "java": ext = "java"
        case "html": ext = "html"
        case "css": ext = "css"
        case "shell": ext = "sh"
        case "yaml": ext = "yml"
        case "json": ext = "json"
        case "toml": ext = "toml"
        case "dockerfile": ext = "Dockerfile"
        case "makefile": ext = "Makefile"
        case "xml": ext = "xml"
        case "sql": ext = "sql"
        case "ruby": ext = "rb"
        case "elixir": ext = "ex"
        case "kotlin": ext = "kt"
        case "c": ext = "c"
        case "cpp": ext = "cpp"
        case "php": ext = "php"
        case "terraform": ext = "tf"
        case "scala": ext = "scala"
        case "r": ext = "R"
        case "lua": ext = "lua"
        case "dart": ext = "dart"
        case "haskell": ext = "hs"
        default: ext = "txt"
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("copied-snippet.\(ext)")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tempURL)
    }

    private func openImageInDefaultViewer(_ clipping: Clipping) {
        guard let data = clipping.imageData else { return }
        let ext: String
        switch clipping.imageFormat.lowercased() {
        case "png": ext = "png"
        case "jpeg", "jpg": ext = "jpg"
        case "gif": ext = "gif"
        case "webp": ext = "webp"
        case "heic": ext = "heic"
        default: ext = "tiff"
        }
        let slug = String(clipping.clippingID.prefix(8))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("copied-\(slug).\(ext)")
        do {
            try data.write(to: tempURL, options: .atomic)
            NSWorkspace.shared.open(tempURL)
        } catch {
            NSLog("Failed to write temp image for viewer: \(error)")
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle()
                    .fill(clipboardService.isMonitoring ? .green : .red)
                    .frame(width: 6, height: 6)
                Text(clipboardService.isMonitoring ? "Monitoring" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            syncStatusView

            Spacer()

            Text(GlobalHotkeyManager.shared.shortcutDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Menu {
                Button("Open Main Window") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    // Find existing window or let SwiftUI create one
                    if let window = NSApp.windows.first(where: { $0.title == "Copied" }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        // Open the Window scene by its ID
                        NSApp.sendAction(Selector(("showMainWindow:")), to: nil, from: nil)
                    }
                    StatusBarController.shared.closePopover()
                }
                Button("Settings…") {
                    StatusBarController.shared.openSettings()
                }
                Divider()
                Button(clipboardService.isMonitoring ? "Pause Monitoring" : "Resume Monitoring") {
                    clipboardService.isMonitoring ? clipboardService.stop() : clipboardService.start()
                }
                Divider()
                Button("Sync Now") {
                    syncMonitor.triggerSync()
                }
                Divider()
                Button("Quit Copied") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var isSyncing: Bool {
        guard popoverSyncState == .live else { return false }
        if case .syncing = syncMonitor.status { return true }
        return false
    }

    /// The user-facing sync state shown in the popover footer. Separate from
    /// `syncMonitor.status` because the monitor only reports CloudKit
    /// connectivity — we also have to reflect the purchase/unlock flag
    /// (MAS_BUILD) and whether the user toggled sync off in Settings.
    private enum PopoverSyncState {
        case locked      // paywall not unlocked
        case disabled    // unlocked but user toggled off
        case live        // unlocked + enabled → mirror syncMonitor.status
    }

    private var popoverSyncState: PopoverSyncState {
        #if MAS_BUILD
        if !iCloudSyncPurchased { return .locked }
        #endif
        if !cloudSyncEnabled { return .disabled }
        return .live
    }

    private var syncStatusView: some View {
        HStack(spacing: 4) {
            Image(systemName: syncIcon)
                .font(.caption2)
                .foregroundStyle(syncColor)
                .symbolEffect(.rotate, isActive: isSyncing)
            Text(syncLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .layoutPriority(1)
    }

    private var syncLabel: String {
        switch popoverSyncState {
        case .locked: return "Sync Locked"
        case .disabled: return "Sync Off"
        case .live: return syncMonitor.status.label
        }
    }

    private var syncIcon: String {
        switch popoverSyncState {
        case .locked: return "lock.icloud"
        case .disabled: return "icloud.slash"
        case .live:
            switch syncMonitor.status {
            case .synced: return "icloud.fill"
            case .available: return "icloud"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .noAccount: return "icloud.slash"
            case .error: return "exclamationmark.icloud"
            case .notStarted: return "icloud"
            }
        }
    }

    private var syncColor: Color {
        switch popoverSyncState {
        case .locked, .disabled: return .secondary
        case .live:
            switch syncMonitor.status {
            case .synced: return .green
            case .available: return .secondary
            case .syncing: return .blue
            case .noAccount, .error: return .red
            case .notStarted: return .secondary
            }
        }
    }

    // MARK: - Actions

    private func selectClipping(at index: Int) {
        selectedIndex = index
    }

    private func handleDoubleClick(_ clipping: Clipping) {
        // If the clipping references a video file on disk, open it in the
        // user's default video app instead of copying a thumbnail.
        if let videoURL = videoFileURL(for: clipping) {
            NSWorkspace.shared.open(videoURL)
            StatusBarController.shared.closePopover()
            return
        }
        switch clipping.contentKind {
        case .link:
            if let urlStr = clipping.url, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
                StatusBarController.shared.closePopover()
            }
        case .code:
            previewClipID = clipping.clippingID
        case .image:
            previewClipID = clipping.clippingID
        default:
            copyAndPaste(clipping)
        }
    }

    private func videoFileURL(for clipping: Clipping) -> URL? {
        guard clipping.isVideoFile,
              let src = clipping.sourceURL,
              let url = URL(string: src),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func copyTransformed(_ clipping: Clipping, transform: TextTransform) {
        guard let text = clipping.text else { return }
        clipboardService.skipNextCapture = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transform.apply(text), forType: .string)
        clipping.markUsed()
        try? modelContext.save()
    }

    private func copyAsRichText(_ clipping: Clipping) {
        guard let rtfData = clipping.richTextData else { return }
        clipboardService.skipNextCapture = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(rtfData, forType: clipping.richTextPasteboardType)
        if let text = clipping.text {
            pb.setString(text, forType: .string)
        }
        clipping.markUsed()
        try? modelContext.save()
    }

    private func copyAsHTML(_ clipping: Clipping) {
        guard let htmlData = clipping.htmlData else { return }
        clipboardService.skipNextCapture = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(htmlData, forType: .html)
        if let text = clipping.text {
            pb.setString(text, forType: .string)
        }
        clipping.markUsed()
        try? modelContext.save()
    }

    private func copyAndPaste(_ clipping: Clipping) {
        copyToClipboard(clipping)
        if pasteAndClose {
            StatusBarController.shared.closePopover()
        }
    }

    /// Warm the thumbnail cache for a few rows around `index` so scroll-back
    /// and scroll-forward both land on cache hits. Fire-and-forget — the cache
    /// returns early if an entry already exists, and failures are silent.
    private func prefetchAdjacentThumbnails(around index: Int) {
        let window = 5
        let start = max(0, index - window)
        let end = min(filtered.count, index + window + 1)
        guard start < end else { return }
        for i in start..<end where i < filtered.count {
            let clip = filtered[i]
            guard clip.hasImage else { continue }
            let clippingID = clip.clippingID
            let data = clip.imageData
            Task.detached(priority: .utility) {
                _ = await ThumbnailCache.shared.decodeThumbnail(for: clippingID, data: data, maxSize: 96)
            }
        }
    }

    private func copyToClipboard(_ clipping: Clipping) {
        // Tell the clipboard service to skip the next poll so it doesn't re-capture our own write
        clipboardService.skipNextCapture = true

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let text = clipping.text {
            pasteboard.setString(text, forType: .string)
        }
        if let url = clipping.url {
            pasteboard.setString(url, forType: .URL)
        }
        if let imageData = clipping.imageData {
            let type: NSPasteboard.PasteboardType = clipping.imageFormat == "png" ? .png : .tiff
            pasteboard.setData(imageData, forType: type)
        }
        if let rtfData = clipping.richTextData {
            pasteboard.setData(rtfData, forType: clipping.richTextPasteboardType)
        }
        if let htmlData = clipping.htmlData {
            pasteboard.setData(htmlData, forType: .html)
        }

        clipping.markUsed()
        try? modelContext.save()
        selectedIndex = 0
        // Invalidate cache so the re-sorted order is visible immediately
    }
}
