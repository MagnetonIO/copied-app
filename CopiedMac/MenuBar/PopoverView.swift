import SwiftUI
import SwiftData
import CopiedKit
import OSLog

struct PopoverView: View {
    private let syncProfileLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Copied",
        category: "SyncProfile"
    )
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(AppState.self) private var appState
    @Environment(SyncMonitor.self) private var syncMonitor
    @Environment(SyncTicker.self) private var syncTicker

    /// Change detector only. MenuBarExtra's scene-local model context can lag
    /// behind the main window's context after CloudKit imports, so the popover
    /// renders from `freshAllClippings` instead of trusting this @Query as its
    /// source of truth. We still keep the query mounted because it is a cheap
    /// local-mutation signal for user edits that originate inside the popover.
    @Query(
        filter: #Predicate<Clipping> { $0.deleteDate == nil },
        sort: \Clipping.addDate,
        order: .reverse
    )
    private var allClippings: [Clipping]

    /// Sidebar-style list roster for the popover filter menu.
    @Query(sort: \ClipList.sortOrder) private var userLists: [ClipList]

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

    /// Search input trails `searchText` by 200 ms so fuzzy scoring on
    /// 500-item history doesn't re-run on every keystroke. Updated via
    /// `.onChange(of: searchText)` below.
    @State private var searchDebounced: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Coalesces rapid row-appearance events into a single batched
    /// thumbnail-prefetch pass. A fast scroll can fire dozens of
    /// `prefetchAdjacentThumbnails(around:)` calls back-to-back; the
    /// batch window means we spawn one set of detached decode Tasks
    /// for the settled-on region instead of one per appeared row.
    @State private var prefetchPendingIndices: Set<Int> = []
    @State private var prefetchDebounceTask: Task<Void, Never>?
    @State private var freshAllClippings: [Clipping] = []

    /// Fingerprint for detecting local popover-originated mutations
    /// (favorite/pin/edit/delete) even if they do not cross a CloudKit sync
    /// boundary and therefore do not bump `SyncTicker`.
    private var localClippingsRevision: Int {
        var hasher = Hasher()
        hasher.combine(allClippings.count)
        for clip in allClippings {
            hasher.combine(clip.clippingID)
            hasher.combine(clip.modifiedDate ?? clip.addDate)
            hasher.combine(clip.deleteDate)
            hasher.combine(clip.isPinned)
            hasher.combine(clip.isFavorite)
            hasher.combine(clip.list?.listID)
        }
        return hasher.finalize()
    }

    /// Read through a brand-new ModelContext so the popover is not pinned to a
    /// stale SwiftData generation. This is the load-bearing fix for the
    /// screenshot mismatch where the main window showed three clippings while
    /// the popover still showed one.
    @MainActor
    private func refreshFreshClippings() {
        var descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate<Clipping> { $0.deleteDate == nil }
        )
        descriptor.sortBy = [SortDescriptor(\Clipping.addDate, order: .reverse)]
        let ctx = ModelContext(SharedData.container)
        freshAllClippings = (try? ctx.fetch(descriptor)) ?? Array(allClippings)
    }

    /// Queue a prefetch around `index` for a batched pass ~100 ms later.
    /// Deduplicates via `prefetchPendingIndices` set so overlapping
    /// windows from adjacent row-appearances only prefetch each
    /// clipping once.
    private func schedulePrefetch(aroundIndex index: Int) {
        prefetchPendingIndices.insert(index)
        prefetchDebounceTask?.cancel()
        prefetchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let indices = prefetchPendingIndices
            prefetchPendingIndices.removeAll()
            for i in indices {
                prefetchAdjacentThumbnails(around: i)
            }
        }
    }

    /// Filter/sort result computed from `freshAllClippings`, which is fetched
    /// via a new ModelContext on every sync/local-mutation signal so the
    /// popover reflects the same dataset as the main window.
    private var filteredAndRanges: (clippings: [Clipping], ranges: [String: [Range<String.Index>]]) {
        var result = freshAllClippings

        if let kind = appState.filterKind {
            result = result.filter { $0.contentKind == kind }
        }

        if let listID = appState.popoverListFilterID {
            result = result.filter { $0.list?.listID == listID }
        }

        var ranges: [String: [Range<String.Index>]] = [:]

        if !searchDebounced.isEmpty {
            if searchDebounced.count > 2 {
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
                    let minimumFuzzyScore = max(8, searchDebounced.count * 2)
                    for candidate in candidates.compactMap({ $0 }) {
                        if let range = candidate.range(of: searchDebounced, options: [.caseInsensitive, .diacriticInsensitive]) {
                            let score = 1_000 + searchDebounced.count
                            if score > bestScore {
                                bestScore = score
                                bestRanges = [range]
                            }
                        } else if let m = FuzzyMatcher.match(query: searchDebounced, in: candidate),
                                  m.score >= minimumFuzzyScore,
                                  m.score > bestScore {
                            bestScore = m.score
                            bestRanges = m.matchedRanges
                        }
                    }
                    if bestScore > Int.min {
                        scored.append((clip, bestScore, bestRanges))
                        ranges[clip.clippingID] = bestRanges
                    }
                }
                scored.sort { $0.1 > $1.1 }
                result = scored.map(\.0)
            } else {
                result = result.filter { clip in
                    clip.text?.localizedCaseInsensitiveContains(searchDebounced) == true ||
                    clip.title?.localizedCaseInsensitiveContains(searchDebounced) == true ||
                    clip.url?.localizedCaseInsensitiveContains(searchDebounced) == true ||
                    clip.appName?.localizedCaseInsensitiveContains(searchDebounced) == true ||
                    clip.extractedText?.localizedCaseInsensitiveContains(searchDebounced) == true
                }
            }
        }

        // Pinned to top — only for the default recent list, not searches.
        if searchDebounced.isEmpty {
            let pinned = result.filter { $0.isPinned }
            let unpinned = result.filter { !$0.isPinned }
            result = pinned + unpinned
        }

        return (result, ranges)
    }

    private var filtered: [Clipping] { filteredAndRanges.clippings }
    private var matchRanges: [String: [Range<String.Index>]] { filteredAndRanges.ranges }

    var body: some View {
        let _ = syncTicker.tick
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
        .onAppear {
            syncProfileLogger.log("trigger popover.onAppear")
            // Reset to top-of-list every time the popover reopens.
            // scenePhase doesn't fire reliably for MenuBarExtra
            // re-presentation, so do the reset here in onAppear too.
            searchFocused = true
            selectedIndex = 0
            visibleCount = pageSize
            refreshFreshClippings()
            DispatchQueue.main.async {
                if let first = filtered.first {
                    scrollProxy?.scrollTo(first.clippingID, anchor: .top)
                }
            }
            // manualInboundFetch (not engine.fetchChanges) — opening the
            // popover doesn't activate the app, so the engine's push
            // queue won't be flushed and fetchChanges no-ops. Manual
            // path issues a real CKFetchRecordZoneChangesOperation.
            Task.detached { await CopiedSyncEngine.shared.manualInboundFetch(source: "mac.popover.onAppear") }
        }
        .onKeyPress(.escape) {
            if previewClipID != nil {
                previewClipID = nil
                return .handled
            }
            dismissPopover()
            return .handled
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
        .onChange(of: scenePhase) { _, phase in
            syncProfileLogger.log("trigger popover.scenePhase phase=\(String(describing: phase), privacy: .public)")
            let visible = (phase == .active)
            appState.popoverIsVisible = visible
            guard visible else { return }
            searchFocused = true
            selectedIndex = 0
            visibleCount = pageSize
            refreshFreshClippings()
            // Fire-and-forget manual inbound fetch on popover open /
            // re-activate. Engine.fetchChanges no-ops here because
            // popover open doesn't activate the app (no push queue
            // flush). manualInboundFetch issues a real CKFetch against
            // our independent change token — cooldown is enforced in
            // the engine.
            Task.detached { await CopiedSyncEngine.shared.manualInboundFetch(source: "mac.popover.sceneActive") }
            // Defer scroll so SwiftUI has rendered the filtered list
            // before scrolling. Scrolling synchronously against a
            // not-yet-rendered list no-ops or lands at the wrong row.
            DispatchQueue.main.async {
                guard let first = filtered.first else { return }
                scrollProxy?.scrollTo(first.clippingID, anchor: .top)
            }
        }
        // Debounce search input by 200 ms so fuzzy scoring runs once
        // the user pauses, not on every keystroke.
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                searchDebounced = newValue
            }
        }
        .onChange(of: syncTicker.tick) { _, _ in
            refreshFreshClippings()
        }
        .onChange(of: localClippingsRevision) { _, _ in
            refreshFreshClippings()
        }
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

            listFilterMenu
            filterMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Items shared between the footer "..." Menu and the popover-root
    /// `.contextMenu` (right-click anywhere outside a clipping row).
    /// Per-row context menus take precedence — SwiftUI uses the
    /// innermost contextMenu at the click location.
    @ViewBuilder
    private var popoverGlobalMenuItems: some View {
        Button("Open Main Window") {
            // Use dismissPopover (which calls window.close() directly
            // on the MenuBarExtra window) instead of performClose —
            // the latter beeps because the popover refuses
            // responder-chain close requests. Defer openWindow to the
            // next runloop tick so menu dismissal completes first.
            dismissPopover()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                openWindow(id: "main")
            }
        }
        Button("Settings…") {
            SettingsWindowController.shared.show()
        }
        Divider()
        Button(clipboardService.isMonitoring ? "Pause Monitoring" : "Resume Monitoring") {
            if clipboardService.isMonitoring {
                clipboardService.stop()
            } else {
                clipboardService.start()
                Task { await CopiedSyncEngine.shared.syncNow() }
            }
        }
        Divider()
        Button("Sync Now") {
            Task { await CopiedSyncEngine.shared.syncNow() }
        }
        Divider()
        Button("Quit Copied") { NSApplication.shared.terminate(nil) }
    }

    /// Popover list filter — a folder icon that opens a checkmarked menu
    /// of user lists. "All Lists" clears the filter. Mirrors the shape of
    /// `filterMenu` so the two controls read as a pair.
    private var listFilterMenu: some View {
        Menu {
            Button {
                appState.popoverListFilterID = nil
            } label: {
                HStack {
                    Text("All Lists")
                    if appState.popoverListFilterID == nil { Image(systemName: "checkmark") }
                }
            }
            if !userLists.isEmpty {
                Divider()
                ForEach(userLists) { list in
                    Button {
                        appState.popoverListFilterID = list.listID
                    } label: {
                        HStack {
                            Text(list.name)
                            if appState.popoverListFilterID == list.listID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: appState.popoverListFilterID != nil
                  ? "folder.fill"
                  : "folder")
                .font(.callout)
                .foregroundStyle(appState.popoverListFilterID != nil ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            ForEach([ContentKind.text, .richText, .image, .video, .link, .code, .markdown, .html], id: \.self) { kind in
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
                                    // Queue the next few thumbnails for a
                                    // batched prefetch ~100 ms after the last
                                    // row-appearance settles. Collapses a flood
                                    // of scroll-driven prefetch calls into one
                                    // deduped pass (was visibly stuttering on
                                    // fast image-heavy scroll).
                                    schedulePrefetch(aroundIndex: index)
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
                                    if clipping.contentKind == .link,
                                       let urlStr = clipping.url,
                                       let url = URL(string: urlStr),
                                       let scheme = url.scheme?.lowercased(),
                                       scheme == "http" || scheme == "https" {
                                        // Restrict to http/https — a crafted clipping
                                        // containing e.g. `x-apple-reminderkit://…` would
                                        // otherwise dispatch arbitrary custom URL schemes.
                                        Button("Open Link") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    if clipping.isCodeLike, let text = clipping.text {
                                        Button("Open in Editor") {
                                            openInEditor(text: text, language: clipping.detectedLanguage)
                                        }
                                    }
                                    if clipping.contentKind == .image, clipping.hasImage {
                                        Button("Open in Default Viewer") {
                                            openImageInDefaultViewer(clipping)
                                        }
                                    }
                                    if let videoURL = videoFileURL(for: clipping) {
                                        Button("Open Video") {
                                            NSWorkspace.shared.open(videoURL)
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
                                        clipping.persist()
                                    }
                                    Button(clipping.isPinned ? "Unpin" : "Pin") {
                                        clipping.isPinned.toggle()
                                        clipping.persist()
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
                        clipping.persist()
                        editingClipID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Save") {
                        clipping.text = editText
                        clipping.persist()
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

                        HStack(spacing: 16) {
                            Button("Copy") {
                                if let imageData = clip.imageData {
                                    let type: NSPasteboard.PasteboardType = clip.imageFormat == "png" ? .png : .tiff
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setData(imageData, forType: type)
                                }
                                previewClipID = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Open in Default Viewer") {
                                openImageInDefaultViewer(clip)
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
                } else if clip.isCodeLike, let text = clip.text {
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
                popoverGlobalMenuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            // .menuStyle(.button) + .buttonStyle(.borderless) = menu
            // popup behavior (no pop sound) with transparent background
            // (blends with the footer). Do NOT use .buttonStyle(.plain)
            // — that one reintroduces the system beep on open.
            .menuStyle(.button)
            .buttonStyle(.borderless)
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
            NSApp.keyWindow?.performClose(nil)
            return
        }
        switch clipping.contentKind {
        case .link:
            if let urlStr = clipping.url, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
                NSApp.keyWindow?.performClose(nil)
            }
        case .code, .markdown, .html:
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
            dismissPopover()
        }
    }

    /// Close the MenuBarExtra popover from any responder context.
    /// Routes through the existing toggle notification, whose handler
    /// performClicks the NSStatusBarButton — that closes the popover
    /// AND clears the button's highlight state. Closing the window
    /// directly (e.g. window.close()) leaves the button stuck in its
    /// "pressed" highlight because the system thinks the popover is
    /// still associated with it.
    private func dismissPopover() {
        NotificationCenter.default.post(
            name: Notification.Name("com.magneton.copied.toggleMenuBarPopover"),
            object: nil
        )
    }

    /// Warm the thumbnail cache for a few rows around `index` so scroll-back
    /// and scroll-forward both land on cache hits. Fire-and-forget — the cache
    /// returns early if an entry already exists, and failures are silent.
    ///
    /// Previously this faulted `clip.imageData` (an `@Attribute(.externalStorage)`
    /// blob) on the main actor before kicking off the detached decode,
    /// which caused visible scroll hitches on image-heavy popover views.
    /// Now we short-circuit on cache hits before touching imageData, and
    /// fetch the blob inside the detached task via a dedicated ModelContext
    /// so the main actor never blocks on blob I/O.
    private func prefetchAdjacentThumbnails(around index: Int) {
        let window = 5
        let start = max(0, index - window)
        let end = min(filtered.count, index + window + 1)
        guard start < end else { return }
        for i in start..<end where i < filtered.count {
            let clip = filtered[i]
            guard clip.hasImage else { continue }
            let clippingID = clip.clippingID
            // Cache-hit short circuit — avoids the external-storage fault
            // entirely for rows we already have a thumbnail for.
            if ThumbnailCache.shared.cachedThumbnail(for: clippingID, maxSize: 96) != nil {
                continue
            }
            let container = modelContext.container
            Task.detached(priority: .utility) {
                let ctx = ModelContext(container)
                let descriptor = FetchDescriptor<Clipping>(
                    predicate: #Predicate { $0.clippingID == clippingID }
                )
                guard let fetched = try? ctx.fetch(descriptor).first,
                      let data = fetched.imageData else { return }
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
